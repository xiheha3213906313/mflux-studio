import CryptoKit
import Darwin
import Foundation
import Network
import Security

struct FrameAPIError: Error, LocalizedError {
    let status: Int
    let code: String
    let message: String

    init(_ status: Int, _ code: String, _ message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    var errorDescription: String? { message }
}

struct FrameHTTPHead {
    let method: String
    let path: String
    let headers: [String: String]
    let length: Int

    init(_ data: Data) throws {
        let bad = FrameAPIError(400, "invalid_http", "无法读取 HTTP 请求。")
        guard let text = String(data: data, encoding: .ascii) else { throw bad }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, ["GET", "POST"].contains(request[0]), request[1].hasPrefix("/v1/"),
              !request[1].contains(where: { $0.isWhitespace || $0 == "%" || $0 == "?" }),
              ["HTTP/1.1", "HTTP/1.0"].contains(request[2]) else { throw bad }
        method = String(request[0])
        path = String(request[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw bad }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  headers[key] == nil else { throw bad }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw bad }
        let raw = headers["content-length"] ?? "0"
        guard raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(raw), method != "GET" || length == 0 else { throw bad }
        self.length = length
        self.headers = headers
    }
}

enum FrameResponseBody {
    case data(Data)
    case file(URL, Int)

    var length: Int {
        switch self {
        case .data(let data): data.count
        case .file(_, let size): size
        }
    }
}

struct FrameHTTPResponse {
    let status: Int
    let type: String
    let body: FrameResponseBody

    static func json(_ value: [String: Any], status: Int = 200) -> Self {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return Self(status: data == nil ? 500 : status, type: "application/json; charset=utf-8",
                    body: .data(data ?? Data("{\"error\":{\"code\":\"encoding_failed\"}}".utf8)))
    }

    static func failure(_ error: FrameAPIError) -> Self {
        .json(["error": ["code": error.code, "message": error.message]], status: error.status)
    }

    var header: Data {
        let reasons = [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request",
                       401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                       413: "Payload Too Large", 415: "Unsupported Media Type",
                       422: "Unprocessable Content", 429: "Too Many Requests",
                       500: "Internal Server Error", 507: "Insufficient Storage"]
        return Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.length)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
    }
}

final class FrameHTTPConnection {
    private let connection: NWConnection
    private let allow: (FrameHTTPHead) throws -> Void
    private let respond: (FrameHTTPHead, Data) throws -> FrameHTTPResponse
    private let closed: () -> Void
    private var socketClosed = false
    private var headerBuffer = Data()
    private var body = Data()
    private var request: FrameHTTPHead?

    init(_ connection: NWConnection, allow: @escaping (FrameHTTPHead) throws -> Void,
         respond: @escaping (FrameHTTPHead, Data) throws -> FrameHTTPResponse, closed: @escaping () -> Void) {
        self.connection = connection
        self.allow = allow
        self.respond = respond
        self.closed = closed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.read()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.close() }
    }

    func close() {
        guard !socketClosed else { return }
        socketClosed = true
        connection.cancel()
        closed()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.socketClosed else { return }
            do {
                if let data, !data.isEmpty, try self.consume(data) { return }
                if complete || error != nil { self.close() } else { self.read() }
            } catch let error as FrameAPIError {
                self.send(.failure(error))
            } catch {
                self.send(.failure(FrameAPIError(500, "internal_error", "Mac 无法处理此请求。")))
            }
        }
    }

    private func consume(_ data: Data) throws -> Bool {
        if let request {
            guard body.count + data.count <= request.length else {
                throw FrameAPIError(400, "invalid_http", "请求大小与声明不符。")
            }
            body.append(data)
        } else {
            headerBuffer.append(data)
            guard let split = headerBuffer.range(of: Data([13, 10, 13, 10])) else {
                if headerBuffer.count > 16_384 { throw FrameAPIError(413, "request_limit", "请求头过大。") }
                return false
            }
            guard split.lowerBound <= 16_384 else { throw FrameAPIError(413, "request_limit", "请求头过大。") }
            let head = try FrameHTTPHead(headerBuffer.prefix(upTo: split.lowerBound))
            try allow(head)
            request = head
            body = headerBuffer.suffix(from: split.upperBound)
            headerBuffer.removeAll()
        }
        guard let request, body.count >= request.length else { return false }
        guard body.count == request.length else {
            throw FrameAPIError(400, "invalid_http", "请求大小与声明不符。")
        }
        let response = try respond(request, body)
        body.removeAll()
        send(response)
        return true
    }

    private func send(_ response: FrameHTTPResponse) {
        connection.send(content: response.header, completion: .contentProcessed { [weak self] error in
            guard let self, !self.socketClosed else { return }
            guard error == nil else { self.close(); return }
            switch response.body {
            case .data(let data):
                self.connection.send(content: data, isComplete: true,
                    completion: .contentProcessed { [weak self] _ in self?.close() })
            case .file(let url, let length):
                guard let file = try? FileHandle(forReadingFrom: url) else { self.close(); return }
                self.sendFile(file, remaining: length)
            }
        })
    }

    private func sendFile(_ file: FileHandle, remaining: Int) {
        guard !socketClosed, remaining > 0, let data = try? file.read(upToCount: min(256 * 1024, remaining)),
              !data.isEmpty else { try? file.close(); close(); return }
        connection.send(content: data, isComplete: remaining == data.count,
                        completion: .contentProcessed { [weak self] error in
            if let self, error == nil, remaining > data.count {
                self.sendFile(file, remaining: remaining - data.count)
            } else {
                try? file.close()
                self?.close()
            }
        })
    }
}

