import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct MaskStroke: Identifiable {
    let id = UUID()
    let diameter: CGFloat
    let erases: Bool
    var points: [CGPoint]

    func path(in size: CGSize) -> CGPath? {
        let scaled = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = scaled.first else { return nil }
        let thickness = diameter * min(size.width, size.height)
        if !scaled.dropFirst().contains(where: { $0 != first }) {
            return CGPath(ellipseIn: CGRect(x: first.x - thickness / 2, y: first.y - thickness / 2,
                                            width: thickness, height: thickness), transform: nil)
        }
        let line = CGMutablePath()
        line.addLines(between: scaled)
        return line.copy(strokingWithWidth: thickness, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}

enum RepairMask {
    private static func write(_ image: CGImage, to url: URL) throws {
        guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError("无法创建临时 PNG。")
        }
        CGImageDestinationAddImage(file, image, nil)
        guard CGImageDestinationFinalize(file) else { throw StudioError("无法保存临时 PNG。") }
    }

    static func stage(source: URL, strokes: [MaskStroke], size: CGSize, in directory: URL) throws {
        let width = Int(size.width), height = Int(size.height)
        guard let original = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(original, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary),
              let rgb = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw StudioError("无法按所选尺寸处理底图或遮罩。")
        }
        let rect = CGRect(origin: .zero, size: size)
        rgb.setFillColor(NSColor.white.cgColor)
        rgb.fill(rect)
        rgb.interpolationQuality = .high
        rgb.draw(image, in: rect)

        gray.setFillColor(gray: 0, alpha: 1)
        gray.fill(rect)
        gray.translateBy(x: 0, y: size.height)
        gray.scaleBy(x: 1, y: -1)
        for stroke in strokes {
            guard let path = stroke.path(in: size) else { continue }
            gray.setFillColor(gray: stroke.erases ? 0 : 1, alpha: 1)
            gray.addPath(path)
            gray.fillPath()
        }
        if let pixels = gray.data?.assumingMemoryBound(to: UInt8.self) {
            let stride = gray.bytesPerRow
            let hasMask = (0..<height).contains { row in
                UnsafeBufferPointer(start: pixels + row * stride, count: width).contains { $0 >= 128 }
            }
            guard hasMask else { throw StudioError("涂抹区域已擦空，请先涂出要编辑的区域。") }
        }
        guard let input = rgb.makeImage(), let mask = gray.makeImage() else {
            throw StudioError("无法生成局部编辑遮罩。")
        }
        try write(input, to: directory.appendingPathComponent("input.png"))
        try write(mask, to: directory.appendingPathComponent("mask.png"))
    }

    static func composite(in directory: URL, output: URL) throws {
        guard let original = CIImage(contentsOf: directory.appendingPathComponent("input.png")),
              let mask = CIImage(contentsOf: directory.appendingPathComponent("mask.png")),
              let edited = CIImage(contentsOf: directory.appendingPathComponent("repaired.png")),
              edited.extent.size == original.extent.size,
              let filter = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: edited, kCIInputBackgroundImageKey: original, kCIInputMaskImageKey: mask,
              ]),
              let combined = filter.outputImage,
              let result = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(combined, from: original.extent) else {
            throw StudioError("无法合成局部编辑结果。请检查输出尺寸和运行日志。")
        }
        try write(result, to: output)
    }
}

struct MaskCanvas: View {
    let source: ReferenceImage
    let strokes: [MaskStroke]
    let brush: Double
    let erases: Bool
    let completed: (MaskStroke) -> Void
    @StateObject private var drawing = ActiveStroke()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { proxy in
            let imageSize = CGSize(width: source.width, height: source.height)
            let viewport = proxy.size
            let frame = drawing.zoom.frame(for: imageSize, in: viewport)
            drawingSurface
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .frame(width: viewport.width, height: viewport.height)
                .background {
                    ImagePointerSurface(scroll: { change, location in
                        if drawing.stroke != nil { return frame.contains(location) }
                        return drawing.zoom.scroll(change, at: location, image: imageSize, viewport: viewport)
                    }, canPan: { location in
                        drawing.stroke == nil && drawing.zoom.canPan(at: location, image: imageSize, viewport: viewport)
                    }, pan: { movement, _ in
                        drawing.zoom.pan(movement, image: imageSize, viewport: viewport)
                    })
                }
                .overlay {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard isEnabled, !frame.isEmpty, frame.contains(value.startLocation) else { return }
                            let point = CGPoint(x: min(1, max(0, (value.location.x - frame.minX) / frame.width)),
                                                y: min(1, max(0, (value.location.y - frame.minY) / frame.height)))
                            if drawing.stroke == nil { drawing.stroke = MaskStroke(diameter: brush, erases: erases, points: []) }
                            drawing.stroke?.points.append(point)
                        }.onEnded { _ in
                            if let stroke = drawing.stroke, isEnabled { completed(stroke) }
                            drawing.stroke = nil
                        })
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel(erases ? "擦除已涂抹的遮罩" : "涂出要编辑的区域")
        .help(erases ? "左键拖动擦除遮罩。滚轮缩放，放大后按住中键拖动。" : "左键拖动涂抹。滚轮缩放，放大后按住中键拖动。")
    }

    private var drawingSurface: some View {
        Canvas { context, size in
            context.drawLayer { layer in
                for stroke in strokes + (drawing.stroke.map { [$0] } ?? []) {
                    guard let path = stroke.path(in: size) else { continue }
                    layer.blendMode = stroke.erases ? .destinationOut : .normal
                    layer.fill(Path(path), with: .color(.red))
                }
            }
        }
        .opacity(0.45)
        .background { FittedPicture(reference: source) }
    }

    private final class ActiveStroke: ObservableObject {
        @Published var stroke: MaskStroke?
        @Published var zoom = ImageZoom()
    }
}

