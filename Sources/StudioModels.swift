import Foundation

struct PixelResolution: Hashable {
    let width: Int
    let height: Int
    var longEdge: Int { max(width, height) }
    var label: String { "\(width) × \(height)" }

    func isValid(step: Int) -> Bool { width >= step && height >= step && width % step == 0 && height % step == 0 }
}

enum OutputRatio: String, CaseIterable, Identifiable {
    case original = "跟随原图比例"
    case square = "1:1"
    case landscape4x3 = "4:3"
    case portrait3x4 = "3:4"
    case landscape3x2 = "3:2"
    case portrait2x3 = "2:3"
    case landscape5x4 = "5:4"
    case portrait4x5 = "4:5"
    case landscape16x9 = "16:9"
    case portrait9x16 = "9:16"
    case landscape21x9 = "21:9"
    case portrait9x21 = "9:21"
    case free = "自由"

    var id: Self { self }

    var dimensions: PixelResolution? {
        let parts = rawValue.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return PixelResolution(width: parts[0], height: parts[1])
    }
}

struct GenerationSize {
    var ratio: OutputRatio
    var resolution: PixelResolution?
    var width = 1024
    var height = 1024
    var preferSourceSize = false

    func options(source: PixelResolution?, step: Int) -> [PixelResolution] {
        let aspect = ratio == .original ? source : ratio.dimensions
        guard let aspect else { return [] }
        let maxEdge = 2048
        var edges = [512, 768, 1024, 1280, 1536, maxEdge]
        if ratio == .original, preferSourceSize { edges.append(min(maxEdge, aspect.longEdge)) }
        let divisor = gcd(aspect.width, aspect.height)
        let exactWidth = aspect.width / divisor * step
        let exactHeight = aspect.height / divisor * step
        let exactEdge = max(exactWidth, exactHeight)
        var resolutions = Set<PixelResolution>()
        if exactEdge <= maxEdge / 2 {
            for edge in edges {
                let factor = max(1, min(maxEdge / exactEdge, Int((Double(edge) / Double(exactEdge)).rounded())))
                resolutions.insert(PixelResolution(width: exactWidth * factor, height: exactHeight * factor))
            }
        } else {
            // A coprime source can require an impractically large exact grid. Round each size to the model grid.
            for edge in edges {
                let scale = Double(edge) / Double(aspect.longEdge) / Double(step)
                let width = max(1, Int((Double(aspect.width) * scale).rounded())) * step
                let height = max(1, Int((Double(aspect.height) * scale).rounded())) * step
                resolutions.insert(PixelResolution(width: width, height: height))
            }
        }
        if ratio == .original, aspect.longEdge <= maxEdge, aspect.isValid(step: step) { resolutions.insert(aspect) }
        return resolutions.sorted { ($0.longEdge, $0.width, $0.height) < ($1.longEdge, $1.width, $1.height) }
    }

    func choose(from options: [PixelResolution], source: PixelResolution?) -> PixelResolution? {
        if let resolution, options.contains(resolution) { return resolution }
        let sourceEdge = source?.longEdge ?? 1024
        let defaultEdge = ratio == .original ? (preferSourceSize ? sourceEdge : min(1024, sourceEdge)) : 768
        let preferredEdge = resolution?.longEdge ?? defaultEdge
        return options.min { abs($0.longEdge - preferredEdge) < abs($1.longEdge - preferredEdge) }
    }

    private func gcd(_ width: Int, _ height: Int) -> Int {
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

enum ModelGroup: String, CaseIterable, Identifiable {
    case flux2Small = "flux2-klein-4b"
    case flux2Large = "flux2-klein-9b"
    case flux3 = "flux3"
    case zImage = "z-image"
    case qwen = "qwen-image-2512"
    case qwen21 = "qwen-image-2.1"
    case krea2 = "krea-2"
    case anima = "anima"
    case flux1 = "flux1"
    case fill = "flux1-fill"
    case seedvr2 = "seedvr2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flux2Small: "FLUX.2 Klein 4B"
        case .flux2Large: "FLUX.2 Klein 9B"
        case .flux3: "FLUX.3 Image Klein"
        case .zImage: "Z-Image"
        case .qwen: "Qwen-Image 2512"
        case .qwen21: "Qwen-Image 2.1"
        case .krea2: "Krea 2"
        case .anima: "Anima"
        case .flux1: "FLUX.1"
        case .fill: "FLUX.1 Fill"
        case .seedvr2: "SeedVR2"
        }
    }