struct FrameAddress: Identifiable, Hashable {
    let ip: IPv4Address
    let mask: IPv4Address
    var id: String { ip.debugDescription }

    func allows(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let peer) = host else { return false }
        // A listener bound to an interface also restricts its clients to that IPv4 subnet.
        return zip(zip(ip.rawValue, peer.rawValue), mask.rawValue).allSatisfy {
            ($0.0.0 & $0.1) == ($0.0.1 & $0.1)
        }
    }

    static func available() -> [Self] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [Self] = []
        var current: UnsafeMutablePointer<ifaddrs>? = list
        while let item = current?.pointee {
            current = item.ifa_next
            guard item.ifa_flags & UInt32(IFF_UP | IFF_LOOPBACK) == UInt32(IFF_UP),
                  String(cString: item.ifa_name).hasPrefix("en"),
                  let host = address(item.ifa_addr), isPrivate(host), let netmask = address(item.ifa_netmask) else { continue }
            addresses.append(Self(ip: host, mask: netmask))
        }
        return addresses
    }

    private static func isPrivate(_ address: IPv4Address) -> Bool {
        let bytes = Array(address.rawValue)
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }

    private static func address(_ value: UnsafeMutablePointer<sockaddr>?) -> IPv4Address? {
        guard let value, value.pointee.sa_family == UInt8(AF_INET) else { return nil }
        var address = value.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return withUnsafeBytes(of: &address) { IPv4Address(Data($0)) }
    }
}

struct FrameTLS: Codable {
    let serverId: UUID
    let certificate: Data
    let privateKey: Data

    var fingerprint: String { frameDigest(certificate) }

    func parameters() throws -> NWParameters {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let certificate = SecCertificateCreateWithData(nil, certificate as CFData),
              let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, nil),
              let identity = SecIdentityCreate(nil, certificate, key).flatMap(sec_identity_create) else {
            throw StudioError("无法读取局域网连接证书。")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func load(in root: URL) throws -> Self {
        let file = root.appendingPathComponent("identity.json")
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }
        let scratch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try framePrivateDirectory(scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pem = scratch.appendingPathComponent("key.pem")
        let key = scratch.appendingPathComponent("key.der")
        let cert = scratch.appendingPathComponent("certificate.der")
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                     "-subj", "/CN=MFlux Studio", "-keyout", pem.path, "-outform", "DER", "-out", cert.path])
        try openssl(["rsa", "-in", pem.path, "-outform", "DER", "-out", key.path])
        let identity = Self(serverId: UUID(), certificate: try Data(contentsOf: cert), privateKey: try Data(contentsOf: key))
        try frameWrite(identity, to: file)
        return identity
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StudioError("无法生成局域网连接证书。") }
    }
}

func frameDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func frameSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw StudioError("无法生成配对凭证。")
    }
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func framePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

func frameWrite<T: Encodable>(_ value: T, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: file, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
