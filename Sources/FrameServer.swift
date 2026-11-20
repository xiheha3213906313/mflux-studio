import Combine
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

struct FrameDevice: Codable, Identifiable {
    let id: UUID
    let name: String
    let tokenDigest: String
}

enum FrameJobState: String, Codable {
    case queued, running, succeeded, failed, cancelled

    var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "推理中"
        case .succeeded: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    var active: Bool { self == .queued || self == .running }
}

struct FrameJob: Codable, Identifiable {
    struct Output: Codable {
        let width: Int
        let height: Int
        let elapsed: TimeInterval
    }

    let id: UUID
    let deviceId: UUID
    let requestDigest: String
    let created: Date
    let plan: FramePlan
    var state: FrameJobState = .queued
    var failureCode: String?
    var message: String?
    var output: Output?
    var finished: Date?

    var key: String { deviceId.uuidString + "-" + id.uuidString }

    var json: [String: Any] {
        let serialized = (try? JSONEncoder().encode(plan.options))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        var result: [String: Any] = [
            "id": id.uuidString, "state": state.rawValue, "operation": plan.operation.rawValue,
            "modelId": plan.modelId.uuidString, "modelName": plan.modelName, "familyId": plan.familyId,
            "createdAt": ISO8601DateFormatter().string(from: created), "options": serialized
        ]
        if let output {
            result["output"] = ["width": output.width, "height": output.height, "elapsedSeconds": output.elapsed,
                                "path": "/v1/jobs/\(id.uuidString)/output", "mimeType": "image/png"] as [String: Any]
        }
        if let failureCode { result["error"] = ["code": failureCode, "message": message ?? "任务失败。"] }
        return result
    }
}

final class FrameServer: ObservableObject {
    private weak var studio: Studio?
    private let root: URL
    private let files = FileManager.default
    private let preferences: UserDefaults
    private static let enabledKey = "FrameStudioConnectionEnabled"
    private static let interfaceKey = "FrameStudioConnectionInterface"
    private var monitor: Timer?
    private var listener: NWListener?
    private var boundInterface: FrameAddress?
    private var identity: FrameTLS?
    private var connections: [UUID: FrameHTTPConnection] = [:]
    private var pairing: FramePairing?
    private var records: [String: FrameJob] = [:]
    private var activeKey: String?
    private var cancellationPending = false
    private var loaded = false

    @Published private(set) var enabled: Bool
    @Published private(set) var address: String?
    @Published private(set) var starting = false
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairExpires: Date?
    @Published private(set) var devices: [FrameDevice] = []
    @Published private(set) var jobs: [FrameJob] = []
    @Published private(set) var error: String?

    init(studio: Studio, preferences: UserDefaults = .standard) {
        self.studio = studio
        self.preferences = preferences
        enabled = preferences.bool(forKey: Self.enabledKey)
        root = studio.root.appendingPathComponent(".FrameStudio", isDirectory: true)
    }

    deinit {
        monitor?.invalidate()
        listener?.cancel()
    }

    var preferredInterface: String? { preferences.string(forKey: Self.interfaceKey) }