    var componentFolders: [String] {
        switch self {
        case .flux3: ["text_encoder", "vae"]
        case .qwen21: ["text_encoder", "processor", "vae"]
        case .seedvr2: ["vae"]
        case .flux1, .fill: ["text_encoder", "text_encoder_2", "tokenizer", "tokenizer_2", "vae"]
        case .anima: ["text_encoder", "tokenizer", "tokenizer_2", "vae"]
        default: ["text_encoder", "tokenizer", "vae"]
        }
    }

    var optionalPaths: [String] { ["scheduler", "model_index.json", "manifest.json", "chat_template.jinja", "added_tokens.json"] }
}

struct Family: Identifiable {
    let id: String
    let group: ModelGroup
    let variant: String
    let command: String
    let steps: Int
    let upstream: String
    let presetRepo: String
    let downloadBytes: Int64
    let componentDownloadBytes: Int64
    var label: String { group == .qwen ? group.title : "\(group.title) · \(variant)" }

    var canCreate: Bool { group != .seedvr2 && group != .fill }
    var canRepair: Bool { group == .fill || group == .qwen21 }
    var usesInitImage: Bool { [.flux1, .zImage, .qwen, .krea2].contains(group) }
    var referenceLimit: Int? {
        if usesInitImage { return 1 }
        return [.flux3, .qwen21].contains(group) ? 10 : nil
    }
    var canReference: Bool { usesInitImage || editCommand != nil }
    var dimensionStep: Int { group == .qwen21 ? 32 : 16 }
    var quantizationLabel: String { group == .seedvr2 ? "FP16" : "Q4" }
    var seedTransformerFile: String { "seedvr2_ema_3b_fp16.safetensors" }
    var editCommand: String? {
        switch group {
        case .flux2Small, .flux2Large: "mflux-generate-flux2-edit"
        case .flux3: "mflux-generate-flux3-edit"
        case .qwen21: "mflux-generate-qwen-2.1-edit"
        default: nil
        }
    }

    var minimumSteps: Int { group == .qwen21 ? 2 : 1 }
    var isQwen21Turbo: Bool { id == "qwen-image-2.1-turbo" }

    var guidanceDefault: Double? {
        switch group {
        case .flux2Small, .flux2Large: id.contains("-base-") ? 1 : nil
        case .flux3: id.hasSuffix("-base") ? 3.5 : nil
        case .flux1: id == "dev" ? 3.5 : nil
        case .fill: 30
        case .zImage: id == "z-image" ? 4 : nil
        case .qwen: 3.5
        case .qwen21: isQwen21Turbo ? nil : 1
        case .krea2: 1
        case .anima: id == "anima-turbo" ? 1 : 4
        case .seedvr2: nil
        }
    }

    var acceptsNegativePrompt: Bool {
        ([.qwen, .qwen21, .krea2, .anima].contains(group) && !isQwen21Turbo) || id == "z-image"
    }

    func samplers(referenced: Bool) -> [Sampler] {
        switch group {
        case .krea2, .anima: [.linearEuler, .erSDE]
        case .qwen21: referenced || isQwen21Turbo ? [] : [.linear, .flowMatch]
        case .flux1, .fill, .qwen, .zImage: [.linear, .flowMatch]
        default: []
        }
    }

    func samplerLabel(referenced: Bool) -> String {
        switch group {
        case .flux2Small, .flux2Large: "Flow Match Euler"
        case .flux3: "Flow Map"
        case .seedvr2: "SeedVR2 Euler"
        case .qwen21: isQwen21Turbo ? "Qwen-Image 2.1 Turbo" : referenced ? "Linear Euler" : "模型默认"
        default: "模型默认"
        }
    }

    func sharesComponents(with other: Family) -> Bool {
        guard group == other.group else { return false }
        // Both 4B variants use the same Qwen3, VAE and tokenizer definitions, as do
        // the 9B variants. Other presets use the declared version's own package.
        return group == .flux2Small || group == .flux2Large || id == other.id
    }

