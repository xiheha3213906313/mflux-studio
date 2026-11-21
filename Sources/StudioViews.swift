import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let studioAccent = NSColor(srgbRed: 64.0 / 255, green: 102.0 / 255, blue: 232.0 / 255, alpha: 1)

final class ModelDraft: ObservableObject {
    @Published var name: String
    @Published var familyID: String
    @Published var kind: PackageKind
    @Published var files: ModelImportFiles
    @Published var error = ""
    @Published var showsFiles = false
    @Published var showsOptionalFiles = false
    @Published var fileDetails: String?

    init(studio: Studio, existing: LocalModel?, source: LocalModel?) {
        name = existing?.name ?? ""
        familyID = existing?.familyID ?? source?.familyID ?? studio.selected?.familyID ?? "flux2-klein-4b"
        kind = existing?.kind ?? (source == nil ? .model : .assembly)
        files = existing.map { studio.importFiles(for: $0) } ?? ModelImportFiles(componentSource: source?.folder)
    }
}

struct ModelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var studio: Studio
    @StateObject private var draft: ModelDraft
    let existing: LocalModel?

    init(studio: Studio, existing: LocalModel?, source: LocalModel?) {
        self.studio = studio
        self.existing = existing
        _draft = StateObject(wrappedValue: ModelDraft(studio: studio, existing: existing, source: source))
    }

    private var family: Family { Family.find(draft.familyID) ?? Family.all[0] }
    private var candidates: [LocalModel] { studio.componentSources(for: family) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "添加到模型库" : "编辑模型").font(.title2.bold())
            modelFields
            filePanel
            if !draft.error.isEmpty {
                Label(draft.error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: saveModel)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasFiles)
            }
        }
        .padding(20)
        .frame(width: 495)
        .onChange(of: draft.kind) { _, kind in
            draft.error = ""
            draft.fileDetails = nil
            if kind == .assembly && draft.files.componentSource == nil { draft.files.componentSource = candidates.first?.folder }
        }
    }

    private var modelFields: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("类型", selection: $draft.kind) {
                ForEach(PackageKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            modelField("名称") { TextField("显示名称", text: $draft.name).textFieldStyle(.roundedBorder) }
            HStack(alignment: .top, spacing: 12) {
                modelField("架构") {
                    ParameterPopup(title: "架构", selection: Binding(get: { family.group }, set: { selected in
                        if let first = Family.all.first(where: { $0.group == selected }) { changeFamily(first.id) }
                    }), options: ModelGroup.allCases, label: \.title)
                }
                modelField("版本") {
                    let versions = Family.all.filter { $0.group == family.group }.map { ModelChoice(id: $0.id, label: $0.variant) }
                    ParameterPopup(title: "版本", selection: Binding(get: {
                        ModelChoice(id: family.id, label: family.variant)
                    }, set: { changeFamily($0.id) }), options: versions, label: \.label)
                }
                .frame(width: 130)
            }
        }
    }

    private func modelField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content().frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    private var filePanel: some View {
        let border = RoundedRectangle(cornerRadius: 8)
        return VStack(alignment: .leading, spacing: 0) {
            disclosureButton("模型文件", status: "\(selectedFileGroups) / \(requiredFileGroups) 项已选", isExpanded: $draft.showsFiles)
                .padding(.horizontal, 12)
                .frame(height: 36)
            if draft.showsFiles {
                Divider()
                ViewThatFits(in: .vertical) {
                    fileRows.fixedSize(horizontal: false, vertical: true)
                    ScrollView { fileRows }
                }
                .frame(maxHeight: 264)
            }
        }
        .background(.background, in: border)
        .overlay(border.strokeBorder(.quaternary).allowsHitTesting(false))
    }

    private var fileRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if draft.kind != .components {
                fileRow("底模权重", files: $draft.files.transformer,
                        hint: family.group == .seedvr2 ? "选择单个 3B .safetensors 权重。" : "可同时选取权重、分片索引和 config.json。",
                        extensions: family.group == .seedvr2 ? ["safetensors"] : ["safetensors", "json"], suggestName: true)
            }
            if draft.kind == .assembly {
                componentPicker
            } else {
                ForEach(family.group.componentFolders, id: \.self) { part in
                    fileRow(componentName(part), files: componentFiles(part), hint: componentHint(part))
                }
                Divider().padding(.vertical, 4)
                let optionalCount = (draft.files.components["scheduler"]?.count ?? 0) + draft.files.metadata.count
                disclosureButton("附加配置", status: optionalCount == 0 ? "可选" : "\(optionalCount) 个文件", isExpanded: $draft.showsOptionalFiles)
                    .frame(height: 29)
                if draft.showsOptionalFiles {
                    fileRow("采样调度配置", files: componentFiles("scheduler"),
                            hint: "例如 scheduler_config.json。", extensions: ["json"])
                    fileRow("模型附加配置", files: $draft.files.metadata,
                            hint: "例如 model_index.json 或 mflux_model.json。", extensions: ["json", "jinja"])
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosureButton(_ title: String, status: String, isExpanded: Binding<Bool>) -> some View {
        Button { isExpanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(status).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue("\(status)，\(isExpanded.wrappedValue ? "已展开" : "已折叠")")
    }

    private var componentPicker: some View {
        let path = draft.files.componentSource?.path ?? ""
        return HStack {
            Text("已入库配套")
            Spacer(minLength: 8)
            Picker("已入库配套", selection: Binding(get: { draft.files.componentSource?.path ?? "" }, set: { value in
                draft.files.componentSource = value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
                draft.error = ""
            })) {
                Text(candidates.isEmpty ? "暂无匹配配套" : "选择同架构的配套").tag("")
                if !path.isEmpty, !candidates.contains(where: { $0.path == path }) {
                    Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                }
                ForEach(candidates) { Text($0.name).tag($0.path) }
            }
            .labelsHidden()
            .frame(width: 200, alignment: .trailing)
            .disabled(candidates.isEmpty && path.isEmpty)
            .help(candidates.isEmpty ? "可切换到「完整模型」逐项导入。" : "选择同架构的配套")
        }
        .frame(minHeight: 33)
    }

    private struct ModelChoice: Equatable {
        let id: String
        let label: String
    }

    private var requiredFileGroups: Int {
        if draft.kind == .assembly { return 2 }
        return family.group.componentFolders.count + (draft.kind == .model ? 1 : 0)
    }

    private var selectedFileGroups: Int {
        let weight = draft.kind != .components && hasTransformer ? 1 : 0
        if draft.kind == .assembly { return weight + (draft.files.componentSource != nil ? 1 : 0) }
        return weight + family.group.componentFolders.filter { !(draft.files.components[$0] ?? []).isEmpty }.count
    }

    private var hasTransformer: Bool {
        draft.files.transformer.contains { $0.pathExtension.lowercased() == "safetensors" }
    }

    private var hasFiles: Bool {
        selectedFileGroups == requiredFileGroups
    }

    private func changeFamily(_ id: String) {
        guard id != draft.familyID, let selected = Family.find(id) else { return }
        let shared = selected.sharesComponents(with: family)
        draft.familyID = id
        draft.error = ""
        draft.fileDetails = nil
        draft.files.transformer = []
        draft.files.metadata = []
        if !shared {
            draft.files.components = [:]
            draft.files.componentSource = nil
        }
        if draft.kind == .assembly,
           !candidates.contains(where: { $0.path == draft.files.componentSource?.path }) {
            draft.files.componentSource = candidates.first?.folder
        }
    }

    private func saveModel() {
        do {
            try studio.saveModelImport(name: draft.name, familyID: draft.familyID, files: draft.files,
                                       kind: draft.kind, replacing: existing?.id)
            dismiss()
        } catch { draft.error = error.localizedDescription }
    }

    private func componentFiles(_ part: String) -> Binding<[URL]> {
        Binding(get: { draft.files.components[part] ?? [] }, set: { files in
            draft.files.components[part] = files.isEmpty ? nil : files
        })
    }

    private func componentName(_ part: String) -> String {
        switch part {
        case "text_encoder": "文本编码器"
        case "text_encoder_2": "第二文本编码器"
        case "tokenizer": "分词器／词表"
        case "tokenizer_2": "第二分词器／词表"
        case "processor": "图文处理器"
        case "vae": "VAE"
        default: part
        }
    }

    private func componentHint(_ part: String) -> String {
        if family.group == .seedvr2 && part == "vae" { return "选择单个 VAE .safetensors 文件。" }
        if part.hasPrefix("tokenizer") || part == "processor" { return "选择该组件的词表、分词器或处理器配置文件。" }
        return "选择该组件的权重文件，以及随权重提供的配置和分片索引。"
    }

    private func fileRow(_ title: String, files: Binding<[URL]>, hint: String,
                         extensions: [String] = ["safetensors", "json", "txt", "model", "jinja", "tiktoken"],
                         suggestName: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if !files.wrappedValue.isEmpty {
                Button("\(files.wrappedValue.count) 个文件") { draft.fileDetails = title }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .help("查看已选的\(title)文件")
                    .popover(isPresented: Binding(get: { draft.fileDetails == title }, set: { showing in
                        if !showing && draft.fileDetails == title { draft.fileDetails = nil }
                    })) {
                        selectedFiles(title, files: files, hint: hint)
                    }
            }
            Button {
                chooseFiles(title, into: files, extensions: extensions, suggestName: suggestName)
            } label: {
                Text("选择文件…").frame(width: 76)
            }
            .help(hint)
            .accessibilityLabel("选择\(title)文件")
        }
        .frame(minHeight: 33)
    }

    private func selectedFiles(_ title: String, files: Binding<[URL]>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .vertical) {
                selectedFileList(files).fixedSize(horizontal: false, vertical: true)
                ScrollView { selectedFileList(files) }
            }
            .frame(maxHeight: 170)
        }
        .padding(12)
        .frame(width: 335)
    }

    private func selectedFileList(_ files: Binding<[URL]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files.wrappedValue, id: \.self) { url in
                HStack {
                    Label(url.lastPathComponent, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                        .help(url.path)
                    Spacer(minLength: 0)
                    Button {
                        files.wrappedValue.removeAll { $0 == url }
                        if files.wrappedValue.isEmpty { draft.fileDetails = nil }
                        draft.error = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除 \(url.lastPathComponent)")
                }
            }
        }
    }

    private func chooseFiles(_ title: String, into files: Binding<[URL]>, extensions: [String], suggestName: Bool) {
        let panel = NSOpenPanel()
        panel.title = "选择\(title)文件"
        panel.prompt = "添加"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = extensions.map { UTType(filenameExtension: $0, conformingTo: .data) ?? .data }
        panel.directoryURL = files.wrappedValue.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }
        let selected = panel.urls.map(\.standardizedFileURL)
        files.wrappedValue = Array(Set(files.wrappedValue + selected)).sorted { $0.path < $1.path }
        if draft.name.isEmpty {
            if suggestName, let weight = selected.first(where: { $0.pathExtension.lowercased() == "safetensors" }) {
                draft.name = weight.deletingPathExtension().lastPathComponent
            } else if draft.kind == .components {
                draft.name = "\(family.label) · 配套"
            }
        }
        draft.error = ""
    }

}