struct EditResultPreview: View {
    let comparing: Bool
    let open: () -> Void
    @StateObject private var original: PreviewBitmap
    @StateObject private var result: PreviewBitmap
    @StateObject private var interaction = PreviewInteraction()
    private let imageSize: CGSize

    init(source: ReferenceImage, result: ReferenceImage, comparing: Bool, open: @escaping () -> Void) {
        self.comparing = comparing
        self.open = open
        imageSize = CGSize(width: result.width, height: result.height)
        _original = StateObject(wrappedValue: PreviewBitmap(source))
        _result = StateObject(wrappedValue: PreviewBitmap(result))
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let frame = interaction.zoom.frame(for: imageSize, in: viewport)
            let visible = frame.intersection(CGRect(origin: .zero, size: viewport))
            let split = comparing ? interaction.pointer.flatMap { visible.contains($0) ? $0.x : nil } : nil
            Button(action: open) {
                ZStack(alignment: .topLeading) {
                    if let split {
                        // Local editing resizes the source to the result dimensions before inference.
                        imageLayer(original.image, frame: frame, visible: visible, viewport: viewport, label: "原图")
                            .mask(alignment: .leading) { Rectangle().frame(width: split) }
                        imageLayer(result.image, frame: frame, visible: visible, viewport: viewport, label: "结果", trailing: true)
                            .mask(alignment: .trailing) { Rectangle().frame(width: viewport.width - split) }
                        Rectangle().fill(.white)
                            .frame(width: 1, height: visible.height)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .position(x: split, y: visible.midY)
                    } else {
                        imageLayer(result.image, frame: frame, visible: visible, viewport: viewport)
                    }
                }
                .frame(width: viewport.width, height: viewport.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if comparing { interaction.pointer = location }
                    case .ended: interaction.pointer = nil
                    }
                }
            }
            .buttonStyle(.plain)
            .background {
                ImagePointerSurface(scroll: { change, location in
                    guard interaction.zoom.scroll(change, at: location, image: imageSize, viewport: viewport) else { return false }
                    if comparing { interaction.pointer = location }
                    return true
                }, canPan: { location in
                    interaction.zoom.canPan(at: location, image: imageSize, viewport: viewport)
                }, pan: { movement, location in
                    interaction.zoom.pan(movement, image: imageSize, viewport: viewport)
                    if comparing { interaction.pointer = location }
                })
            }
        }
        .clipped()
        .accessibilityLabel("打开结果图片")
        .help("滚轮缩放，放大后按住中键拖动")
    }

    private func imageLayer(_ image: NSImage, frame: CGRect, visible: CGRect, viewport: CGSize,
                            label: String? = nil, trailing: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            if let label, !visible.isEmpty {
                Text(label)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
                    .frame(width: visible.width, height: visible.height, alignment: trailing ? .topTrailing : .topLeading)
                    .position(x: visible.midX, y: visible.midY)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
    }

    private final class PreviewInteraction: ObservableObject {
        @Published var zoom = ImageZoom()
        @Published var pointer: CGPoint?
    }
}

private struct ImageZoom {
    private var scale: CGFloat = 1
    private var offset: CGSize = .zero

    func frame(for image: CGSize, in viewport: CGSize) -> CGRect {
        let fit = min(viewport.width / image.width, viewport.height / image.height)
        let width = image.width * fit * scale, height = image.height * fit * scale
        let center = CGSize(width: viewport.width / 2, height: viewport.height / 2)
        return CGRect(x: center.width + bounded(offset.width, excess: width - viewport.width) - width / 2,
                      y: center.height + bounded(offset.height, excess: height - viewport.height) - height / 2,
                      width: width, height: height)
    }

