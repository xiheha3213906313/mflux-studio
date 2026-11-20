import AppKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Adapter: Identifiable {
    var id = UUID()
    var url: URL
    var strength = 0.8
}

struct LibraryAdapter: Identifiable, Codable {
    var id = UUID()
    let url: URL
    let familyID: String

    var name: String { url.lastPathComponent }
    var family: Family? { Family.find(familyID) }
}

struct ReferenceImage: Identifiable {
    let url: URL
    let thumbnail: NSImage
    let width: Int
    let height: Int

    var id: URL { url }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              min(width, height) >= 16 else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ] as CFDictionary
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let sideways = (5...8).contains(orientation)
        self.url = url
        self.width = sideways ? height : width
        self.height = sideways ? width : height
        thumbnail = NSImage(cgImage: preview, size: .zero)
    }

    var resolution: PixelResolution { PixelResolution(width: width, height: height) }
}

struct StudioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct StudioResult {
    let image: ReferenceImage
    let elapsed: TimeInterval
}

enum DownloadPhase {
    case downloading, pausing, paused, cancelling

    var title: String {
        switch self {
        case .downloading: "正在下载"
        case .pausing: "正在暂停"
        case .paused: "下载已暂停"
        case .cancelling: "正在取消"
        }
    }
}

private struct PresetDownload: Codable {
    let id: UUID
    let familyID: String
    let componentsOnly: Bool

    var kind: PackageKind { componentsOnly ? .components : .model }
}

final class Studio: ObservableObject {
    lazy var frameServer = FrameServer(studio: self)
    @Published var models: [LocalModel] = []
    @Published var selection: UUID?
    static let customSize = "自定义"

    @Published private var adaptersByFamily: [String: [Adapter]] = [:]
    @Published private(set) var adapterLibrary: [LibraryAdapter] = []
    @Published var references: [ReferenceImage] = []
    @Published private var generationSelection: UUID?
    @Published private var repairSelection: UUID?
    @Published private var upscaleSelection: UUID?
    @Published private(set) var localEditImageID: URL?
    @Published var guidance = ""
    @Published var sampler = Sampler.automatic
    @Published var negativePrompt = ""
    @Published var imageStrength = 0.6
    @Published var lowRAM = false
    @Published var upscaleScale = "2x"
    @Published var upscalePixels = 2160
    @Published var upscaleSoftness = 0.0
    @Published var repairStrokes: [MaskStroke] = []
    @Published var erasesRepairMask = false
    @Published var brushSize = 0.08
    @Published var repairSize = GenerationSize(ratio: .original, preferSourceSize: true)
    @Published var prompt = ""
    @Published var steps = 4
    @Published var size = GenerationSize(ratio: .square)
    @Published var editSize = GenerationSize(ratio: .original)
    @Published var seed = ""
    @Published private(set) var log = ""
    @Published var message = ""
    @Published var error: String?
    @Published private(set) var outputResult: StudioResult?
    @Published private(set) var localEditResults: [URL: StudioResult] = [:]
    @Published private(set) var running = false
    @Published private(set) var downloadPhase: DownloadPhase?
    @Published private(set) var downloadMessage = ""
    @Published private(set) var downloadLog = ""

    let root: URL
    let images: URL
    let tools: URL
    private let fm = FileManager.default
    private let list: URL
    private let adapterList: URL
    private var process: Process?
    private var monitor: Timer?
    private var stopped = false
    private var downloadProcess: Process?
    private var downloadMonitor: Timer?
    private var pendingDownload: PresetDownload?
    private var downloadRoot: URL { root.appendingPathComponent(".Downloads", isDirectory: true) }
    private var downloadReceipt: URL { downloadRoot.appendingPathComponent("current.json") }
    var downloadLabel: String? {
        guard let job = pendingDownload, let family = Family.find(job.familyID) else { return nil }
        return "\(family.label) · \(job.kind.rawValue)"
    }
    private var creationSettings: (Int, String, Sampler)?
    var selected: LocalModel? { models.first { $0.id == selection } }
    var adapters: [Adapter] {
        get { activeModel.map { adaptersByFamily[$0.familyID] ?? [] } ?? [] }
        set {
            if let activeModel { adaptersByFamily[activeModel.familyID] = newValue }
        }
    }
    var generationModel: LocalModel? {
        availableModel(preferred: generationSelection) { $0.canCreate }
    }
    var repairModels: [LocalModel] {
        models.filter { $0.kind != .components && $0.family?.canRepair == true }
    }
    var repairModel: LocalModel? {
        availableModel(preferred: repairSelection ?? generationModel?.id) { $0.canRepair }
    }
    var upscaleModels: [LocalModel] {
        models.filter { $0.kind != .components && $0.family?.group == .seedvr2 }
    }
    var upscaleModel: LocalModel? {
        availableModel(preferred: upscaleSelection) { $0.group == .seedvr2 }
    }
    var isLocalEditing: Bool { localEditImageID != nil }
    var repairInput: ReferenceImage? { references.first { $0.id == localEditImageID } }
    var activeModel: LocalModel? { isLocalEditing ? repairModel : generationModel }
    var supportsEditing: Bool { generationModel?.family?.canReference == true }
    var editing: Bool { !isLocalEditing && supportsEditing && !references.isEmpty }
    var hasMaskStrokes: Bool { repairStrokes.contains { !$0.erases } }
    var canRun: Bool {
        guard !running, activeModel != nil,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isLocalEditing || (repairInput != nil && hasMaskStrokes)
    }

    private func availableModel(preferred: UUID?, accepting accepts: (Family) -> Bool) -> LocalModel? {
        let eligible = models.filter { $0.kind != .components && $0.family.map(accepts) == true }
        return eligible.first { $0.id == preferred } ?? eligible.first
    }

    init(root: URL = Bundle.main.bundleURL.deletingLastPathComponent()) {
        self.root = root
        images = root.appendingPathComponent("Images", isDirectory: true)
        list = root.appendingPathComponent("library.json")
        adapterList = root.appendingPathComponent("LoRA.json")
        tools = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)