struct CatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var studio: Studio
    @StateObject private var selection: CatalogSelection

    init(studio: Studio, initialGroup: ModelGroup) {
        self.studio = studio
        _selection = StateObject(wrappedValue: CatalogSelection(initialGroup))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("预设模型").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selection.group) {
                    ForEach(ModelGroup.allCases) { group in
                        Label(group.title, systemImage: "square.stack.3d.up")
                            .tag(group)
                    }
                }
                .listStyle(.sidebar).frame(width: 206)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(selection.group.title).font(.title2.bold())
                        ForEach(Family.all.filter { $0.group == selection.group }) { family in
                            presetRow(family)
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if studio.downloadPhase != nil || !studio.downloadMessage.isEmpty || !studio.downloadLog.isEmpty {
                Divider()
                transferStatus
            }
        }.frame(width: 830, height: 560)
    }

    private func presetRow(_ family: Family) -> some View {
        let model = studio.presetPackage(family, kind: .model)
        let components = studio.presetPackage(family, kind: .components)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(family.variant).font(.headline)
                Text("\(family.quantizationLabel) · 约 \(downloadSize(family.downloadBytes))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("完整模型和配套文件的预计下载大小")
                Spacer()
                Link("模型来源", destination: URL(string: "https://huggingface.co/" + family.presetRepo)!)
                    .font(.caption)
            }
            HStack(spacing: 9) {
                if let model {
                    Button { show(model) } label: { Label("打开完整模型", systemImage: "checkmark.circle") }
                } else {
                    Button { studio.download(family, kind: .model) } label: {
                        Label("下载完整模型", systemImage: "arrow.down.circle")
                    }.buttonStyle(.borderedProminent).disabled(studio.downloadLabel != nil)
                }
                if let components, components.kind == .components {
                    Button { show(components) } label: { Label("打开已下载配套", systemImage: "square.stack.3d.up") }
                } else if model != nil {
                    Label("完整模型已含配套", systemImage: "checkmark")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Button { studio.download(family, kind: .components) } label: {
                            Label("仅下载配套", systemImage: "square.stack.3d.down.right")
                        }
                        .disabled(studio.downloadLabel != nil)
                        Text("约 \(downloadSize(family.componentDownloadBytes))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func show(_ model: LocalModel) {
        studio.select(model)
        dismiss()
    }

    private func downloadSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private var transferStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let phase = studio.downloadPhase, let label = studio.downloadLabel {
                HStack(spacing: 10) {
                    if phase != .paused { ProgressView().controlSize(.small) }
                    Text("\(phase.title) · \(label)").lineLimit(1)
                    Spacer()
                    if phase == .downloading {
                        Button("暂停下载", action: studio.pauseDownload)
                    } else if phase == .paused {
                        Button("继续下载", action: studio.resumeDownload).buttonStyle(.borderedProminent)
                    }
                    if phase != .cancelling {
                        Button("取消下载", role: .destructive, action: studio.cancelDownload)
                            .help("清除本次任务的临时下载文件")
                    }
                }
                .font(.callout)
            }
            if !studio.downloadMessage.isEmpty {
                Text(studio.downloadMessage).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if !studio.downloadLog.isEmpty {
                DisclosureGroup("下载日志") {
                    ScrollView {
                        Text(studio.downloadLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 105)
                }.font(.callout)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

final class CatalogSelection: ObservableObject {
    @Published var group: ModelGroup
    init(_ group: ModelGroup) { self.group = group }
}

enum LibraryCategory: String, CaseIterable, Identifiable {
    case models = "模型"
    case adapters = "LoRA"
    var id: Self { self }
}

final class Presentation: ObservableObject {
    @Published var libraryCategory = LibraryCategory.models
    @Published var modelSheet = false
    @Published var catalog = false
    @Published var catalogGroup = ModelGroup.flux2Small
    @Published var preview: ReferenceImage?
    @Published var upscale: ReferenceImage?
    @Published var logDetails = false
    @Published var comparingLocalEdit = false
    @Published var editing: LocalModel?
    @Published var componentSource: LocalModel?
    @Published var framePanel = false
    @Published var pendingTrash: LocalModel?
}

struct StudioView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var appSettings: StudioAppSettings
    @StateObject private var presentation = Presentation()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow
    private let workspacePadding: CGFloat = 22
    private let workspaceMaxWidth: CGFloat = 980
    private let footerHeight: CGFloat = 62
    private var dimensionAccent: NSColor? { appearsActive && !studio.running ? studioAccent : nil }
    private var dimensionTextColor: Color { dimensionAccent.map { Color(nsColor: $0) } ?? .primary }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                sidebar.frame(maxHeight: .infinity)
                sidebarActions.frame(height: footerHeight)
            }
            .frame(minWidth: 222, idealWidth: 238, maxWidth: 260)
            .background(sidebarColor)
            GeometryReader { geometry in
                let inset = workspacePadding + max(0, (geometry.size.width - workspaceMaxWidth) / 2)
                VStack(spacing: 0) {
                    workspace(inset: inset)
                    Divider()
                    createBar(inset: inset)
                        .frame(height: footerHeight)
                        .background(.background)
                }
            }
            .frame(minWidth: 508)
        }
        .frame(minWidth: 790, minHeight: 600)
        .tint(Color(nsColor: studioAccent))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .task {
            appSettings.prepareWindow(openWindow)
            studio.frameServer.restorePreference()
        }
        .sheet(isPresented: $presentation.modelSheet) {
            ModelEditor(studio: studio, existing: presentation.editing, source: presentation.componentSource)
        }
        .sheet(isPresented: $presentation.catalog) { CatalogView(studio: studio, initialGroup: presentation.catalogGroup) }
        .sheet(isPresented: $presentation.framePanel) {
            FramePanel(server: studio.frameServer, appSettings: appSettings)
        }
        .sheet(item: $presentation.preview) { image in
            VStack(spacing: 12) {
                HStack {
                    Text("图片预览").font(.headline)
                    Spacer()
                    Button("完成") { presentation.preview = nil }.keyboardShortcut(.cancelAction)
                }
                FittedPicture(reference: image)
            }
            .padding(18)
            .frame(width: 710, height: 580)
        }
        .sheet(item: $presentation.upscale) { image in
            UpscalePanel(studio: studio, image: image)
        }
        .alert("操作未完成", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("好", role: .cancel) { studio.error = nil }
        } message: { Text(studio.error ?? "") }
        .confirmationDialog(presentation.pendingTrash?.importFiles == nil ? "把原始文件移到废纸篓？" : "把导入配置移到废纸篓？", isPresented: Binding(
            get: { presentation.pendingTrash != nil }, set: { if !$0 { presentation.pendingTrash = nil } }
        ), titleVisibility: .visible, presenting: presentation.pendingTrash) { model in
            Button("移到废纸篓", role: .destructive) { studio.remove(model, trash: true) }
            Button("取消", role: .cancel) {}
        } message: { model in Text(model.source.path) }
    }

    private var sidebarColor: Color { Color(white: colorScheme == .dark ? 0.10 : 0.91) }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("模型库").font(.title3.bold())
                    Spacer()
                    let count = presentation.libraryCategory == .models ? studio.models.count : studio.adapterLibrary.count
                    Text("\(count)").foregroundStyle(.secondary).font(.caption.monospacedDigit())
                }
                Picker("模型库分类", selection: $presentation.libraryCategory) {
                    ForEach(LibraryCategory.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 10)

            if presentation.libraryCategory == .models { modelList } else { adapterList }
        }
    }

    private var modelList: some View {
        List(selection: Binding(get: { studio.selection }, set: { id in
            if let model = studio.models.first(where: { $0.id == id }) { studio.select(model) }
        })) {
            ForEach(ModelGroup.allCases) { group in
                let entries = studio.entries(in: group)
                if !entries.isEmpty {
                    Section(group.title) {
                        ForEach(entries) { model in
                            libraryRow(model).tag(model.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if studio.models.isEmpty {
                Text("从预设下载，或导入本地模型。")
                    .font(.callout).foregroundStyle(.secondary).padding(14)
            }
        }
    }

    private var adapterList: some View {
        let groups = Dictionary(grouping: studio.adapterLibrary) { $0.family?.group }
        return List {
            ForEach(ModelGroup.allCases) { group in
                if let entries = groups[group] {
                    Section(group.title) { ForEach(entries) { adapterRow($0) } }
                }
            }
            if let entries = groups[nil] {
                Section("其他") { ForEach(entries) { adapterRow($0) } }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if studio.adapterLibrary.isEmpty {
                Text("导入 LoRA 后，可为匹配的模型加载。")
                    .font(.callout).foregroundStyle(.secondary).padding(14)
            }
        }
    }

    private func adapterRow(_ adapter: LibraryAdapter) -> some View {
        let active = studio.adapterIsActive(adapter)
        return HStack(spacing: 9) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 23).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(adapter.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(adapter.family?.variant ?? adapter.familyID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if adapter.familyID == studio.activeModel?.familyID {
                Button { studio.toggleAdapter(adapter) } label: {
                    Image(systemName: active ? "checkmark.circle.fill" : "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(studio.running)
                .help(active ? "从本次生成卸载" : "加载到当前模型")
                .accessibilityLabel(active ? "卸载 \(adapter.name)" : "加载 \(adapter.name)")
            }
        }
        .padding(.vertical, 4)
        .help(adapter.name)
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([adapter.url]) }
            Button("从 LoRA 库移除", role: .destructive) { studio.removeLibraryAdapter(adapter) }.disabled(studio.running)
        }
    }

    private var sidebarActions: some View {
        HStack(spacing: 7) {
            if presentation.libraryCategory == .models {
                Button { openCatalog(studio.selected?.family?.group ?? .flux2Small) } label: {
                    Label(studio.downloadPhase?.title ?? "预设模型", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                Button { openEditor() } label: {
                    Label("导入本地", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }.disabled(studio.running)
            } else {
                Button { studio.importAdapters() } label: {
                    Label("导入 LoRA", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }.disabled(studio.running)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 10)
    }

    private func libraryRow(_ model: LocalModel) -> some View {
        HStack(spacing: 9) {
            Image(systemName: model.kind.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(studio.selection == model.id ? Color.primary : model.kind == .components ? Color.secondary : Color.accentColor)
                .frame(width: 23).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                Text([model.family?.variant, model.kind.rawValue].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .help(model.name)
        .contextMenu { modelActions(model) }
    }

    private func openCatalog(_ group: ModelGroup) {
        presentation.catalogGroup = group
        presentation.catalog = true
    }

    private func workspace(inset: CGFloat) -> some View {
        VStack(spacing: 0) {
            workspaceHeader(inset: inset)
            ScrollView {
                Group {
                    if let model = studio.selected, model.kind == .components {
                        componentDetails(model)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            if studio.activeModel == nil && !studio.isLocalEditing { generationModelNeeded }
                            composer
                            outputView
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.bottom, workspacePadding)
            }
        }
    }

    private var generationModelNeeded: some View {
        HStack(spacing: 12) {
            Text("选择一个本地生图模型").font(.headline)
            Spacer(minLength: 4)
            Button("打开预设模型") { openCatalog(.flux2Small) }
        }.modifier(Card())
    }

    private func workspaceHeader(inset: CGFloat) -> some View {
        let selected = studio.selected
        let model = selected?.kind == .components ? selected : studio.generationModel ?? studio.activeModel
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model?.name ?? "MFlux Studio")
                    .font(.system(size: 23, weight: .bold)).lineLimit(1).truncationMode(.tail)
                if let model {
                    Text(model.family.map { "\($0.label) · \(model.kind.rawValue)" } ?? model.kind.rawValue)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Button { presentation.framePanel = true } label: {
                Label("连接映序", systemImage: "iphone")
            }
            .fixedSize()
            Button { studio.open(studio.images) } label: {
                Label("图片文件夹", systemImage: "folder")
            }
            .fixedSize()
            .disabled(!FileManager.default.fileExists(atPath: studio.images.path))
            if let model {
                Menu {
                    Button("检查模型") { studio.validate(model) }
                    Toggle("低内存模式", isOn: $studio.lowRAM)
                    if studio.isLocalEditing, model.kind != .components, let active = studio.activeModel, active.id != model.id {
                        Button("检查局部编辑模型") { studio.validate(active) }
                    }
                    Divider()
                    modelActions(model)
                } label: {
                    Label("管理模型", systemImage: "ellipsis.circle")
                }
                .menuOrder(.fixed)
                .fixedSize().disabled(studio.running)
            }
        }
        .padding(.leading, inset).padding(.trailing, workspacePadding).padding(.vertical, 15)
        .frame(minHeight: 67)
    }

    @ViewBuilder private func modelActions(_ model: LocalModel) -> some View {
        Button("编辑名称或路径…") { openEditor(editing: model) }.disabled(studio.running)
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.source]) }
        if model.kind != .assembly {
            Button("用这套配套组装底模…") { openEditor(source: model) }.disabled(studio.running)
        }
        Divider()
        Button("从模型库移除") { studio.remove(model, trash: false) }.disabled(studio.running)
        Button(model.importFiles == nil ? "将原文件移到废纸篓…" : "将导入配置移到废纸篓…", role: .destructive) { presentation.pendingTrash = model }
            .disabled(studio.running)
    }

    private func openEditor(editing model: LocalModel? = nil, source: LocalModel? = nil) {
        presentation.editing = model
        presentation.componentSource = source
        presentation.modelSheet = true
    }

    private func componentDetails(_ model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配套文件").font(.title3.bold())
            if let family = model.family {
                let seedVAE = "ema_vae_fp16.safetensors"
                let parts = family.group == .seedvr2 && FileManager.default.fileExists(atPath: model.folder.appendingPathComponent(seedVAE).path)
                    ? [seedVAE] : family.group.componentFolders
                ForEach(parts, id: \.self) { part in
                    Label(part, systemImage: "folder")
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button("在 Finder 中打开") { studio.open(model.folder) }
                Spacer()
                Button { openEditor(source: model) } label: { Label("组装底模", systemImage: "link") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .modifier(Card())
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 18) {
            referenceEditor
            VStack(alignment: .leading, spacing: 8) {
                Text("提示词").font(.headline)
                PromptEditor(text: $studio.prompt)
                    .frame(height: 108)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary).allowsHitTesting(false))
            }

            if let family = studio.activeModel?.family {
                let size = studio.isLocalEditing ? $studio.repairSize : studio.editing ? $studio.editSize : $studio.size
                let source = studio.isLocalEditing ? studio.repairInput : studio.editing ? studio.references.first : nil
                generationSettings(size: size, source: source?.resolution, family: family)
                loraEditor
            }
        }
        .padding(.vertical, 12)
    }

    private func generationSettings(size: Binding<GenerationSize>, source: PixelResolution?, family: Family) -> some View {
        let referenced = source != nil
        let dimensionColumnWidth: CGFloat = 164
        return VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    field("比例") {
                        if studio.isLocalEditing {
                            readOnlyParameter("比例", value: OutputRatio.original.rawValue).foregroundStyle(dimensionTextColor)
                        } else {
                            let options = OutputRatio.allCases.filter { referenced || $0 != .original }
                            dimensionPopup("输出比例", selection: size.ratio, options: options, label: \.rawValue)
                        }
                    }
                    .frame(width: dimensionColumnWidth)
                    field("步数") {
                        HStack(spacing: 3) {
                            TextField("步数", value: $studio.steps, format: .number)
                            Stepper("调整步数", value: $studio.steps, in: family.minimumSteps...150).labelsHidden()
                        }
                    }
                    seedField
                }
                GridRow {
                    field("分辨率") {
                        resolutionField(size, source: source, step: family.dimensionStep)
                    }
                    .frame(width: dimensionColumnWidth)
                    field(family.group == .flux1 || family.group == .fill ? "引导强度" : "CFG") {
                        if let defaultValue = family.guidanceDefault {
                            TextField("默认 \(defaultValue.formatted())", text: $studio.guidance)
                                .accessibilityLabel("CFG 指导强度")
                        } else {
                            let fixed = [.flux2Small, .flux2Large].contains(family.group) ? "固定 1" : "模型固定"
                            readOnlyParameter("CFG", value: fixed)
                        }
                    }
                    field("采样／调度") {
                        let choices = family.samplers(referenced: referenced)
                        if choices.isEmpty {
                            readOnlyParameter("采样／调度", value: family.samplerLabel(referenced: referenced))
                        } else {
                            let selection = Binding(
                                get: { choices.contains(studio.sampler) ? studio.sampler : .automatic },
                                set: { studio.sampler = $0 }
                            )
                            ParameterPopup(title: "采样／调度", selection: selection, options: [.automatic] + choices, label: \.label)
                        }
                    }
                }
            }
            if family.acceptsNegativePrompt {
                field("负面提示词") {
                    TextField("可选", text: $studio.negativePrompt).accessibilityLabel("负面提示词")
                        .help("使用 CFG 大于 1 时可引导模型避开指定内容。")
                }
            }
            if referenced && !studio.isLocalEditing && family.usesInitImage {
                field("参考图影响") {
                    HStack {
                        Slider(value: $studio.imageStrength, in: 0.01...1)
                        Text(studio.imageStrength.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.regular)
        .disabled(studio.running)
    }

    @ViewBuilder private func resolutionField(_ size: Binding<GenerationSize>, source: PixelResolution?, step: Int) -> some View {
        if size.wrappedValue.ratio == .free {
            HStack(spacing: 6) {
                dimensionField("宽", value: size.width)
                dimensionField("高", value: size.height)
            }
            .help("宽和高须为 \(step) 的正整数倍。")
        } else {
            let options = size.wrappedValue.options(source: source, step: step)
            if let current = size.wrappedValue.choose(from: options, source: source) {
                let selection = Binding(
                    get: { size.wrappedValue.choose(from: options, source: source) ?? current },
                    set: { size.wrappedValue.resolution = $0 }
                )
                dimensionPopup("输出分辨率", selection: selection, options: options, label: \.label)
                    .help(size.wrappedValue.ratio == .original
                          ? "原图比例无法精确匹配时，取最接近且宽高为 \(step) 的倍数的尺寸。"
                          : "宽和高为 \(step) 的倍数。")
            }
        }
    }

    private func dimensionPopup<Value: Equatable>(_ title: String, selection: Binding<Value>, options: [Value],
                                                   label: KeyPath<Value, String>) -> some View {
        ParameterPopup(title: title, selection: selection, options: options, label: label,
                       isBordered: false, selectedTextColor: dimensionAccent)
            .padding(.horizontal, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary).allowsHitTesting(false))
    }

    private func dimensionField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 3) {
            Text("\(label)：").font(.caption).foregroundStyle(.secondary).fixedSize()
            TextField(label, value: value, format: .number.grouping(.never))
                .foregroundStyle(dimensionTextColor)
                .accessibilityLabel(label == "宽" ? "宽度（像素）" : "高度（像素）")
        }
        .frame(maxWidth: .infinity)
    }

    private var seedField: some View {
        field("种子") {
            TextField("自动", text: $studio.seed).accessibilityLabel("随机种子")
        }
    }

    private func readOnlyParameter(_ label: String, value: String) -> some View {
        TextField(label, text: .constant(value)).disabled(true)
    }

    private func localEditControls(_ source: ReferenceImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if studio.repairModels.isEmpty {
                HStack {
                    Text("局部编辑需要 FLUX.1 Fill 或 Qwen-Image 2.1。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看预设模型") { openCatalog(.fill) }
                }
            } else {
                Picker("编辑模型", selection: Binding(get: { studio.repairModel?.id }, set: studio.selectRepairModel)) {
                    ForEach(studio.repairModels) { model in Text(model.name).tag(Optional(model.id)) }
                }
            }
            localEditComparison(source)
        }
    }

    private func localEditComparison(_ source: ReferenceImage) -> some View {
        let result = studio.localEditResults[source.id]
        let previewHeight: CGFloat = 260
        let corners = RoundedRectangle(cornerRadius: 7)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text("涂抹区域").font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    Button {
                        if !studio.repairStrokes.isEmpty { studio.repairStrokes.removeLast() }
                    } label: { Label("撤销一笔", systemImage: "arrow.uturn.backward") }
                        .help("撤销一笔")
                        .disabled(studio.repairStrokes.isEmpty)
                    Button { studio.erasesRepairMask.toggle() } label: {
                        Label("橡皮擦", systemImage: studio.erasesRepairMask ? "eraser.fill" : "eraser")
                            .foregroundStyle(studio.erasesRepairMask ? Color.accentColor : Color.primary)
                    }
                    .help(studio.erasesRepairMask ? "切回画笔" : "启用橡皮擦，按住左键拖动擦除")
                    .accessibilityAddTraits(studio.erasesRepairMask ? .isSelected : [])
                    Button { studio.repairStrokes = [] } label: {
                        BroomIcon().stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                            .frame(width: 15, height: 15)
                    }
                    .help("清除全部涂画")
                    .accessibilityLabel("清除全部涂画")
                    .disabled(studio.repairStrokes.isEmpty)
                }
                .labelStyle(.iconOnly)
                .frame(height: 24)
                MaskCanvas(source: source, strokes: studio.repairStrokes, brush: studio.brushSize,
                           erases: studio.erasesRepairMask) { stroke in
                    if !stroke.erases || studio.hasMaskStrokes { studio.repairStrokes.append(stroke) }
                }
                .id(source.id)
                .frame(height: previewHeight)
                .background(.secondary.opacity(0.07), in: corners)
                Slider(value: $studio.brushSize, in: 0.01...0.4) {
                    Text("笔刷大小").font(.callout)
                }
                .frame(maxWidth: 250)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text("结果").font(.callout.weight(.medium))
                        if let result { elapsedLabel(result) }
                    }
                    Spacer(minLength: 0)
                    if let result {
                        Button {
                            presentation.comparingLocalEdit.toggle()
                        } label: {
                            Label("对比", systemImage: "rectangle.split.2x1")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(presentation.comparingLocalEdit ? Color.accentColor : Color.primary)
                        }
                        .help("开启后把鼠标移到结果图上进行对比")
                        .accessibilityAddTraits(presentation.comparingLocalEdit ? .isSelected : [])
                        resultActions(result.image, compact: true).labelStyle(.iconOnly)
                    }
                }
                .frame(height: 24)
                ZStack {
                    corners.fill(.secondary.opacity(0.07))
                    if let result {
                        EditResultPreview(source: source, result: result.image, comparing: presentation.comparingLocalEdit) {
                            presentation.preview = result.image
                        }
                        .id(result.image.id)
                    } else {
                        Text("等待生成").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(height: previewHeight)
                .clipShape(corners)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var referenceEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("参考图").font(.headline)
                Spacer()
                Button {
                    if studio.isLocalEditing { studio.endLocalEdit() }
                    else { studio.beginLocalEdit() }
                } label: {
                    Label(studio.isLocalEditing ? "退出编辑" : "局部编辑",
                          systemImage: studio.isLocalEditing ? "xmark.circle" : "paintbrush.pointed")
                }
                .help(studio.isLocalEditing ? "关闭局部编辑" : "涂抹参考图中要编辑的区域")
                if studio.supportsEditing || studio.isLocalEditing {
                    Button { studio.chooseReferences() } label: {
                        Label("添加参考图", systemImage: "photo.badge.plus")
                    }
                }
            }
            if (studio.supportsEditing || studio.isLocalEditing) && !studio.references.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 92), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(studio.references.enumerated()), id: \.element.id) { index, reference in
                        let selected = reference.id == studio.localEditImageID
                        let canDrag = !studio.isLocalEditing || selected
                        let actionLabel = studio.isLocalEditing ? "编辑参考图 \(index + 1)" : "预览参考图 \(index + 1)"
                        DraggableReference(reference: reference, index: index + 1, canDrag: canDrag, actionLabel: actionLabel) {
                            if studio.isLocalEditing {
                                studio.beginLocalEdit(with: reference)
                            } else {
                                presentation.preview = reference
                            }
                        }
                            .frame(width: 76, height: 76)
                            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                thumbnailClose("移除参考图 \(index + 1)") { studio.removeReference(reference) }
                                    .padding(4)
                            }
                            .contextMenu {
                                Button("局部编辑此图") { studio.beginLocalEdit(with: reference) }
                            }
                            .help(canDrag ? "\(actionLabel) · 拖入提示词引用" : actionLabel)
                    }
                }
            }
            if let source = studio.repairInput { localEditControls(source).padding(.top, 3) }
        }
        .disabled(studio.running)
    }

    private func thumbnailClose(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 17, height: 17)
                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                .overlay(Circle().strokeBorder(.secondary.opacity(0.35)))
                .frame(width: 23, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var loraEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LoRA").font(.headline)
                Spacer()
                Button { studio.addAdapters() } label: { Label("添加 LoRA", systemImage: "plus") }
            }
            ForEach($studio.adapters) { $adapter in
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).frame(width: 46)
                    Text(adapter.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Slider(value: $adapter.strength, in: 0...2)
                        .frame(width: 108).accessibilityLabel("LoRA 强度")
                    Text(adapter.strength.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit().frame(width: 33, alignment: .trailing)
                    removeButton("移除 LoRA") {
                        studio.adapters.removeAll { $0.id == adapter.id }
                    }
                }.font(.callout)
            }
        }.disabled(studio.running)
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                .frame(width: 23, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func createBar(inset: CGFloat) -> some View {
        HStack(spacing: 10) {
            runtimeLog
            if studio.running {
                ProgressView().controlSize(.small)
                Button("停止") { studio.stop() }
            }
            if studio.selected?.kind != .components {
                Button { studio.runTool() } label: {
                    Label("生成图片", systemImage: "sparkles")
                        .frame(minWidth: 82)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!studio.canRun)
            }
        }
        .controlSize(.regular)
        .padding(.leading, inset).padding(.trailing, workspacePadding)
    }

    private var runtimeLog: some View {
        let lines = Array(studio.runtimeLogText.split(separator: "\n").suffix(2))
        return Button { presentation.logDetails.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(String(lines[index])).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看完整运行日志")
        .help("查看完整运行日志")
        .popover(isPresented: $presentation.logDetails, arrowEdge: .bottom) {
            RuntimeLogPanel(studio: studio)
        }
    }

    @ViewBuilder private var outputView: some View {
        if !studio.isLocalEditing, let result = studio.outputResult {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text("结果").font(.headline)
                        elapsedLabel(result)
                    }
                    Spacer(minLength: 10)
                    resultActions(result.image)
                }
                FittedPicture(reference: result.image)
                    .id(result.image.id)
                    .frame(height: 340)
            }
            .modifier(Card())
        }
    }

    private func elapsedLabel(_ result: StudioResult) -> some View {
        Text("\(result.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("本次生成用时")
    }

    @ViewBuilder private func resultActions(_ image: ReferenceImage, compact: Bool = false) -> some View {
        if !compact { Button("打开图片") { presentation.preview = image } }
        if studio.supportsEditing {
            Button { studio.useAsReference(image.url) } label: {
                Label("用作参考图", systemImage: "photo.badge.plus")
            }
            .help("用作参考图")
            .disabled(studio.running)
        }
        Button { presentation.upscale = image } label: {
            Label("高清放大", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("高清放大")
        .disabled(studio.running)
    }
}

private struct ParameterPopup<Value: Equatable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: KeyPath<Value, String>
    var isBordered = true
    var selectedTextColor: NSColor? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .push
        button.isBordered = isBordered
        button.cell?.lineBreakMode = .byTruncatingTail
        if !isBordered, let cell = button.cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem()
            cell.arrowPosition = .arrowAtCenter
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let titles = options.map { $0[keyPath: label] }
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(of: selection), index != button.indexOfSelectedItem {
            button.selectItem(at: index)
        }
        button.isEnabled = isEnabled
        updateDisplayedValue(in: button)
        button.setAccessibilityLabel(title)
        context.coordinator.onSelection = { sender in
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            updateDisplayedValue(in: sender)
            selection = options[index]
        }
    }

    private func updateDisplayedValue(in button: NSPopUpButton) {
        guard !isBordered, let cell = button.cell as? NSPopUpButtonCell, let item = cell.menuItem else { return }
        let title = button.titleOfSelectedItem ?? ""
        let attributed: NSAttributedString?
        if button.isEnabled, let selectedTextColor {
            attributed = NSAttributedString(string: title, attributes: [
                .foregroundColor: selectedTextColor,
                .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            ])
        } else { attributed = nil }
        guard item.title != title || item.attributedTitle != attributed else { return }
        item.title = title
        item.attributedTitle = attributed
        cell.needsSizing = true
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(0, intrinsic.width)
        return CGSize(width: width, height: max(22, intrinsic.height))
    }

    final class Coordinator: NSObject {
        var onSelection: ((NSPopUpButton) -> Void)?
        @objc func choose(_ sender: NSPopUpButton) { onSelection?(sender) }
    }
}