    mutating func scroll(_ change: CGFloat, at location: CGPoint, image: CGSize, viewport: CGSize) -> Bool {
        let previous = frame(for: image, in: viewport)
        guard !previous.isEmpty, previous.contains(location) else { return false }
        let updated = min(8, max(1, scale * exp(change)))
        guard updated != scale else { return true }
        let ratio = updated / scale
        offset = CGSize(width: location.x + (previous.midX - location.x) * ratio - viewport.width / 2,
                        height: location.y + (previous.midY - location.y) * ratio - viewport.height / 2)
        scale = updated
        offset.width = bounded(offset.width, excess: previous.width * ratio - viewport.width)
        offset.height = bounded(offset.height, excess: previous.height * ratio - viewport.height)
        return true
    }

    func canPan(at location: CGPoint, image: CGSize, viewport: CGSize) -> Bool {
        scale > 1 && frame(for: image, in: viewport).contains(location)
    }

    mutating func pan(_ movement: CGSize, image: CGSize, viewport: CGSize) {
        let current = frame(for: image, in: viewport)
        offset.width = bounded(current.midX - viewport.width / 2 + movement.width, excess: current.width - viewport.width)
        offset.height = bounded(current.midY - viewport.height / 2 + movement.height, excess: current.height - viewport.height)
    }

    private func bounded(_ value: CGFloat, excess: CGFloat) -> CGFloat {
        let limit = max(0, excess / 2)
        return min(limit, max(-limit, value))
    }
}

private struct ImagePointerSurface: NSViewRepresentable {
    let scroll: (CGFloat, CGPoint) -> Bool
    let canPan: (CGPoint) -> Bool
    let pan: (CGSize, CGPoint?) -> Void

    func makeNSView(context: Context) -> Surface { Surface(frame: .zero) }

    func updateNSView(_ view: Surface, context: Context) {
        view.scroll = scroll
        view.canPan = canPan
        view.pan = pan
    }

    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.removeMonitor() }

    final class Surface: NSView {
        var scroll: ((CGFloat, CGPoint) -> Bool)?
        var canPan: ((CGPoint) -> Bool)?
        var pan: ((CGSize, CGPoint?) -> Void)?
        private var dragPosition: CGPoint?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            let events: NSEvent.EventTypeMask = [.scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
            monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .otherMouseUp, event.buttonNumber == 2, dragPosition != nil {
                dragPosition = nil
                return nil
            }
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
            let location = convert(event.locationInWindow, from: nil)
            let inside = visibleRect.contains(location)

            switch event.type {
            case .scrollWheel:
                guard inside, event.scrollingDeltaY != 0,
                      abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return event }
                if dragPosition != nil { return nil }
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.025 : 0.18
                return scroll?(event.scrollingDeltaY * sensitivity, location) == true ? nil : event
            case .otherMouseDown:
                guard event.buttonNumber == 2, inside, canPan?(location) == true else { return event }
                dragPosition = location
                return nil
            case .otherMouseDragged:
                guard event.buttonNumber == 2, let previous = dragPosition else { return event }
                let movement = CGSize(width: location.x - previous.x, height: location.y - previous.y)
                dragPosition = location
                pan?(movement, inside ? location : nil)
                return nil
            default:
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            dragPosition = nil
        }
    }
}

struct FittedPicture: View {
    @StateObject private var picture: PreviewBitmap
    let pixelSize: CGSize

    init(reference: ReferenceImage) {
        pixelSize = CGSize(width: reference.width, height: reference.height)
        _picture = StateObject(wrappedValue: PreviewBitmap(reference))
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / pixelSize.width, proxy.size.height / pixelSize.height)
            Image(nsImage: picture.image)
                .resizable()
                .frame(width: pixelSize.width * scale, height: pixelSize.height * scale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

private final class PreviewBitmap: ObservableObject {
    let image: NSImage

    init(_ reference: ReferenceImage) {
        if let source = CGImageSourceCreateWithURL(reference.url as CFURL, nil),
           let rendered = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 2048,
           ] as CFDictionary) {
            image = NSImage(cgImage: rendered, size: .zero)
        } else {
            image = reference.thumbnail
        }
    }
}

struct DraggableReference: NSViewRepresentable {
    let reference: ReferenceImage
    let index: Int
    let canDrag: Bool
    let actionLabel: String
    let activate: () -> Void