    // Byte counts from the Hugging Face file manifests on 2026-11-19, using the app's preset download filters.
    static let all: [Family] = [
        Family(id: "flux2-klein-4b", group: .flux2Small, variant: "蒸馏", command: "mflux-generate-flux2", steps: 4, upstream: "black-forest-labs/FLUX.2-klein-4B", presetRepo: "mlx-community/flux2-klein-4b-4bit",
               downloadBytes: 4_619_708_452, componentDownloadBytes: 2_439_622_286),
        Family(id: "flux2-klein-base-4b", group: .flux2Small, variant: "Base", command: "mflux-generate-flux2", steps: 50, upstream: "black-forest-labs/FLUX.2-klein-base-4B", presetRepo: "mflux-community/flux-2-klein-base-4b-mflux-q4",
               downloadBytes: 4_619_704_418, componentDownloadBytes: 2_439_624_433),
        Family(id: "flux2-klein-9b", group: .flux2Large, variant: "蒸馏", command: "mflux-generate-flux2", steps: 4, upstream: "black-forest-labs/FLUX.2-klein-9B", presetRepo: "mflux-community/flux2-klein-9b-mflux-q4",
               downloadBytes: 9_541_196_072, componentDownloadBytes: 4_434_375_761),
        Family(id: "flux2-klein-base-9b", group: .flux2Large, variant: "Base", command: "mflux-generate-flux2", steps: 50, upstream: "black-forest-labs/FLUX.2-klein-base-9B", presetRepo: "mflux-community/flux-2-klein-base-9b-mflux-q4",
               downloadBytes: 9_541_196_290, componentDownloadBytes: 4_434_375_979),
        Family(id: "flux2-klein-9b-kv", group: .flux2Large, variant: "KV", command: "mflux-generate-flux2", steps: 4, upstream: "black-forest-labs/FLUX.2-klein-9b-kv", presetRepo: "mflux-community/flux2-klein-9b-kv-mflux-q4",
               downloadBytes: 9_541_196_147, componentDownloadBytes: 4_434_375_836),
        Family(id: "flux3-image-klein", group: .flux3, variant: "蒸馏", command: "mflux-generate-flux3", steps: 16, upstream: "black-forest-labs/flux-3-image-klein", presetRepo: "mflux-community/flux-3-image-klein-mflux-q4",
               downloadBytes: 5_333_804_349, componentDownloadBytes: 2_212_484_135),
        Family(id: "flux3-image-klein-base", group: .flux3, variant: "Base", command: "mflux-generate-flux3", steps: 50, upstream: "black-forest-labs/flux-3-image-klein-base", presetRepo: "mflux-community/flux-3-image-klein-base-mflux-q4",
               downloadBytes: 5_328_052_603, componentDownloadBytes: 2_212_484_250),
        Family(id: "z-image-turbo", group: .zImage, variant: "Turbo", command: "mflux-generate-z-image-turbo", steps: 9, upstream: "Tongyi-MAI/Z-Image-Turbo", presetRepo: "mflux-community/z-image-turbo-mflux-q4",
               downloadBytes: 5_902_988_435, componentDownloadBytes: 2_439_170_606),
        Family(id: "z-image", group: .zImage, variant: "Base", command: "mflux-generate-z-image", steps: 50, upstream: "Tongyi-MAI/Z-Image", presetRepo: "mflux-community/z-image-base-mflux-q4",
               downloadBytes: 5_902_988_438, componentDownloadBytes: 2_439_170_609),
        Family(id: "qwen-image", group: .qwen, variant: "2512", command: "mflux-generate-qwen", steps: 20, upstream: "Qwen/Qwen-Image-2512", presetRepo: "mflux-community/qwen-image-2512-mflux-q4",
               downloadBytes: 27_605_818_500, componentDownloadBytes: 14_406_332_320),
        Family(id: "qwen-image-2.1-turbo", group: .qwen21, variant: "Turbo", command: "mflux-generate-qwen-2.1", steps: 8, upstream: "Qwen/Qwen-Image-2.1-Turbo", presetRepo: "mflux-community/qwen-image-2-1-turbo-mflux-q4",
               downloadBytes: 9_963_448_387, componentDownloadBytes: 5_814_824_075),
        Family(id: "qwen-image-2.1", group: .qwen21, variant: "Base", command: "mflux-generate-qwen-2.1", steps: 40, upstream: "Qwen/Qwen-Image-2.1", presetRepo: "mflux-community/qwen-image-2-1-mflux-q4",
               downloadBytes: 10_638_928_735, componentDownloadBytes: 6_490_304_423),
        Family(id: "krea-2", group: .krea2, variant: "Turbo", command: "mflux-generate-krea2", steps: 8, upstream: "krea/Krea-2-Turbo", presetRepo: "mflux-community/krea-2-turbo-mflux-q4",
               downloadBytes: 15_777_189_828, componentDownloadBytes: 8_563_597_399),
        Family(id: "anima-turbo", group: .anima, variant: "Turbo", command: "mflux-generate-anima", steps: 10, upstream: "circlestone-labs/Anima", presetRepo: "mflux-community/anima-turbo-mflux-q4",
               downloadBytes: 3_109_460_892, componentDownloadBytes: 1_459_608_301),
        Family(id: "anima-base", group: .anima, variant: "Base", command: "mflux-generate-anima", steps: 30, upstream: "circlestone-labs/Anima", presetRepo: "mflux-community/anima-base-mflux-q4",
               downloadBytes: 3_109_460_877, componentDownloadBytes: 1_459_608_286),
        Family(id: "anima-aesthetic", group: .anima, variant: "Aesthetic", command: "mflux-generate-anima", steps: 30, upstream: "circlestone-labs/Anima", presetRepo: "mflux-community/anima-aesthetic-mflux-q4",
               downloadBytes: 3_109_460_952, componentDownloadBytes: 1_459_608_361),
        Family(id: "dev", group: .flux1, variant: "Dev", command: "mflux-generate", steps: 25, upstream: "black-forest-labs/FLUX.1-dev", presetRepo: "mflux-community/flux-1-dev-mflux-q4",
               downloadBytes: 9_618_821_681, componentDownloadBytes: 2_919_439_968),
        Family(id: "schnell", group: .flux1, variant: "Schnell", command: "mflux-generate", steps: 4, upstream: "black-forest-labs/FLUX.1-schnell", presetRepo: "mflux-community/flux-1-schnell-mflux-q4",
               downloadBytes: 9_613_057_027, componentDownloadBytes: 2_919_439_911),
        Family(id: "dev-fill", group: .fill, variant: "Dev", command: "mflux-generate-fill", steps: 30, upstream: "black-forest-labs/FLUX.1-Fill-dev", presetRepo: "mflux-community/flux-1-dev-fill-mflux-q4",
               downloadBytes: 9_619_374_832, componentDownloadBytes: 2_919_440_158),
        Family(id: "seedvr2-3b", group: .seedvr2, variant: "3B", command: "mflux-upscale-seedvr2", steps: 1, upstream: "numz/SeedVR2_comfyUI", presetRepo: "numz/SeedVR2_comfyUI",
               downloadBytes: 7_284_343_622, componentDownloadBytes: 501_324_814),

    ]

