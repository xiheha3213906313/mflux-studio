import Foundation
import ImageIO
import UniformTypeIdentifiers

struct InferenceOptions {
    let steps: Int
    let guidance: String
    let sampler: Sampler
    let negativePrompt: String
    let lowRAM: Bool
    let adapters: [Adapter]
}

typealias InferenceCompletion = (Result<StudioResult, Error>) -> Void

enum FrameOperation: String, Codable, CaseIterable {
    case txt2img, img2img, inpaint, upscale

    func command(for family: Family) -> String? {
        switch self {
        case .txt2img: family.canCreate ? family.command : nil
        case .img2img: family.canReference ? (family.editCommand ?? family.command) : nil
        case .inpaint: family.canRepair ? (family.editCommand ?? family.command) : nil
        case .upscale: family.group == .seedvr2 ? family.command : nil
        }
    }

    func refs(for family: Family) -> ClosedRange<Int> {
        switch self {
        case .txt2img: 0...0
        case .img2img: 1...min(family.referenceLimit ?? 14, 14)
        case .inpaint, .upscale: 1...1
        }
    }

    var title: String {
        switch self {
        case .txt2img: "文生图"
        case .img2img: "参考图编辑"
        case .inpaint: "局部编辑"
        case .upscale: "高清放大"
        }
    }
}

struct FrameOptions: Codable {
    var width: Int?
    var height: Int?
    var steps: Int?
    var seed: UInt32?
    var guidance: Double?
    var sampler: String?
    var negativePrompt: String?
    var lowRAM: Bool?
    var imageStrength: Double?
    var loras: [LoRA]?
    var scale: String?
    var shortEdge: Int?
    var softness: Double?

    struct LoRA: Codable {
        let id: UUID
        let strength: Double
    }
}

struct FrameStroke: Codable {
    let diameter: Double
    let erases: Bool
    let points: [Point]

    struct Point: Codable {
        let x: Double
        let y: Double
    }

    var mask: MaskStroke {
        MaskStroke(diameter: diameter, erases: erases, points: points.map { CGPoint(x: $0.x, y: $0.y) })
    }

    var valid: Bool {
        (0.001...1).contains(diameter) && !points.isEmpty &&
            points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
    }
}

struct FrameSubmission: Decodable {
    let id: UUID
    let operation: FrameOperation
    let modelId: UUID
    let prompt: String?
    let options: FrameOptions?
    let inputs: [Data]?
    let strokes: [FrameStroke]?
}

struct FramePlan: Codable {
    let operation: FrameOperation
    let modelId: UUID
    let modelName: String
    let familyId: String
    let prompt: String
    let options: FrameOptions
    let inputCount: Int
    let strokes: [FrameStroke]

    var seed: String { options.seed.map(String.init) ?? "0" }
}

extension Studio {
    func frameCatalog() -> [[String: Any]] {
        models.compactMap { model in
            guard model.kind != .components, let family = model.family else { return nil }
            let ready = (try? checkFrameModel(model, family: family)) != nil
            let loras = adapterLibrary.filter { $0.familyID == family.id && fmReadable($0.url) }
                .map { ["id": $0.id.uuidString, "name": $0.name, "defaultStrength": 0.8] as [String: Any] }
            let operations = FrameOperation.allCases.compactMap { operation -> [String: Any]? in
                guard let command = operation.command(for: family), FileManager.default.isExecutableFile(
                    atPath: tools.appendingPathComponent(command).path) else { return nil }
                let refs = operation.refs(for: family)
                var fields: [String: Any] = [
                    "id": operation.rawValue, "minInputs": refs.lowerBound, "maxInputs": refs.upperBound,
                    "seed": ["min": 0, "max": UInt32.max], "lowRAM": true
                ]
                if operation == .upscale {
                    fields["scales"] = ["1.5x", "2x", "3x", "4x"]
                    fields["defaultScale"] = "2x"
                    fields["maxOutputEdge"] = 8192
                    fields["softness"] = ["min": 0, "max": 1, "default": 0]
                    return fields
                }
                fields["size"] = ["step": family.dimensionStep, "maxEdge": 4096,
                                  "presets": [512, 768, 1024, 1280, 1536, 2048],
                                  "followInput": operation != .txt2img, "custom": operation != .inpaint] as [String: Any]
                fields["steps"] = ["min": family.minimumSteps, "max": 150, "default": family.steps]
                let referenced = operation != .txt2img
                fields["negativePrompt"] = family.acceptsNegativePrompt
                fields["samplerDefaultLabel"] = family.samplerLabel(referenced: referenced)
                fields["samplers"] = family.samplers(referenced: referenced).map { ["id": $0.rawValue, "label": $0.label] }
                fields["loras"] = loras
                if let guidance = family.guidanceDefault {
                    fields["guidance"] = ["min": family.group == .qwen21 ? 1.0 : 0, "default": guidance]
                } else if family.group == .flux2Small || family.group == .flux2Large || family.isQwen21Turbo {
                    fields["fixedGuidance"] = 1
                }
                if operation == .img2img && family.usesInitImage {
                    fields["imageStrength"] = ["min": 0.01, "max": 1, "default": 0.6]
                }
                return fields
            }
            return ["id": model.id.uuidString, "name": model.name, "familyId": family.id,
                    "variant": family.variant, "ready": ready && !operations.isEmpty, "operations": operations]
        }
    }