private struct BroomIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var broom = Path()
        broom.move(to: CGPoint(x: 13.5, y: 2))
        broom.addLine(to: CGPoint(x: 8.5, y: 7))
        broom.move(to: CGPoint(x: 7, y: 6))
        broom.addLine(to: CGPoint(x: 10, y: 9))
        broom.addLine(to: CGPoint(x: 7.2, y: 14))
        broom.addLine(to: CGPoint(x: 2, y: 8.8))
        broom.closeSubpath()
        broom.move(to: CGPoint(x: 6, y: 9.5))
        broom.addLine(to: CGPoint(x: 4.1, y: 10.9))
        broom.move(to: CGPoint(x: 7.7, y: 11.2))
        broom.addLine(to: CGPoint(x: 6.1, y: 12.9))
        return broom.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 16, y: rect.height / 16))
    }
}

private struct RuntimeLogPanel: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("运行日志").font(.headline)
                Spacer()
                Button("导出日志…", action: export)
                    .disabled(studio.runtimeLogText.isEmpty)
            }
            ScrollView {
                Text(studio.runtimeLogText.isEmpty ? "暂无运行日志" : studio.runtimeLogText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
        }
        .padding(14)
        .frame(width: 560, height: 300)
    }

    private func export() {
        let text = studio.runtimeLogText
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MFlux-运行日志.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            studio.error = "无法导出日志。\(error.localizedDescription)"
        }
    }
}