        if fm.fileExists(atPath: list.path) {
            do {
                models = try JSONDecoder().decode([LocalModel].self, from: Data(contentsOf: list))
            } catch {
                self.error = "无法读取模型清单。\n\(error.localizedDescription)"
            }
        } else {
            let path = root.appendingPathComponent("Models/FLUX.2-Klein-4B-Q4", isDirectory: true)
            if fm.fileExists(atPath: path.path) {
                models = [LocalModel(name: "FLUX.2 Klein 4B · Q4", familyID: "flux2-klein-4b", path: path.path,
                                     presetRepo: Family.find("flux2-klein-4b")?.presetRepo)]
                do { try save(models) }
                catch { self.error = "无法保存默认模型清单。\n\(error.localizedDescription)" }
            }
        }
        selection = generationModel?.id ?? models.first?.id
        steps = generationModel?.family?.steps ?? 4
        if fm.fileExists(atPath: adapterList.path) {
            do {
                adapterLibrary = try JSONDecoder().decode([LibraryAdapter].self, from: Data(contentsOf: adapterList))
            } catch {
                self.error = "无法读取 LoRA 库。\n\(error.localizedDescription)"
            }
        }
        if let receipt = try? Data(contentsOf: downloadReceipt),
           let job = try? JSONDecoder().decode(PresetDownload.self, from: receipt),
           Family.find(job.familyID) != nil {
            pendingDownload = job
            downloadPhase = .paused
        }
    }

    func select(_ model: LocalModel) {
        guard !running else { return }
        let previous = activeModel?.familyID
        let previousGeneration = generationModel?.familyID
        selection = model.id
        if model.kind != .components, let family = model.family {
            if family.canCreate { generationSelection = model.id }
            if family.canRepair && (isLocalEditing || !family.canCreate) { repairSelection = model.id }
            if family.group == .seedvr2 { upscaleSelection = model.id }
        }
        if previous != activeModel?.familyID { applyDefaults() }
        if isLocalEditing && previousGeneration != generationModel?.familyID {
            creationSettings = (generationModel?.family?.steps ?? 4, "", .automatic)
        }
    }

    func selectRepairModel(_ id: UUID?) {
        guard let id, repairModels.contains(where: { $0.id == id }), id != repairModel?.id else { return }
        repairSelection = id
        applyDefaults()
    }

    func selectUpscaleModel(_ id: UUID?) {
        guard let id, upscaleModels.contains(where: { $0.id == id }) else { return }
        upscaleSelection = id
    }

    private func applyDefaults() {
        steps = activeModel?.family?.steps ?? (isLocalEditing ? 30 : 4)
        guidance = ""
        sampler = .automatic
    }

    func save(_ updated: [LocalModel]) throws {
        try JSONEncoder().encode(updated).write(to: list, options: [.atomic])
        models = updated
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func addAdapters() {
        guard let family = activeModel?.family else { return }
        importAdapters(family: family, activate: true)
    }

    func importAdapters(family: Family? = nil, activate: Bool = false) {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 LoRA 文件"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.init(filenameExtension: "safetensors") ?? .data]
        panel.allowsMultipleSelection = true
        let families = Family.all.filter { $0.group != .seedvr2 }
        let picker = NSPopUpButton()
        if family == nil {
            picker.addItems(withTitles: families.map(\.label))
            if let index = families.firstIndex(where: { $0.id == activeModel?.familyID }) { picker.selectItem(at: index) }
            let accessory = NSStackView(views: [NSTextField(labelWithString: "适用模型"), picker])
            accessory.orientation = .horizontal
            accessory.spacing = 8
            accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            accessory.frame.size = accessory.fittingSize
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = true
        }
        guard panel.runModal() == .OK else { return }
        let index = picker.indexOfSelectedItem
        let selectedFamily = families.indices.contains(index) ? families[index] : nil
        guard let family = family ?? selectedFamily else { return }
        var updated = adapterLibrary
        var imported: [LibraryAdapter] = []
        for file in panel.urls {
            let url = file.standardizedFileURL
            if let existing = updated.first(where: { $0.url == url && $0.familyID == family.id }) {
                imported.append(existing)
            } else {
                let adapter = LibraryAdapter(url: url, familyID: family.id)
                updated.append(adapter)
                imported.append(adapter)
            }
        }
        do {
            if updated.count != adapterLibrary.count { try saveAdapters(updated) }
            if activate {
                for adapter in imported where !adapterIsActive(adapter) { toggleAdapter(adapter) }
            }
        } catch { self.error = error.localizedDescription }
    }

    func adapterIsActive(_ adapter: LibraryAdapter) -> Bool { adapters.contains { $0.id == adapter.id } }

    func toggleAdapter(_ adapter: LibraryAdapter) {
        guard !running, activeModel?.familyID == adapter.familyID else { return }
        if adapterIsActive(adapter) {
            adapters.removeAll { $0.id == adapter.id }
        } else if fm.isReadableFile(atPath: adapter.url.path) {
            adapters.append(Adapter(id: adapter.id, url: adapter.url))
        } else {
            error = "找不到 LoRA 文件 \(adapter.name)。"
        }
    }

    func removeLibraryAdapter(_ adapter: LibraryAdapter) {
        guard !running else { return }
        do {
            try saveAdapters(adapterLibrary.filter { $0.id != adapter.id })
            adaptersByFamily[adapter.familyID]?.removeAll { $0.id == adapter.id }
        } catch { self.error = error.localizedDescription }
    }

    private func saveAdapters(_ entries: [LibraryAdapter]) throws {
        try JSONEncoder().encode(entries).write(to: adapterList, options: .atomic)
        adapterLibrary = entries
    }

    private func pickImages(multiple: Bool, title: String) -> [URL] {
        guard !running else { return [] }
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "打开"
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseReferences() {
        if isLocalEditing && !supportsEditing {
            beginLocalEdit(chooseNew: true)
            return
        }
        addReferences(pickImages(multiple: generationModel?.family?.referenceLimit != 1, title: "选择参考图"))
    }

    func useAsReference(_ url: URL) {
        guard !running else { return }
        addReferences([url])
    }

    func beginLocalEdit(with image: ReferenceImage? = nil, chooseNew: Bool = false) {
        guard !running else { return }
        let source: ReferenceImage
        if let existing = image ?? (chooseNew ? nil : references.first) {
            source = existing
        } else {
            guard let url = pickImages(multiple: false, title: "选择局部编辑的图片").first?.standardizedFileURL else { return }
            if let existing = references.first(where: { $0.id == url }) {
                source = existing
            } else if let selected = ReferenceImage(url: url) {
                references.append(selected)
                source = selected
            } else {
                error = "无法读取图片，请选择 PNG、JPEG 或 WebP。"
                return
            }
        }
        guard source.id != localEditImageID else { return }
        let wasEditing = isLocalEditing
        let previousFamily = activeModel?.familyID
        if !wasEditing { creationSettings = (steps, guidance, sampler) }
        localEditImageID = source.id
        repairStrokes = []
        erasesRepairMask = false
        repairSize.resolution = nil
        if !wasEditing && previousFamily != activeModel?.familyID { applyDefaults() }
    }

    func endLocalEdit() {
        guard isLocalEditing, !running else { return }
        localEditImageID = nil
        repairStrokes = []
        erasesRepairMask = false
        if let saved = creationSettings {
            (steps, guidance, sampler) = saved
        } else {
            applyDefaults()
        }
        creationSettings = nil
    }

    func removeReference(_ image: ReferenceImage) {
        guard !running, let index = references.firstIndex(where: { $0.id == image.id }) else { return }
        if image.id == localEditImageID { endLocalEdit() }
        references.remove(at: index)
        localEditResults.removeValue(forKey: image.id)
        prompt = rewriteImageTokens(prompt) { number in
            if number == index + 1 { return "" }
            return "@image \(number > index + 1 ? number - 1 : number)"
        }
    }

    func rewriteImageTokens(_ text: String, replacement: (Int) -> String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"@image ([1-9][0-9]*)\b"#)
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let number = Range(match.range(at: 1), in: result),
                  let index = Int(result[number]) else { continue }
            result.replaceSubrange(whole, with: replacement(index))
        }
        return result
    }

    private func addReferences(_ urls: [URL]) {
        guard !urls.isEmpty, let family = generationModel?.family, family.canReference else { return }
        var pending = references
        for url in urls {
            let file = url.standardizedFileURL
            guard !pending.contains(where: { $0.url == file }) else { continue }
            guard let reference = ReferenceImage(url: file) else {
                error = "无法读取 \(file.lastPathComponent)。请选择有效的 PNG、JPEG 或 WebP。"
                return
            }
            pending.append(reference)
        }
        if let limit = family.referenceLimit, pending.count > limit {
            if limit == 1, urls.count == 1, let last = pending.last {
                let wasEditing = isLocalEditing
                while let old = references.last { removeReference(old) }
                references = [last]
                if wasEditing { beginLocalEdit(with: last) }
                return
            }
            error = "当前模型最多支持 \(limit) 张参考图。"
            return
        }
        references = pending
    }

    func entries(in group: ModelGroup) -> [LocalModel] {
        models.filter { $0.family?.group == group }
    }

    func componentSources(for family: Family) -> [LocalModel] {
        models.filter { model in
            guard model.kind != .assembly, let source = model.family,
                  family.sharesComponents(with: source) else { return false }
            return PackageLayout.directory(model.folder)
        }
    }

    func importFiles(for model: LocalModel) -> ModelImportFiles {
        if let files = model.importFiles { return files }
        guard let family = model.family else { return ModelImportFiles() }
        let transformer = model.kind == .assembly ? model.source : PackageLayout.transformer(at: model.folder, family: family)
        var files = ModelImportFiles()
        if model.kind != .components {
            files.transformer = selectableFiles(at: transformer).filter {
                $0.pathExtension.lowercased() == "safetensors" || $0.lastPathComponent == "config.json"
                    || $0.lastPathComponent.hasSuffix(".safetensors.index.json")
            }
        }
        if model.kind == .assembly {
            files.componentSource = model.folder
        } else {
            for part in family.group.componentFolders + ["scheduler"] {
                let path = model.folder.appendingPathComponent(part)
                let selected = selectableFiles(at: path)
                if !selected.isEmpty { files.components[part] = selected }
            }
            if family.group == .seedvr2 {
                let vae = selectableFiles(at: model.folder.appendingPathComponent("ema_vae_fp16.safetensors"))
                if !vae.isEmpty { files.components["vae"] = vae }
            }
            files.metadata = optionalModelFiles(for: family).flatMap { selectableFiles(at: model.folder.appendingPathComponent($0)) }
                .sorted { $0.path < $1.path }
        }
        return files
    }

    private func selectableFiles(at location: URL) -> [URL] {
        let entries: [URL]
        if PackageLayout.directory(location) {
            entries = (try? fm.contentsOfDirectory(at: location, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        } else { entries = [location] }
        return entries.filter { !PackageLayout.directory($0) && fm.isReadableFile(atPath: $0.path) }.sorted { $0.path < $1.path }
    }

    func saveModelImport(name: String, familyID: String, files: ModelImportFiles,
                         kind: PackageKind, replacing: UUID?) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let family = Family.find(familyID) else { throw StudioError("请输入模型名称并选择架构。") }
        let old = models.first { $0.id == replacing }
        var selection = files
        if kind == .components { selection.transformer = [] }
        if kind == .assembly {
            selection.components = [:]
            selection.metadata = []
        } else { selection.componentSource = nil }
        if var existing = old, existing.familyID == familyID, existing.kind == kind, importFiles(for: existing) == selection {
            existing.name = title
            try register(existing, select: true)
            return
        }

        let directory = root.appendingPathComponent("Models/Imported", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            if kind == .assembly {
                guard let source = selection.componentSource else { throw StudioError("请选择已入库的配套。") }
                let available = componentSources(for: family).contains { $0.folder.path == source.path }
                let retained = old?.kind == .assembly && (old?.importFiles?.componentSource ?? old?.folder)?.path == source.path
                    && old?.family.map { family.sharesComponents(with: $0) } == true
                guard available || retained else { throw StudioError("请选择与此架构匹配的配套。") }
                try PackageLayout.validateComponents(at: source, family: family)
                try linkPackageComponents(from: source, to: folder, family: family)
            } else {
                try linkSelectedComponents(selection, at: folder, family: family)
            }
            if kind != .components {
                try linkTransformer(selection.transformer, at: folder, family: family)
            }
            try PackageLayout.validateComponents(at: folder, family: family)
            if kind == .model, let declared = PackageLayout.knownFamily(at: folder), declared.id != family.id {
                throw StudioError("这套文件属于 \(declared.label)。请选择对应的版本。")
            }
            if kind != .components {
                try PackageLayout.validateTransformer(at: PackageLayout.transformer(at: folder, family: family), family: family)
            }
            try PackageLayout.record(.init(familyID: family.id, repo: "", componentsOnly: kind == .components), at: folder)
            let model = LocalModel(id: replacing ?? UUID(), name: title, familyID: familyID, path: folder.path,
                                   componentsOnly: kind == .components ? true : nil, importFiles: selection)
            try register(model, select: true)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        if let old, old.importFiles != nil, old.folder.deletingLastPathComponent().path == directory.path,
           !locationIsShared(old.folder, among: models) {
            try? fm.removeItem(at: old.folder)
        }
    }

    private func optionalModelFiles(for family: Family) -> [String] {
        family.group.optionalPaths.filter { $0 != "scheduler" } + ["mflux_model.json"]
    }

    private func linkSelectedComponents(_ selection: ModelImportFiles, at folder: URL, family: Family) throws {
        for part in family.group.componentFolders + ["scheduler"] {
            let files = selection.components[part] ?? []
            if part == "scheduler" && files.isEmpty { continue }
            guard !files.isEmpty else { throw StudioError("请为 \(part) 选择对应的文件。") }
            if family.group == .seedvr2 && part == "vae" {
                try linkSeedWeight(files, named: "ema_vae_fp16.safetensors", at: folder)
            } else {
                let component = folder.appendingPathComponent(part, isDirectory: true)
                try fm.createDirectory(at: component, withIntermediateDirectories: false)
                try linkFiles(files, at: component)
            }
        }
        if let unsupported = selection.metadata.first(where: { !optionalModelFiles(for: family).contains($0.lastPathComponent) }) {
            throw StudioError("\(unsupported.lastPathComponent) 不属于模型的附加配置。请放到对应组件中。")
        }
        try linkFiles(selection.metadata, at: folder)
    }

    private func linkTransformer(_ files: [URL], at folder: URL, family: Family) throws {
        if family.group == .seedvr2 {
            try linkSeedWeight(files, named: family.seedTransformerFile, at: folder)
        } else if family.group == .krea2 && files.contains(where: { ["turbo.safetensors", "raw.safetensors"].contains($0.lastPathComponent) }) {
            try linkFiles(files, at: folder)
        } else {
            let transformer = folder.appendingPathComponent("transformer", isDirectory: true)
            try fm.createDirectory(at: transformer, withIntermediateDirectories: false)
            try linkFiles(files, at: transformer)
        }
    }

    private func linkSeedWeight(_ files: [URL], named name: String, at folder: URL) throws {
        guard files.count == 1, let file = files.first, file.pathExtension.lowercased() == "safetensors",
              !PackageLayout.directory(file), fm.isReadableFile(atPath: file.path) else {
            throw StudioError("请选择用于 \(name) 的单个 .safetensors 文件。")
        }
        try fm.createSymbolicLink(at: folder.appendingPathComponent(name), withDestinationURL: file)
    }

    private func linkFiles(_ files: [URL], at folder: URL) throws {
        try PackageLayout.validateSelectedShards(in: files)
        var names = Set<String>()
        for file in files {
            let name = file.lastPathComponent
            guard file.isFileURL, !PackageLayout.directory(file), fm.isReadableFile(atPath: file.path) else {
                throw StudioError("找不到文件 \(name)。")
            }
            guard names.insert(name.lowercased()).inserted else { throw StudioError("同一组件中有重名文件 \(name)。") }
            try fm.createSymbolicLink(at: folder.appendingPathComponent(name), withDestinationURL: file)
        }
    }

    private func register(_ model: LocalModel, select shouldSelect: Bool) throws {
        if models.contains(where: { $0.id == model.id }) {
            try save(models.map { $0.id == model.id ? model : $0 })
        } else {
            try save(models + [model])
        }
        if shouldSelect || selection == nil { select(model) }
    }

    private func locationIsShared(_ source: URL, among entries: [LocalModel]) -> Bool {
        func paths(_ url: URL) -> Set<String> { [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path] }
        let sourcePaths = paths(source)
        return entries.contains { entry in
            entry.referencedPaths.contains { candidate in
                paths(candidate).contains { path in
                    sourcePaths.contains { sourcePath in
                        path == sourcePath || path.hasPrefix(sourcePath + "/") || sourcePath.hasPrefix(path + "/")
                    }
                }
            }
        }
    }

    func remove(_ model: LocalModel, trash: Bool) {
        do {
            let before = activeModel?.familyID
            let previousGeneration = generationModel?.familyID
            let remaining = models.filter { $0.id != model.id }
            if trash {
                guard !locationIsShared(model.source, among: remaining) else {
                    throw StudioError("其他模型仍在使用这个目录或文件。")
                }
                let original = models
                try save(remaining)
                do {
                    try fm.trashItem(at: model.source.standardizedFileURL, resultingItemURL: nil)
                } catch {
                    try save(original)
                    throw error
                }
            } else {
                try save(remaining)
            }
            if selection == model.id { selection = generationModel?.id ?? remaining.first?.id }
            if generationSelection == model.id { generationSelection = nil }
            if repairSelection == model.id { repairSelection = nil }
            if upscaleSelection == model.id { upscaleSelection = nil }
            if before != activeModel?.familyID { applyDefaults() }
            if isLocalEditing && previousGeneration != generationModel?.familyID {
                creationSettings = (generationModel?.family?.steps ?? 4, "", .automatic)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func modelPath(_ model: LocalModel, in scratch: URL) throws -> URL {
        guard let family = model.family, model.kind != .components else {
            throw StudioError("请选择完整模型或已组装的底模。")
        }
        try PackageLayout.validateComponents(at: model.folder, family: family)
        if model.importFiles != nil {
            try PackageLayout.validateTransformer(at: PackageLayout.transformer(at: model.folder, family: family), family: family)
            return model.folder
        }
        guard model.kind == .assembly else { return model.folder }
        try PackageLayout.validateTransformer(at: model.source, family: family)
        let modelRoot = scratch.appendingPathComponent("model", isDirectory: true)
        try fm.createDirectory(at: modelRoot, withIntermediateDirectories: false)
        try linkPackageComponents(from: model.folder, to: modelRoot, family: family)
        let seedRaw = family.group == .seedvr2 && model.source.lastPathComponent == family.seedTransformerFile
        let rootLayout = seedRaw || (family.group == .krea2 && model.source.lastPathComponent != "transformer")
        let transformer = rootLayout ? modelRoot : modelRoot.appendingPathComponent("transformer", isDirectory: true)
        if !rootLayout {
            try fm.createDirectory(at: transformer, withIntermediateDirectories: false)
        }
        var items = PackageLayout.weightFiles(in: model.source)
        if PackageLayout.directory(model.source) {
            for name in ["model.safetensors.index.json", "diffusion_pytorch_model.safetensors.index.json", "config.json"] {
                let file = model.source.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) && (!rootLayout || name != "config.json") {
                    items.append(file)
                }
            }
        }
        for item in items {
            try fm.createSymbolicLink(at: transformer.appendingPathComponent(item.lastPathComponent), withDestinationURL: item)
        }
        return modelRoot
    }

    private func linkPackageComponents(from source: URL, to target: URL, family: Family) throws {
        let seedVAE = family.group == .seedvr2 ? ["ema_vae_fp16.safetensors"] : []
        for part in family.group.componentFolders + family.group.optionalPaths + seedVAE {
            let item = source.appendingPathComponent(part)
            if PackageLayout.directory(item) {
                try stageComponent(item, at: target.appendingPathComponent(part, isDirectory: true))
            } else if fm.fileExists(atPath: item.path) {
                try fm.createSymbolicLink(at: target.appendingPathComponent(part), withDestinationURL: item)
            }
        }
    }

    private func stageComponent(_ source: URL, at target: URL) throws {
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            try fm.createSymbolicLink(at: target.appendingPathComponent(item.lastPathComponent), withDestinationURL: item)
        }
    }

    private func runSeed() throws -> String {
        let text = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || UInt32(text) != nil else {
            throw StudioError("种子必须是 0 到 4294967295 之间的整数。")
        }
        return text.isEmpty ? String(UInt32.random(in: 0...1_000_000_000)) : text
    }

    func runTool() {
        guard !running, let model = activeModel, let family = model.family else { return }
        do {
            let seed = try runSeed()
            let output = images.appendingPathComponent("\(UUID().uuidString.prefix(12)).png")
            if isLocalEditing {
                try repair(model: model, family: family, seed: seed, output: output)
            } else {
                try generate(model: model, family: family, seed: seed, output: output)
            }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func runUpscale(_ input: URL) -> Bool {
        guard !running, let model = upscaleModel, let family = model.family else { return false }
        do {
            let seed = try runSeed()
            let output = images.appendingPathComponent("\(UUID().uuidString.prefix(12)).png")
            try upscale(input: input, model: model, family: family, seed: seed, output: output)
        } catch { self.error = error.localizedDescription }
        return running
    }

    private func dimensions(_ choice: GenerationSize, reference: ReferenceImage?, family: Family) throws -> CGSize {
        let step = family.dimensionStep
        let source = reference?.resolution
        let resolution: PixelResolution
        if choice.ratio == .free {
            resolution = PixelResolution(width: choice.width, height: choice.height)
        } else {
            guard let selected = choice.choose(from: choice.options(source: source, step: step), source: source) else {
                throw StudioError("请选择有效的输出分辨率。")
            }
            resolution = selected
        }
        guard resolution.isValid(step: step) else { throw StudioError("宽和高需要是 \(step) 的正整数倍。") }
        return CGSize(width: resolution.width, height: resolution.height)
    }

    private var inference: InferenceOptions {
        InferenceOptions(steps: steps, guidance: guidance, sampler: sampler,
                         negativePrompt: negativePrompt, lowRAM: lowRAM, adapters: adapters)
    }

    private func generationOptions(_ family: Family, referenced: Bool, size: CGSize, seed: String,
                                   settings: InferenceOptions) throws -> [String] {
        guard (family.minimumSteps...150).contains(settings.steps) else {
            throw StudioError("步数应在 \(family.minimumSteps) 到 150 之间。")
        }
        var args = ["--width", String(Int(size.width)), "--height", String(Int(size.height)),
                    "--steps", String(settings.steps), "--seed", seed]
        let cfg = settings.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if family.guidanceDefault != nil && !cfg.isEmpty {
            let separator = Locale.current.decimalSeparator ?? "."
            let minimum = family.group == .qwen21 ? 1.0 : 0.0
            guard let value = Double(cfg.replacingOccurrences(of: separator, with: ".")),
                  value.isFinite, value >= minimum else {
                throw StudioError(family.group == .qwen21 ? "这个模型的 CFG 至少为 1。" : "CFG 请填写非负数字。")
            }
            args += ["--guidance", String(value)]
        }
        if family.samplers(referenced: referenced).contains(settings.sampler) { args += ["--scheduler", settings.sampler.rawValue] }
        let negative = settings.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if family.acceptsNegativePrompt && !negative.isEmpty { args += ["--negative-prompt=\(negative)"] }
        if settings.lowRAM { args.append("--low-ram") }
        for adapter in settings.adapters {
            guard fm.isReadableFile(atPath: adapter.url.path) else {
                throw StudioError("找不到 LoRA 文件 \(adapter.url.lastPathComponent)。")
            }
            args += ["--lora", adapter.url.path, String(adapter.strength)]
        }
        return args
    }

    private func generate(model: LocalModel, family: Family, seed: String, output: URL) throws {
        let input = family.canReference ? references : []
        let target = try dimensions(input.isEmpty ? size : editSize, reference: input.first, family: family)
        try generate(model: model, family: family, seed: seed, output: output, input: input,
                     prompt: prompt, target: target, strength: imageStrength, settings: inference)
    }

    func generate(model: LocalModel, family: Family, seed: String, output: URL,
                          input: [ReferenceImage], prompt: String, target: CGSize, strength: Double,
                          settings: InferenceOptions, completion: InferenceCompletion? = nil) throws {
        if let limit = family.referenceLimit, input.count > limit {
            throw StudioError("当前模型最多支持 \(limit) 张参考图。请先移除多余图片。")
        }
        for image in input where !fm.isReadableFile(atPath: image.url.path) {
            throw StudioError("找不到参考图 \(image.url.lastPathComponent)。")
        }
        var invalid = false
        let text = rewriteImageTokens(prompt) { index in
            if index > input.count { invalid = true }
            return "image \(index)"
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invalid else { throw StudioError("提示词中有未添加的参考图编号。") }
        guard !text.isEmpty else { throw StudioError("请输入提示词。") }

        let referenced = !input.isEmpty
        var options = try generationOptions(family, referenced: referenced, size: target, seed: seed, settings: settings)
        if let first = input.first {
            options += family.usesInitImage
                ? ["--image", first.url.path, String(strength)]
                : ["--image-paths"] + input.map { $0.url.path }
        }
        let command = (referenced ? family.editCommand : nil) ?? family.command
        run(command: command, model: model, output: output, activity: referenced ? "正在根据参考图生图…" : "正在生成图片…",
            completion: completion) { path, _ in
            ["--model", path.path, "--base-model", family.id, "--prompt=\(text)", "--output", output.path] + options
        }
    }

    private func upscale(input: URL, model: LocalModel, family: Family, seed: String, output: URL) throws {
        let resolution: String
        if upscaleScale == Self.customSize {
            guard upscalePixels > 0 else { throw StudioError("目标短边请填写大于 0 的像素值。") }
            resolution = String(upscalePixels)
        } else {
            resolution = upscaleScale
        }
        let editSource = localEditImageID.flatMap { localEditResults[$0]?.image.url == input ? $0 : nil }
        try upscale(input: input, model: model, family: family, seed: seed, output: output,
                    resolution: resolution, softness: upscaleSoftness, lowRAM: lowRAM, editSource: editSource)
    }

    func upscale(input: URL, model: LocalModel, family: Family, seed: String, output: URL,
                         resolution: String, softness: Double, lowRAM: Bool, editSource: URL? = nil,
                         completion: InferenceCompletion? = nil) throws {
        guard fm.isReadableFile(atPath: input.path) else { throw StudioError("请选择需要放大的图片。") }
        run(command: family.command, model: model, output: output, activity: "正在高清放大…",
            editSource: editSource, completion: completion) { path, _ in
            var args = ["--model", path.path, "--image-path", input.path, "--resolution", resolution,
                        "--softness", String(softness), "--seed", seed, "--output", output.path]
            if self.fm.fileExists(atPath: path.appendingPathComponent(family.seedTransformerFile).path) {
                args += ["--quantize", "4"]
            }
            if lowRAM { args.append("--low-ram") }
            return args
        }
    }

    private func repair(model: LocalModel, family: Family, seed: String, output: URL) throws {
        guard let sourceIndex = references.firstIndex(where: { $0.id == localEditImageID }),
              hasMaskStrokes else {
            throw StudioError("请选择一张参考图，并涂出要编辑的区域。")
        }
        let input = references[sourceIndex]
        let target = try dimensions(repairSize, reference: input, family: family)
        try repair(model: model, family: family, seed: seed, output: output, input: input,
                   sourceIndex: sourceIndex, prompt: prompt, target: target, strokes: repairStrokes, settings: inference)
    }

    func repair(model: LocalModel, family: Family, seed: String, output: URL,
                        input: ReferenceImage, sourceIndex: Int, prompt: String, target: CGSize,
                        strokes: [MaskStroke], settings: InferenceOptions,
                        completion: InferenceCompletion? = nil) throws {
        guard fm.isReadableFile(atPath: input.url.path) else {
            throw StudioError("找不到参考图 \(input.url.lastPathComponent)。")
        }
        var mentionsOtherImage = false
        let text = rewriteImageTokens(prompt) { index in
            if index != sourceIndex + 1 { mentionsOtherImage = true }
            return "the source image"
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mentionsOtherImage else { throw StudioError("局部编辑只使用当前涂抹的那张参考图，请调整提示词中的图片引用。") }
        guard !text.isEmpty else { throw StudioError("请输入提示词。") }
        let options = try generationOptions(family, referenced: true, size: target, seed: seed, settings: settings)
        let fill = family.group == .fill
        let command = fill ? family.command : "mflux-generate-qwen-2.1-edit"
        run(command: command, model: model, output: output, activity: "正在局部编辑…", editSource: input.id,
            finalize: { scratch in try RepairMask.composite(in: scratch, output: output) }, completion: completion) { path, scratch in
            try RepairMask.stage(source: input.url, strokes: strokes, size: target, in: scratch)
            let inputPath = scratch.appendingPathComponent("input.png").path
            let maskPath = scratch.appendingPathComponent("mask.png").path
            let rawOutput = scratch.appendingPathComponent("repaired.png").path
            let flags = fill ? ["--image-path", inputPath, "--masked-image-path", maskPath]
                             : ["--image-paths", inputPath, "--mask-image", maskPath]
            return ["--model", path.path, "--base-model", family.id, "--prompt=\(text)", "--output", rawOutput] + options + flags
        }
    }

    func validate(_ model: LocalModel) {
        guard !running, let family = model.family else { return }
        if model.kind == .components {
            log = ""
            do {
                try PackageLayout.validateComponents(at: model.folder, family: family)
                message = "配套组件目录检查通过。"
            } catch { self.error = error.localizedDescription }
            return
        }
        run(command: "mflux-check", model: model, output: nil, activity: "正在检查模型…") { path, _ in
            ["model", "--base-model", model.familyID, path.path]
        }
    }

    private func tail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: length > 24_000 ? length - 24_000 : 0)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
    }

    var runtimeLogText: String {
        if log.isEmpty { return message }
        if message.isEmpty { return log }
        return running ? "\(message)\n\(log)" : "\(log)\n\(message)"
    }

    private func readRuntimeLog(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
    }

    func presetPackage(_ family: Family, kind: PackageKind) -> LocalModel? {
        let legacy = root.appendingPathComponent("Models/FLUX.2-Klein-4B-Q4").path
        return models.first { item in
            let matches = item.presetRepo == family.presetRepo
                || (family.id == "flux2-klein-4b" && item.familyID == family.id && item.path == legacy)
            let rightKind = item.kind == kind || (kind == .components && item.kind == .model)
            return matches && rightKind && PackageLayout.directory(item.folder)
        }
    }

    func download(_ family: Family, kind: PackageKind) {
        guard pendingDownload == nil, kind != .assembly else { return }
        if let existing = presetPackage(family, kind: kind) {
            select(existing)
            return
        }
        let job = PresetDownload(id: UUID(), familyID: family.id, componentsOnly: kind == .components)
        let workspace = downloadWorkspace(job)
        do {
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data().write(to: workspace.appendingPathComponent("job.lock"))
            try JSONEncoder().encode(job).write(to: downloadReceipt, options: .atomic)
        } catch {
            try? fm.removeItem(at: workspace)
            downloadMessage = error.localizedDescription
            return
        }
        pendingDownload = job
        downloadPhase = .paused
        downloadLog = ""
        resumeDownload()
    }

    func resumeDownload() {
        guard downloadPhase == .paused, downloadProcess == nil,
              let job = pendingDownload, let family = Family.find(job.familyID) else { return }
        if let saved = savedDownload(job, family: family) {
            finishDownload(job, family: family, saved: saved)
            return
        }
        let python = tools.appendingPathComponent("mflux-check").resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("python")
        guard fm.isExecutableFile(atPath: python.path),
              let script = Bundle.main.url(forResource: "DownloadPreset", withExtension: "py") else {
            downloadMessage = "找不到下载程序或 mflux 的 Python 环境。"
            return
        }
        let loose = job.componentsOnly
        let workspace = downloadWorkspace(job)
        let logfile = fm.temporaryDirectory.appendingPathComponent("mflux-download-\(UUID()).log")
        do {
            try Data().write(to: logfile)
            let handle = try FileHandle(forWritingTo: logfile)
            let task = Process()
            task.executableURL = python
            var args = [script.path, family.presetRepo, workspace.path, String(ProcessInfo.processInfo.processIdentifier)]
            if family.group == .seedvr2 {
                let patterns = loose ? ["ema_vae_fp16.safetensors"] : ["ema_vae_fp16.safetensors", family.seedTransformerFile]
                args += patterns.flatMap { ["--include", $0] }
            } else if loose {
                let patterns = family.group.componentFolders.map { "\($0)/*" }
                    + ["scheduler/*", "model_index.json", "mflux_model.json", "manifest.json",
                       "chat_template.jinja", "added_tokens.json", "README.md"]
                args += patterns.flatMap { ["--include", $0] }
            }
            task.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "0"
            env["HF_ENDPOINT"] = "https://huggingface.co"
            env["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
            env["HF_HUB_DISABLE_TELEMETRY"] = "1"
            env["HF_HUB_DOWNLOAD_TIMEOUT"] = "120"
            env["PYTHONUNBUFFERED"] = "1"
            env["NO_COLOR"] = "1"
            task.environment = env
            task.standardOutput = handle
            task.standardError = handle
            task.terminationHandler = { [weak self] task in
                try? handle.close()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.downloadMonitor?.invalidate()
                    self.downloadMonitor = nil
                    self.downloadLog = self.tail(logfile)
                    try? self.fm.removeItem(at: logfile)
                    self.downloadProcess = nil
                    if self.downloadPhase == .cancelling {
                        self.discardDownload(job)
                    } else if self.downloadPhase == .pausing {
                        self.downloadPhase = .paused
                        self.downloadMessage = "进度已保留，点击「继续下载」可恢复。"
                    } else if task.terminationStatus != 0 {
                        self.downloadPhase = .paused
                        self.downloadMessage = "下载中断。进度已保留，可继续下载。"
                    } else {
                        self.finishDownload(job, family: family)
                    }
                }
            }
            try task.run()
            downloadProcess = task
            downloadPhase = .downloading
            downloadMessage = ""
            downloadLog = ""
            downloadMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.downloadLog = self.tail(logfile)
            }
        } catch {
            try? fm.removeItem(at: logfile)
            downloadMessage = error.localizedDescription
        }
    }

    func pauseDownload() {
        guard downloadPhase == .downloading, let downloadProcess else { return }
        downloadPhase = .pausing
        downloadMessage = ""
        if downloadProcess.isRunning { downloadProcess.terminate() }
    }

    func cancelDownload() {
        guard let job = pendingDownload, downloadPhase != .cancelling else { return }
        downloadPhase = .cancelling
        downloadMessage = ""
        if let downloadProcess {
            if downloadProcess.isRunning { downloadProcess.terminate() }
        } else {
            discardDownload(job)
        }
    }

    private func downloadWorkspace(_ job: PresetDownload) -> URL {
        downloadRoot.appendingPathComponent(job.id.uuidString, isDirectory: true)
    }

    private func downloadDestinations(_ job: PresetDownload, family: Family) -> (standard: URL, alternate: URL) {
        let directory = root.appendingPathComponent(job.componentsOnly ? "Components" : "Models", isDirectory: true)
            .appendingPathComponent(family.group.id, isDirectory: true)
        let leaf = family.presetRepo.split(separator: "/").last.map(String.init) ?? family.id
        return (directory.appendingPathComponent(leaf, isDirectory: true),
                directory.appendingPathComponent("\(leaf)-\(job.id.uuidString.prefix(8))", isDirectory: true))
    }

    private func savedDownload(_ job: PresetDownload, family: Family) -> URL? {
        let destinations = downloadDestinations(job, family: family)
        return [destinations.standard, destinations.alternate].first { path in
            guard let identity = PackageLayout.identity(at: path) else { return false }
            return identity.familyID == job.familyID && identity.repo == family.presetRepo && identity.componentsOnly == job.componentsOnly
        }
    }

    private func finishDownload(_ job: PresetDownload, family: Family, saved: URL? = nil) {
        do {
            let package = saved ?? downloadWorkspace(job).appendingPathComponent("package", isDirectory: true)
            try PackageLayout.validateComponents(at: package, family: family)
            let transformer = PackageLayout.transformer(at: package, family: family)
            if job.componentsOnly {
                guard PackageLayout.weightFiles(in: transformer).isEmpty else {
                    throw StudioError("配套目录已有 Transformer 文件，请检查该目录。")
                }
            } else {
                try PackageLayout.validateTransformer(at: transformer, family: family)
            }
            let destination: URL
            if let saved {
                destination = saved
            } else {
                let paths = downloadDestinations(job, family: family)
                destination = fm.fileExists(atPath: paths.standard.path) ? paths.alternate : paths.standard
                try PackageLayout.record(.init(familyID: family.id, repo: family.presetRepo,
                                               componentsOnly: job.componentsOnly), at: package)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: package, to: destination)
            }
            if !models.contains(where: { $0.path == destination.path && $0.kind == job.kind }) {
                let format = family.group == .seedvr2 ? "FP16" : "Q4"
                let entry = LocalModel(name: "\(family.label) · \(format)", familyID: family.id, path: destination.path,
                                       componentsOnly: job.componentsOnly ? true : nil, presetRepo: family.presetRepo)
                try register(entry, select: !running)
            }
            try clearDownload(job)
            downloadMessage = "\(job.kind.rawValue)已加入模型库。"
        } catch {
            downloadPhase = .paused
            downloadMessage = "保存下载结果时遇到问题。\(error.localizedDescription)"
        }
    }

    private func discardDownload(_ job: PresetDownload) {
        do {
            try clearDownload(job)
            downloadLog = ""
            downloadMessage = "下载已取消。"
        } catch {
            downloadPhase = .paused
            downloadMessage = "取消下载时遇到问题。\(error.localizedDescription)"
        }
    }

    private func clearDownload(_ job: PresetDownload) throws {
        let workspace = downloadWorkspace(job)
        if fm.fileExists(atPath: workspace.path) {
            let descriptor = Darwin.open(workspace.appendingPathComponent("job.lock").path, O_RDWR)
            guard descriptor >= 0 else { throw StudioError("无法读取此下载任务。") }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw StudioError("下载进程尚未退出，请稍后重试。")
            }
            try fm.removeItem(at: workspace)
        }
        try fm.removeItem(at: downloadReceipt)
        pendingDownload = nil
        downloadPhase = nil
    }

    private func run(command: String, model: LocalModel, output: URL?, activity: String,
                     editSource: URL? = nil,
                     finalize: ((URL) throws -> Void)? = nil,
                     completion: InferenceCompletion? = nil,
                     arguments: (URL, URL) throws -> [String]) {
        guard !running else {
            completion?(.failure(StudioError("当前已有任务正在运行。")))
            return
        }
        let executable = tools.appendingPathComponent(command)
        guard fm.isExecutableFile(atPath: executable.path) else {
            let failure = StudioError("找不到已安装的命令 \(command)。")
            if let completion { completion(.failure(failure)) } else { error = failure.localizedDescription }
            return
        }
        let scratch = fm.temporaryDirectory.appendingPathComponent("mflux-studio-\(UUID())", isDirectory: true)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
            let path = try modelPath(model, in: scratch)
            if let output { try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true) }
            let logfile = scratch.appendingPathComponent("run.log")
            try Data().write(to: logfile)
            let handle = try FileHandle(forWritingTo: logfile)
            let task = Process()
            task.executableURL = executable
            task.arguments = try arguments(path, scratch)
            task.currentDirectoryURL = scratch
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "1"
            env["TRANSFORMERS_OFFLINE"] = "1"
            env["HF_DATASETS_OFFLINE"] = "1"
            env["PYTHONUNBUFFERED"] = "1"
            task.environment = env
            task.standardOutput = handle
            task.standardError = handle
            task.terminationHandler = { [weak self] task in
                try? handle.close()
                var saveError: String?
                if task.terminationStatus == 0, let finalize {
                    do { try finalize(scratch) } catch { saveError = error.localizedDescription }
                }
                let finalizeError = saveError
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.monitor?.invalidate()
                    self.monitor = nil
                    self.log = self.readRuntimeLog(logfile)
                    try? self.fm.removeItem(at: scratch)
                    self.running = false
                    self.process = nil
                    defer { self.frameServer.resumeQueue() }
                    if self.stopped {
                        self.message = "已停止。"
                        completion?(.failure(FrameAPIError(409, "cancelled", self.message)))
                    } else if task.terminationStatus != 0 {
                        self.message = "运行失败。请查看下方日志。"
                        completion?(.failure(StudioError(self.message)))
                    } else if let finalizeError {
                        self.message = finalizeError
                        completion?(.failure(StudioError(finalizeError)))
                    } else if let output {
                        if let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                           CGImageSourceGetType(source) == UTType.png.identifier as CFString,
                           let image = ReferenceImage(url: output) {
                            let result = StudioResult(image: image, elapsed: elapsed)
                            if let completion {
                                completion(.success(result))
                            } else {
                                self.outputResult = result
                                if let editSource { self.localEditResults[editSource] = result }
                            }
                            self.message = "图片已保存。"
                        } else {
                            self.message = "mflux 未生成可读取的 PNG 图片。"
                            completion?(.failure(StudioError(self.message)))
                        }
                    } else {
                        self.message = "模型文件检查通过。"
                    }
                }
            }
            try task.run()
            process = task
            stopped = false
            log = ""
            message = activity
            running = true
            monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let latest = self.readRuntimeLog(logfile)
                if self.log != latest { self.log = latest }
            }
        } catch {
            try? fm.removeItem(at: scratch)
            if let completion { completion(.failure(error)) } else { self.error = error.localizedDescription }
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        stopped = true
        process.terminate()
    }
}