    static func find(_ id: String) -> Family? { all.first { $0.id == id } }
}

enum Sampler: String, Identifiable {
    case automatic = ""
    case linear
    case flowMatch = "flow_match_euler_discrete"
    case linearEuler = "euler"
    case erSDE = "er_sde"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "模型默认"
        case .linear: "Linear Euler"
        case .flowMatch: "Flow Match Euler"
        case .linearEuler: "Euler"
        case .erSDE: "ER-SDE"
        }
    }
}

enum PackageKind: String, CaseIterable, Identifiable {
    case model = "完整模型"
    case components = "配套组件"
    case assembly = "组装底模"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .model: "cube"
        case .components: "square.stack.3d.up"
        case .assembly: "link"
        }
    }
}

struct ModelImportFiles: Codable, Equatable {
    var transformer: [URL] = []
    var components: [String: [URL]] = [:]
    var metadata: [URL] = []
    var componentSource: URL?

    var references: [URL] {
        transformer + components.values.flatMap { $0 } + metadata + [componentSource].compactMap { $0 }
    }
}

struct LocalModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var familyID: String
    var path: String
    var transformerPath: String? = nil
    var componentsOnly: Bool? = nil
    var presetRepo: String? = nil
    var importFiles: ModelImportFiles? = nil

    var folder: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var source: URL { transformerPath.map { URL(fileURLWithPath: $0) } ?? folder }
    var family: Family? { Family.find(familyID) }
    var kind: PackageKind {
        if transformerPath != nil || importFiles?.componentSource != nil { return .assembly }
        return componentsOnly == true ? .components : .model
    }
    var referencedPaths: [URL] { [folder, source] + (importFiles?.references ?? []) }
}