    func restorePreference() {
        guard enabled, monitor == nil else { return }
        refreshInterface()
        monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshInterface()
        }
    }

    func setEnabled(_ value: Bool, interface: FrameAddress?) {
        guard enabled != value else { return }
        if value {
            preferences.set(interface?.interfaceName, forKey: Self.interfaceKey)
        }
        preferences.set(value, forKey: Self.enabledKey)
        enabled = value
        if value {
            restorePreference()
        } else {
            monitor?.invalidate()
            monitor = nil
            stop()
            error = nil
        }
    }

    private func refreshInterface() {
        let addresses = FrameAddress.available()
        let selected = preferredInterface == nil ? addresses.first
            : addresses.first { $0.interfaceName == preferredInterface }
        guard selected != boundInterface || listener == nil else { return }
        if listener != nil { stop() }
        if let selected { start(on: selected) }
    }
    private var jobRoot: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    private var deviceFile: URL { root.appendingPathComponent("devices.json") }

    func start(on interface: FrameAddress, port: NWEndpoint.Port = 42817) {
        guard listener == nil else { return }
        do {
            try load()
            let identity = try FrameTLS.load(in: root)
            let parameters = try identity.parameters()
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(interface.ip), port: port)
            let listener = try NWListener(using: parameters)
            if interface.interfaceName != "lo0" {
                let record = NWTXTRecord(["v": "1", "ipv4": interface.id, "serverId": identity.serverId.uuidString])
                listener.service = NWListener.Service(name: nil, type: "_mflux-studio._tcp", txtRecord: record)
            }
            self.listener = listener
            boundInterface = interface
            self.identity = identity
            error = nil
            starting = true
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let port = listener.port { self.address = "https://\(interface.id):\(port.rawValue)" }
                    self.starting = false
                    self.resumeQueue()
                case .failed(let error), .waiting(let error):
                    self.stop()
                    self.error = "局域网服务启动失败：\(error.localizedDescription)"
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 6, interface.allows(connection.endpoint) else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener.start(queue: .main)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        let current = listener
        listener = nil
        boundInterface = nil
        current?.cancel()
        let activeConnections = Array(connections.values)
        for connection in activeConnections { connection.close(reason: "service_stop") }
        address = nil
        starting = false
        clearPairing()
    }

    func newPairing() {
        guard address != nil else { return }
        do {
            let session = try FramePairing()
            pairing = session
            pairingCode = session.displayCode
            pairExpires = session.expires
            error = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + FramePairing.lifetime) { [weak self] in
                if self?.pairing?.expires == session.expires { self?.clearPairing() }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func clearPairing() {
        pairing = nil
        pairingCode = nil
        pairExpires = nil
    }

    func revoke(_ id: UUID) {
        do {
            let remaining = devices.filter { $0.id != id }
            try frameWrite(remaining, to: deviceFile)
            devices = remaining
            let active = records.values.filter { $0.deviceId == id && $0.state.active }
            for job in active { try cancel(job) }
        } catch { self.error = error.localizedDescription }
    }

    func cancelFromMac(_ job: FrameJob) {
        do {
            if let current = records[job.key] { try cancel(current) }
        } catch { self.error = error.localizedDescription }
    }

    func resumeQueue() {
        guard address != nil, activeKey == nil, let studio, !studio.running else { return }
        guard var next = records.values.filter({ $0.state == .queued }).min(by: { $0.created < $1.created }) else { return }
        next.state = .running
        do {
            try save(next)
        } catch {
            // A job may run only after the running state has reached disk.
            self.error = "无法保存任务状态，请检查 Mac 的存储空间。"
            stop()
            return
        }
        let plan = next.plan
        let dir = directory(next.key)
        let key = next.key
        activeKey = key
        cancellationPending = false
        let input = (0..<plan.inputCount).compactMap { ReferenceImage(url: inputFile(dir, at: $0)) }
        do {
            try studio.runFramePlan(plan, input: input, output: outputFile(dir)) { [weak self] result in
                self?.finish(key, result)
            }
        } catch {
            finish(key, .failure(error))
        }
    }

    private func finish(_ key: String, _ result: Result<StudioResult, Error>) {
        guard var job = records[key], activeKey == key else { return }
        activeKey = nil
        let wasCancelled = cancellationPending
        cancellationPending = false
        job.finished = Date()
        switch result {
        case .success(let result) where !wasCancelled:
            job.state = .succeeded
            job.output = .init(width: result.image.width, height: result.image.height, elapsed: result.elapsed)
        case .failure(let error) where !wasCancelled && (error as? FrameAPIError)?.code != "cancelled":
            job.state = .failed
            job.failureCode = (error as? FrameAPIError)?.code ?? "inference_failed"
            job.message = (error as? FrameAPIError)?.message ?? "Mac 推理失败。请在 MFlux Studio 查看运行日志。"
        default:
            job.state = .cancelled
        }
        do { try save(job) }
        catch {
            self.error = "无法保存任务结果，请检查 Mac 的存储空间。"
            loaded = false
            stop()
            return
        }
        cleanInputs(job)
        DispatchQueue.main.async { [weak self] in self?.resumeQueue() }
    }

    private func cancel(_ job: FrameJob) throws {
        if job.state == .queued {
            var updated = job
            updated.state = .cancelled
            updated.finished = Date()
            try save(updated)
            cleanInputs(updated)
        } else if job.state == .running && activeKey == job.key {
            cancellationPending = true
            studio?.stop()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let client = FrameHTTPConnection(connection, allow: { [weak self] head in
            guard let self else { throw FrameAPIError(500, "internal_error", "服务已关闭。") }
            try self.allow(head)
        }, respond: { [weak self] head, body in
            guard let self else { throw FrameAPIError(500, "internal_error", "服务已关闭。") }
            return try self.respond(head, body: body)
        }, closed: { [weak self] in
            self?.connections.removeValue(forKey: id)
        })
        connections[id] = client
        client.start()
    }

    private func allow(_ head: FrameHTTPHead) throws {
        let pairing = head.method == "POST" && ["/v1/pair/challenge", "/v1/pair"].contains(head.path)
        if !pairing { _ = try authenticate(head) }
        let submit = head.method == "POST" && head.path == "/v1/jobs"
        let limit = submit ? 64 * 1024 * 1024 : pairing ? 2048 : 0
        guard head.length <= limit else { throw FrameAPIError(413, "request_limit", "请求内容超过上限。") }
        if pairing || submit {
            guard head.length > 0, head.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else {
                throw FrameAPIError(415, "content_type", "请提交 application/json。")
            }
        }
    }

    private func authenticate(_ head: FrameHTTPHead) throws -> FrameDevice {
        guard let auth = head.headers["authorization"], auth.hasPrefix("Bearer "), auth.count == 50 else {
            throw FrameAPIError(401, "unauthorized", "请先配对 MFlux Studio。")
        }
        let digest = frameDigest(Data(auth.dropFirst(7).utf8))
        guard let device = devices.first(where: { $0.tokenDigest == digest }) else {
            throw FrameAPIError(401, "unauthorized", "设备凭证已失效，请重新配对。")
        }
        return device
    }

    private func respond(_ head: FrameHTTPHead, body: Data) throws -> FrameHTTPResponse {
        if head.method == "POST" && head.path == "/v1/pair/challenge" { return try pairingChallenge(body) }
        if head.method == "POST" && head.path == "/v1/pair" { return try pair(body) }
        let device = try authenticate(head)
        if head.method == "GET" && head.path == "/v1/models", let studio, let identity {
            return .json(["version": 1, "serverId": identity.serverId.uuidString, "models": studio.frameCatalog(),
                          "limits": ["maxBodyBytes": 64 * 1024 * 1024, "maxInputBytes": 24 * 1024 * 1024,
                                     "maxInputPixels": 50_000_000, "maxInputEdge": 12000, "retentionDays": 7]])
        }
        if head.method == "POST" && head.path == "/v1/jobs" { return try submit(body, device: device) }
        let segments = head.path.split(separator: "/", omittingEmptySubsequences: false)
        guard (4...5).contains(segments.count), segments[1] == "v1", segments[2] == "jobs",
              let jobId = UUID(uuidString: String(segments[3])),
              let job = records[device.id.uuidString + "-" + jobId.uuidString] else {
            throw FrameAPIError(404, "not_found", "此设备没有该任务。")
        }
        switch (head.method, segments.count == 5 ? String(segments[4]) : "") {
        case ("GET", ""):
            return .json(job.json)
        case ("POST", "cancel"):
            do { try cancel(job) }
            catch { throw FrameAPIError(507, "storage_error", "Mac 无法保存任务状态。") }
            var response = records[job.key]?.json ?? job.json
            if activeKey == job.key && cancellationPending { response["cancelRequested"] = true }
            return .json(response, status: response["cancelRequested"] != nil ? 202 : 200)
        case ("GET", "output"):
            guard job.state == .succeeded else { throw FrameAPIError(409, "output_not_ready", "任务尚无可下载原图。") }
            guard let finished = job.finished, Date().timeIntervalSince(finished) <= 7 * 86400 else {
                throw FrameDownload.unavailable(job.id, reason: "expired")
            }
            let output = try FrameDownload.open(outputFile(directory(job.key)), jobId: job.id)
            return FrameHTTPResponse(status: 200, type: "image/png", body: .file(output))
        default:
            throw FrameAPIError(404, "not_found", "此接口不可用。")
        }
    }

    private var invalidPairing: FrameAPIError {
        FrameAPIError(403, "pairing_invalid", "配对码不正确或已过期。")
    }

    private func pairingChallenge(_ body: Data) throws -> FrameHTTPResponse {
        struct Challenge: Decodable { let nonce: String }
        guard let identity, let pairing, pairing.expires > Date(),
              let request = try? JSONDecoder().decode(Challenge.self, from: body),
              FramePairing.validHex(request.nonce) else { throw invalidPairing }
        return .json(["version": 1, "serverId": identity.serverId.uuidString,
                      "proof": pairing.proof(.server, nonce: request.nonce, identity: identity)])
    }

    private func pair(_ body: Data) throws -> FrameHTTPResponse {
        struct PairingRequest: Decodable {
            let nonce: String
            let proof: String
            let deviceName: String
        }
        guard let identity, let entry = try? JSONDecoder().decode(PairingRequest.self, from: body),
              let pairing, pairing.expires > Date(), FramePairing.validHex(entry.nonce),
              pairing.authorizes(entry.proof, nonce: entry.nonce, identity: identity) else { throw invalidPairing }
        let name = entry.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw FrameAPIError(422, "device_name", "请填写 1 到 60 字的设备名称。")
        }
        guard devices.count < 32 else { throw FrameAPIError(429, "device_limit", "请先在 Mac 移除闲置设备。") }
        let token = try frameSecret()
        let device = FrameDevice(id: UUID(), name: name, tokenDigest: frameDigest(Data(token.utf8)))
        let entries = devices + [device]
        do { try frameWrite(entries, to: deviceFile) }
        catch { throw FrameAPIError(507, "storage_error", "Mac 无法保存配对记录。") }
        devices = entries
        clearPairing()
        return .json(["version": 1, "serverId": identity.serverId.uuidString,
                      "deviceId": device.id.uuidString, "token": token], status: 201)
    }

    private func submit(_ body: Data, device: FrameDevice) throws -> FrameHTTPResponse {
        struct SubmissionID: Decodable { let id: UUID }
        guard let studio, let id = (try? JSONDecoder().decode(SubmissionID.self, from: body))?.id else {
            throw FrameAPIError(400, "invalid_json", "缺少有效的任务 ID。")
        }
        let digest = frameDigest(body)
        let key = device.id.uuidString + "-" + id.uuidString
        if let found = records[key] {
            guard found.requestDigest == digest else {
                throw FrameAPIError(409, "id_conflict", "同一任务 ID 的请求内容不同。")
            }
            return .json(found.json)
        }
        guard records.values.filter({ $0.state.active }).count < 24 else {
            throw FrameAPIError(429, "queue_full", "Mac 任务队列已满，请稍后重试。")
        }
        guard let request = try? JSONDecoder().decode(FrameSubmission.self, from: body) else {
            throw FrameAPIError(400, "invalid_json", "无法读取任务参数或图片数据。")
        }
        let inputs = request.inputs ?? []
        guard inputs.count <= 14, inputs.allSatisfy({ !$0.isEmpty && $0.count <= 24 * 1024 * 1024 }) else {
            throw FrameAPIError(413, "input_limit", "图片数量或文件大小超过上限。")
        }
        let temp = jobRoot.appendingPathComponent(".submission-" + UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: temp) }
        do {
            try framePrivateDirectory(temp)
            let images = try inputs.enumerated().map { index, input in
                let url = inputFile(temp, at: index)
                try input.write(to: url)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let type = CGImageSourceGetType(source) as String?,
                      [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(type),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (16...12000).contains(width), (16...12000).contains(height),
                      width * height <= 50_000_000, let image = ReferenceImage(url: url) else {
                    throw FrameAPIError(422, "invalid_image", "请提交符合尺寸限制的 PNG、JPEG 或 WebP 图片。")
                }
                return image
            }
            let plan = try studio.prepareFrameJob(request, input: images)
            let job = FrameJob(id: id, deviceId: device.id, requestDigest: digest, created: Date(), plan: plan)
            try frameWrite(job, to: temp.appendingPathComponent("job.json"))
            try files.moveItem(at: temp, to: directory(job.key))
            records[job.key] = job
            updateJobs()
            DispatchQueue.main.async { [weak self] in self?.resumeQueue() }
            return .json(job.json, status: 202)
        } catch let error as FrameAPIError {
            throw error
        } catch {
            throw FrameAPIError(507, "storage_error", "Mac 无法保存任务，请检查剩余空间。")
        }
    }

    private func directory(_ key: String) -> URL { jobRoot.appendingPathComponent(key, isDirectory: true) }
    private func inputFile(_ dir: URL, at index: Int) -> URL { dir.appendingPathComponent("input-\(index)") }
    private func outputFile(_ dir: URL) -> URL { dir.appendingPathComponent("output.png") }

    private func load() throws {
        guard !loaded else { return }
        try framePrivateDirectory(root)
        try framePrivateDirectory(jobRoot)
        if files.fileExists(atPath: deviceFile.path) {
            devices = try JSONDecoder().decode([FrameDevice].self, from: Data(contentsOf: deviceFile))
        }
        var recovered: [String: FrameJob] = [:]
        for dir in try files.contentsOfDirectory(at: jobRoot, includingPropertiesForKeys: nil) {
            if dir.lastPathComponent.hasPrefix(".submission-") {
                try? files.removeItem(at: dir)
                continue
            }
            let file = dir.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: file), var job = try? JSONDecoder().decode(FrameJob.self, from: data),
                  job.key == dir.lastPathComponent else { continue }
            if job.state == .running || (job.state == .queued && !devices.contains(where: { $0.id == job.deviceId })) {
                job.state = job.state == .running ? .failed : .cancelled
                job.finished = Date()
                if job.state == .failed {
                    job.failureCode = "interrupted"
                    job.message = "Mac 在处理此任务时退出。请重新生成。"
                }
                try frameWrite(job, to: file)
            }
            if !job.state.active { cleanInputs(job) }
            recovered[job.key] = job
        }
        records = recovered
        updateJobs()
        loaded = true
    }

    private func save(_ job: FrameJob) throws {
        try frameWrite(job, to: directory(job.key).appendingPathComponent("job.json"))
        records[job.key] = job
        updateJobs()
    }

    private func cleanInputs(_ job: FrameJob) {
        let dir = directory(job.key)
        for index in 0..<job.plan.inputCount { try? files.removeItem(at: inputFile(dir, at: index)) }
        if job.state != .succeeded { try? files.removeItem(at: outputFile(dir)) }
    }

    private func updateJobs() {
        // Keep the task ID record for replay protection after its output expires.
        for job in records.values where job.state == .succeeded {
            if let finished = job.finished, Date().timeIntervalSince(finished) > 7 * 86400 {
                try? files.removeItem(at: outputFile(directory(job.key)))
            }
        }
        jobs = Array(records.values.sorted { $0.created > $1.created }.prefix(30))
    }
}