    private func fmReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }

    private func checkFrameModel(_ model: LocalModel, family: Family) throws {
        try PackageLayout.validateComponents(at: model.folder, family: family)
        let transformer = model.kind == .assembly && model.importFiles == nil
            ? model.source : PackageLayout.transformer(at: model.folder, family: family)
        try PackageLayout.validateTransformer(at: transformer, family: family)
    }

    func prepareFrameJob(_ request: FrameSubmission, input: [ReferenceImage]) throws -> FramePlan {
        let (model, family) = try frameModel(request.modelId, operation: request.operation)
        let operation = request.operation
        guard operation.refs(for: family).contains(input.count) else {
            throw FrameAPIError(422, "input_count", "参考图数量不符合模型要求。")
        }
        var options = request.options ?? FrameOptions()
        let prompt = (request.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.utf8.count <= 16_384, options.negativePrompt?.utf8.count ?? 0 <= 16_384,
              !prompt.contains("\0"), options.negativePrompt?.contains("\0") != true else {
            throw FrameAPIError(422, "invalid_parameters", "提示词过长或包含无效字符。")
        }

        options.seed = options.seed ?? UInt32.random(in: 0...UInt32.max)
        options.lowRAM = options.lowRAM ?? false
        let strokes = request.strokes ?? []
        if operation == .upscale, let source = input.first {
            guard prompt.isEmpty, options.width == nil, options.height == nil, options.steps == nil,
                  options.guidance == nil, options.sampler == nil, options.negativePrompt == nil,
                  options.imageStrength == nil, options.loras?.isEmpty != false, strokes.isEmpty else {
                throw FrameAPIError(422, "invalid_parameters", "放大任务只接受放大参数。")
            }
            let factor: Double
            if let shortEdge = options.shortEdge {
                guard options.scale == nil, (1...8192).contains(shortEdge) else {
                    throw FrameAPIError(422, "invalid_size", "请选择倍率或有效的目标短边。")
                }
                factor = Double(shortEdge) / Double(min(source.width, source.height))
            } else {
                let scale = options.scale ?? "2x"
                guard ["1.5x", "2x", "3x", "4x"].contains(scale), let value = Double(scale.dropLast()) else {
                    throw FrameAPIError(422, "invalid_size", "不支持该放大倍率。")
                }
                options.scale = scale
                factor = value
            }
            guard Double(max(source.width, source.height)) * factor <= 8192 else {
                throw FrameAPIError(422, "invalid_size", "放大后的最长边不能超过 8192 像素。")
            }
            options.softness = options.softness ?? 0
            guard let softness = options.softness, (0...1).contains(softness) else {
                throw FrameAPIError(422, "invalid_parameters", "柔化应在 0 到 1 之间。")
            }
        } else {
            guard !prompt.isEmpty, options.scale == nil, options.shortEdge == nil, options.softness == nil else {
                throw FrameAPIError(422, "invalid_parameters", "请输入提示词并检查生图参数。")
            }
            if operation == .inpaint {
                guard !strokes.isEmpty, strokes.count <= 512, strokes.contains(where: { !$0.erases }),
                      strokes.reduce(0, { $0 + $1.points.count }) <= 50_000, strokes.allSatisfy(\.valid) else {
                    throw FrameAPIError(422, "invalid_mask", "请提交有效的局部编辑笔迹。")
                }
            } else if !strokes.isEmpty {
                throw FrameAPIError(422, "invalid_mask", "仅局部编辑接受笔迹。")
            }
            var invalidRef = false
            _ = rewriteImageTokens(prompt) { index in
                if index > input.count { invalidRef = true }
                return ""
            }
            guard !invalidRef else { throw FrameAPIError(422, "image_reference", "提示词引用了不存在的参考图。") }

            let step = family.dimensionStep
            let source = input.first?.resolution
            let preferred = GenerationSize(ratio: source == nil ? .square : .original,
                                           preferSourceSize: operation == .inpaint)
            let choices = preferred.options(source: source, step: step)
            guard (options.width == nil) == (options.height == nil),
                  let fallback = preferred.choose(from: choices, source: source) else {
                throw FrameAPIError(422, "invalid_size", "宽和高需要一起提供。")
            }
            let size = PixelResolution(width: options.width ?? fallback.width, height: options.height ?? fallback.height)
            guard size.longEdge <= 4096, size.isValid(step: step),
                  operation != .inpaint || choices.contains(size) else {
                throw FrameAPIError(422, "invalid_size", "输出尺寸不符合模型或底图比例要求。")
            }
            options.width = size.width
            options.height = size.height
            options.steps = options.steps ?? family.steps
            guard let steps = options.steps, (family.minimumSteps...150).contains(steps) else {
                throw FrameAPIError(422, "invalid_parameters", "步数应在 \(family.minimumSteps) 到 150 之间。")
            }
            if let guidance = options.guidance,
               family.guidanceDefault == nil || !guidance.isFinite || guidance < (family.group == .qwen21 ? 1 : 0) {
                throw FrameAPIError(422, "invalid_parameters", "该操作不支持此 CFG。")
            }
            if let sampler = options.sampler, !sampler.isEmpty,
               !family.samplers(referenced: operation != .txt2img).contains(where: { $0.rawValue == sampler }) {
                throw FrameAPIError(422, "invalid_parameters", "该操作不支持此采样器。")
            }
            if options.negativePrompt?.isEmpty == false && !family.acceptsNegativePrompt {
                throw FrameAPIError(422, "invalid_parameters", "该模型不支持负面提示词。")
            }
            if operation == .img2img && family.usesInitImage {
                let strength = options.imageStrength ?? 0.6
                guard (0.01...1).contains(strength) else {
                    throw FrameAPIError(422, "invalid_parameters", "重绘强度应在 0.01 到 1 之间。")
                }
                options.imageStrength = strength
            } else if options.imageStrength != nil {
                throw FrameAPIError(422, "invalid_parameters", "该操作不支持重绘强度。")
            }
            _ = try frameAdapters(options.loras ?? [], family: family)
        }
        return FramePlan(operation: operation, modelId: model.id, modelName: model.name, familyId: family.id,
                         prompt: prompt, options: options, inputCount: input.count, strokes: strokes)
    }

    private func frameModel(_ id: UUID, operation: FrameOperation) throws -> (LocalModel, Family) {
        guard let model = models.first(where: { $0.id == id }), model.kind != .components,
              let family = model.family else {
            throw FrameAPIError(422, "model_unavailable", "Mac 上找不到此模型。")
        }
        guard let command = operation.command(for: family) else {
            throw FrameAPIError(422, "unsupported_operation", "该模型不支持此操作。")
        }
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent(command).path) else {
            throw FrameAPIError(422, "runtime_unavailable", "Mac 上缺少所需的 mflux 命令。")
        }
        do { try checkFrameModel(model, family: family) }
        catch { throw FrameAPIError(422, "model_unavailable", "模型未就绪，请在 Mac 上检查模型及配套权重。") }
        return (model, family)
    }

    private func frameAdapters(_ requested: [FrameOptions.LoRA], family: Family) throws -> [Adapter] {
        guard requested.count <= 16, Set(requested.map(\.id)).count == requested.count else {
            throw FrameAPIError(422, "invalid_lora", "请选取至多 16 个不同的 LoRA。")
        }
        return try requested.map { item in
            guard (0...2).contains(item.strength),
                  let adapter = adapterLibrary.first(where: { $0.id == item.id && $0.familyID == family.id }),
                  fmReadable(adapter.url) else {
                throw FrameAPIError(422, "invalid_lora", "LoRA 不可用或与当前模型不兼容。")
            }
            return Adapter(id: adapter.id, url: adapter.url, strength: item.strength)
        }
    }

    func runFramePlan(_ plan: FramePlan, input: [ReferenceImage], output: URL,
                      completion: @escaping InferenceCompletion) throws {
        let (model, family) = try frameModel(plan.modelId, operation: plan.operation)
        guard family.id == plan.familyId, input.count == plan.inputCount else {
            throw FrameAPIError(422, "model_or_input_changed", "排队期间模型或输入文件发生变化。")
        }
        let options = plan.options
        if plan.operation == .upscale, let source = input.first {
            let resolution = options.shortEdge.map(String.init) ?? options.scale ?? "2x"
            try upscale(input: source.url, model: model, family: family, seed: plan.seed, output: output,
                        resolution: resolution, softness: options.softness ?? 0, lowRAM: options.lowRAM ?? false,
                        completion: completion)
            return
        }
        guard let width = options.width, let height = options.height, let steps = options.steps else {
            throw FrameAPIError(422, "invalid_parameters", "缺少已解析的生成参数。")
        }
        let settings = InferenceOptions(steps: steps, guidance: options.guidance.map { String($0) } ?? "",
                                        sampler: Sampler(rawValue: options.sampler ?? "") ?? .automatic,
                                        negativePrompt: options.negativePrompt ?? "", lowRAM: options.lowRAM ?? false,
                                        adapters: try frameAdapters(options.loras ?? [], family: family))
        let target = CGSize(width: width, height: height)
        if plan.operation == .inpaint, let source = input.first {
            try repair(model: model, family: family, seed: plan.seed, output: output, input: source, sourceIndex: 0,
                       prompt: plan.prompt, target: target, strokes: plan.strokes.map(\.mask),
                       settings: settings, completion: completion)
        } else {
            try generate(model: model, family: family, seed: plan.seed, output: output, input: input,
                         prompt: plan.prompt, target: target, strength: options.imageStrength ?? 0.6,
                         settings: settings, completion: completion)
        }
    }
}