enum PackageLayout {
    private static let fm = FileManager.default
    private static let ownershipFile = ".mflux-studio-package.json"

    struct Identity: Codable {
        let familyID: String
        let repo: String
        let componentsOnly: Bool
    }

    static func directory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func identity(at folder: URL) -> Identity? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ownershipFile)) else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: data)
    }

    static func record(_ identity: Identity, at folder: URL) throws {
        try JSONEncoder().encode(identity).write(to: folder.appendingPathComponent(ownershipFile), options: .atomic)
    }

    private static func json(_ file: URL) -> [String: Any]? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 2_000_000,
              let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func knownFamily(at folder: URL) -> Family? {
        if let id = identity(at: folder)?.familyID { return Family.find(id) }
        guard let manifest = json(folder.appendingPathComponent("mflux_model.json")) else { return nil }
        let values = [manifest["base_model"] as? String, manifest["model_name"] as? String,
                      (manifest["upstream"] as? [String: Any])?["repo_id"] as? String]
        for value in values.compactMap({ $0 }) {
            let matches = Family.all.filter { [$0.id, $0.upstream, $0.presetRepo].contains { $0.caseInsensitiveCompare(value) == .orderedSame } }
            if matches.count == 1 { return matches.first }
        }
        return nil
    }

    static func validateComponents(at root: URL, family: Family) throws {
        guard directory(root) else { throw StudioError("找不到模型目录。") }
        if let known = knownFamily(at: root), !family.sharesComponents(with: known) {
            throw StudioError("该目录属于 \(known.label)。请选择对应的模型分类。")
        }
        if family.group == .seedvr2, fm.isReadableFile(atPath: root.appendingPathComponent("ema_vae_fp16.safetensors").path) { return }
        for part in family.group.componentFolders {
            let folder = root.appendingPathComponent(part)
            guard directory(folder) else { throw StudioError("此架构的配套目录缺少 \(part)/。") }
            if part.hasPrefix("text_encoder") || part == "vae" {
                guard !weightFiles(in: folder).isEmpty else { throw StudioError("\(part)/ 里缺少 .safetensors 权重。") }
            } else {
                let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                guard !files.isEmpty else { throw StudioError("\(part)/ 里缺少配置或词表。") }
            }
        }
        if family.group == .flux2Small || family.group == .flux2Large {
            try validateKleinEncoder(at: root.appendingPathComponent("text_encoder"), family: family)
        }
    }

    private static func validateKleinEncoder(at folder: URL, family: Family) throws {
        let expectedWidth = family.group == .flux2Small ? 2560 : 4096
        for file in weightFiles(in: folder) {
            let header = try weightsHeader(file)
            for prefix in ["embed_tokens", "model.embed_tokens"] {
                guard let tensor = header[prefix + ".weight"] as? [String: Any],
                      let shape = tensor["shape"] as? [Int], shape.count == 2 else { continue }
                let width: Int
                if tensor["dtype"] as? String == "U32" {
                    let metadata = header["__metadata__"] as? [String: String]
                    guard let scales = header[prefix + ".scales"] as? [String: Any],
                          let scaleShape = scales["shape"] as? [Int], scaleShape.count == 2 else { continue }
                    let groupSize = metadata?["quantization_group_size"].flatMap(Int.init) ?? 64
                    guard [32, 64, 128].contains(groupSize), (1...128).contains(scaleShape[1]) else { continue }
                    width = scaleShape[1] * groupSize
                } else {
                    width = shape[1]
                }
                guard width == expectedWidth else {
                    throw StudioError("文本编码器的尺寸与 \(family.group.title) 不匹配。")
                }
                return
            }
        }
    }

    static func transformer(at root: URL, family: Family) -> URL {
        let subfolder = root.appendingPathComponent("transformer")
        if family.group == .seedvr2 && !directory(subfolder) {
            return root.appendingPathComponent(family.seedTransformerFile)
        }
        if family.group == .krea2, !directory(subfolder) { return root }
        return subfolder
    }

    static func weightFiles(in location: URL) -> [URL] {
        if !directory(location), location.pathExtension.lowercased() == "safetensors",
           fm.isReadableFile(atPath: location.path) { return [location] }
        let files = try? fm.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return (files ?? []).filter { $0.pathExtension.lowercased() == "safetensors" && fm.isReadableFile(atPath: $0.path) && !directory($0) }
    }

    static func validateSelectedShards(in files: [URL]) throws {
        let names = Set(files.map(\.lastPathComponent))
        for index in files where index.lastPathComponent.hasSuffix(".safetensors.index.json") {
            guard let data = try? Data(contentsOf: index),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weights = document["weight_map"] as? [String: String], !weights.isEmpty else {
                throw StudioError("无法读取分片索引 \(index.lastPathComponent)。")
            }
            if let missing = Set(weights.values).subtracting(names).sorted().first {
                throw StudioError("索引 \(index.lastPathComponent) 还需要文件 \(missing)。请一并选取。")
            }
        }
    }

    private static func weightsHeader(_ file: URL) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let lengthBytes = try handle.read(upToCount: 8), lengthBytes.count == 8 else {
            throw StudioError("无法读取权重文件 \(file.lastPathComponent)。")
        }
        let length = lengthBytes.enumerated().reduce(UInt64(0)) { result, item in
            result | (UInt64(item.element) << (item.offset * 8))
        }
        guard length > 0, length <= 16 * 1024 * 1024,
              let data = try handle.read(upToCount: Int(length)),
              let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudioError("无法读取权重文件 \(file.lastPathComponent)。")
        }
        return header
    }

    static func validateTransformer(at location: URL, family: Family) throws {
        let files = weightFiles(in: location)
        guard !files.isEmpty else { throw StudioError("找不到 Transformer 的 .safetensors 权重。") }
        var keys = Set<String>()
        var widths: [String: Int] = [:]
        var inputWidth: Int?
        for file in files {
            let header = try weightsHeader(file)
            keys.formUnion(header.keys)
            if let tensor = header["x_embedder.weight"] as? [String: Any],
               let shape = tensor["shape"] as? [Int], shape.count == 2 {
                if tensor["dtype"] as? String == "U32" {
                    if let scale = header["x_embedder.scales"] as? [String: Any], let dims = scale["shape"] as? [Int],
                       dims.count == 2, (1...1024).contains(dims[1]) {
                        let metadata = header["__metadata__"] as? [String: String]
                        let size = metadata?["quantization_group_size"].flatMap(Int.init) ?? 64
                        if [32, 64, 128].contains(size) { inputWidth = dims[1] * size }
                    }
                } else { inputWidth = shape[1] }
            }
            for name in ["x_embedder.weight", "context_embedder.weight"] {
                if let tensor = header[name] as? [String: Any], let shape = tensor["shape"] as? [Int] {
                    widths[name] = shape.first
                }
            }
        }
        let matches: Bool
        switch family.group {
        case .flux2Small, .flux2Large:
            let width = family.group == .flux2Small ? 3072 : 4096
            matches = widths["x_embedder.weight"] == width && widths["context_embedder.weight"] == width
                && !keys.contains("x_embedder.bias")
        case .flux3:
            let hasTargetTime = keys.contains("target_timestep_embedder.linear_1.weight")
            matches = keys.contains("x_embedders.image.weight") && keys.contains("x_embedders.image_cond.weight")
                && hasTargetTime == (family.id == "flux3-image-klein")
        case .flux1, .fill:
            let expectedWidth = family.group == .fill ? 384 : 64
            matches = keys.contains("x_embedder.bias") && keys.contains("context_embedder.bias") && inputWidth == expectedWidth
        case .seedvr2:
            matches = keys.contains { $0.hasPrefix("blocks.31.") } && !keys.contains { $0.hasPrefix("blocks.32.") }
        case .zImage:
            matches = keys.contains { $0.hasPrefix("context_refiner.") }
                && keys.contains { $0.hasPrefix("noise_refiner.") }
        case .qwen:
            matches = keys.contains("img_in.weight") && keys.contains("txt_in.weight")
        case .qwen21:
            matches = keys.contains("img_in.weight") && keys.contains("txt_in.in_layer.weight")
        case .krea2:
            matches = keys.contains("first.weight") && keys.contains { $0.hasPrefix("txtfusion.") }
        case .anima:
            matches = keys.contains { $0.hasPrefix("llm_adapter.blocks.") }
        }
        guard matches else {
            throw StudioError("这份 Transformer 的结构不匹配 \(family.label)，请确认架构和权重格式。")
        }
    }
}