private struct UpscalePanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var studio: Studio
    @StateObject private var presentation = Presentation()
    let image: ReferenceImage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("高清放大").font(.title2.bold())
                Spacer()
                Text("\(image.width) × \(image.height)").monospacedDigit().foregroundStyle(.secondary)
            }
            FittedPicture(reference: image).frame(height: 240)
            VStack(alignment: .leading, spacing: 10) {
                if studio.upscaleModels.isEmpty {
                    HStack {
                        Text("需要 SeedVR2 3B。").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("查看预设模型") { presentation.catalog = true }
                    }
                } else {
                    Picker("放大模型", selection: Binding(get: { studio.upscaleModel?.id }, set: studio.selectUpscaleModel)) {
                        ForEach(studio.upscaleModels) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                HStack {
                    Picker("放大倍率", selection: $studio.upscaleScale) {
                        ForEach(["1.5x", "2x", "3x", "4x", Studio.customSize], id: \.self) { Text($0).tag($0) }
                    }
                    if studio.upscaleScale == Studio.customSize {
                        TextField("目标短边（像素）", value: $studio.upscalePixels, format: .number.grouping(.never))
                    }
                    Spacer()
                }
                HStack {
                    Text("柔化")
                    Slider(value: $studio.upscaleSoftness, in: 0...1)
                    Text(studio.upscaleSoftness.formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                }
                TextField("种子（留空自动生成）", text: $studio.seed)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始放大") {
                    if studio.runUpscale(image.url) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(studio.running || studio.upscaleModel == nil)
            }
        }
        .padding(22).frame(width: 545)
        .sheet(isPresented: $presentation.catalog) { CatalogView(studio: studio, initialGroup: .seedvr2) }
        .alert("操作未完成", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("好") { studio.error = nil }
        } message: { Text(studio.error ?? "") }
    }
}

private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

@main
struct MFluxStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @StateObject private var studio = Studio()
    @StateObject private var appSettings = StudioAppSettings()

    var body: some Scene {
        Window("MFlux Studio", id: "studio") {
            StudioView(studio: studio, appSettings: appSettings)
        }
        .defaultSize(width: 960, height: 670)
    }
}