    func makeNSView(context: Context) -> ReferenceImageView {
        let view = ReferenceImageView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: ReferenceImageView, context: Context) {
        view.image = reference.thumbnail
        view.pixelSize = CGSize(width: reference.width, height: reference.height)
        view.needsDisplay = true
        view.token = canDrag ? " @image \(index) " : nil
        view.activate = activate
        view.setAccessibilityLabel(actionLabel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReferenceImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 76, height: 76))
    }

    final class ReferenceImageView: NSView, NSDraggingSource {
        var image: NSImage?
        var pixelSize: CGSize = .zero
        var activate: (() -> Void)?
        var token: String?
        private var startPoint: NSPoint?
        private var beganDrag = false

        override var isFlipped: Bool { true }

        private var imageRect: CGRect {
            let available = bounds.insetBy(dx: 3, dy: 3)
            guard !available.isEmpty, pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
            let scale = min(available.width / pixelSize.width, available.height / pixelSize.height)
            let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
            return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                          width: size.width, height: size.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let image, !imageRect.isEmpty else { return }
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startPoint = event.locationInWindow
            beganDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !beganDrag, let startPoint, let image, let token else { return }
            let point = event.locationInWindow
            guard hypot(point.x - startPoint.x, point.y - startPoint.y) >= 3 else { return }
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(token, forType: .string)
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            item.setDraggingFrame(imageRect, contents: image)
            beganDrag = true
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            if !beganDrag && bounds.contains(location) { activate?() }
            startPoint = nil
        }

        override func accessibilityPerformPress() -> Bool {
            guard let activate else { return false }
            activate()
            return true
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    }
}

struct PromptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let edit = DropPromptView(frame: .zero)
        edit.isRichText = false
        edit.allowsUndo = true
        edit.font = .systemFont(ofSize: NSFont.systemFontSize)
        edit.textContainerInset = NSSize(width: 6, height: 7)
        edit.drawsBackground = false
        edit.isVerticallyResizable = true
        edit.isHorizontallyResizable = false
        edit.autoresizingMask = [.width]
        edit.textContainer?.widthTracksTextView = true
        edit.delegate = context.coordinator
        edit.registerForDraggedTypes([.string])
        edit.setAccessibilityLabel("提示词")
        scroll.documentView = edit
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let edit = scroll.documentView as? NSTextView, edit.string != text else { return }
        edit.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        init(_ parent: PromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }

    final class DropPromptView: NSTextView {
        private static let translatedItems = [
            "Undo": "撤销", "Redo": "重做", "Undo Typing": "撤销输入", "Redo Typing": "重做输入",
            "Cut": "剪切", "Copy": "复制", "Paste": "粘贴", "Paste and Match Style": "粘贴并匹配样式",
            "Delete": "删除", "Select All": "全选", "Search with Google": "使用 Google 搜索",
            "Translate": "翻译", "Writing Tools": "写作工具", "Services": "服务", "AutoFill": "自动填充",
            "Spelling and Grammar": "拼写和语法", "Show Spelling and Grammar": "显示拼写和语法",
            "Check Document Now": "立即检查文稿", "Check Spelling While Typing": "键入时检查拼写",
            "Check Grammar With Spelling": "同时检查语法和拼写", "Correct Spelling Automatically": "自动纠正拼写",
            "Substitutions": "替换", "Show Substitutions": "显示替换", "Smart Quotes": "智能引号",
            "Smart Dashes": "智能破折号", "Smart Links": "智能链接", "Text Replacement": "文本替换",
            "Transformations": "转换", "Make Upper Case": "转换为大写", "Make Lower Case": "转换为小写",
            "Capitalize": "首字母大写", "Speech": "朗读", "Start Speaking": "开始朗读", "Stop Speaking": "停止朗读",
            "Layout Orientation": "排版方向", "Horizontal": "横排", "Vertical": "竖排",
            "Font": "字体", "Show Fonts": "显示字体", "Ignore Spelling": "忽略拼写", "Learn Spelling": "学习拼写",
        ]

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let menu = super.menu(for: event) else { return nil }
            translate(menu)
            return menu
        }

        private func translate(_ menu: NSMenu) {
            for item in menu.items {
                let title = item.title
                if let translated = Self.translatedItems[title] {
                    item.title = translated
                } else if title.hasPrefix("Look Up ") {
                    item.title = "查询 " + title.dropFirst("Look Up ".count)
                }
                if let submenu = item.submenu { translate(submenu) }
            }
        }

        private func token(from sender: NSDraggingInfo) -> String? {
            guard let value = sender.draggingPasteboard.string(forType: .string),
                  value.range(of: #"^\s*@image [1-9][0-9]*\s*$"#, options: .regularExpression) != nil else { return nil }
            return value
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            token(from: sender) == nil ? super.draggingEntered(sender) : .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            token(from: sender) == nil ? super.draggingUpdated(sender) : .copy
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            token(from: sender) != nil || super.prepareForDragOperation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let token = token(from: sender) else { return super.performDragOperation(sender) }
            let point = convert(sender.draggingLocation, from: nil)
            let location = min((string as NSString).length, characterIndexForInsertion(at: point))
            let range = NSRange(location: location, length: 0)
            window?.makeFirstResponder(self)
            insertText(token, replacementRange: range)
            return true
        }
    }
}
