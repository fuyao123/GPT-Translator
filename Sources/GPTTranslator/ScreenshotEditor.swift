import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum ScreenshotEditorTool: String, CaseIterable, Identifiable {
    case pen
    case rectangle
    case ellipse
    case arrow
    case mosaic
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "画笔"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .mosaic: return "square.grid.3x3.topleft.filled"
        case .text: return "textformat"
        }
    }
}

enum ScreenshotAnnotationColor: String, CaseIterable, Identifiable {
    case red
    case yellow
    case blue
    case green

    var id: String { rawValue }

    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .blue: return .blue
        case .green: return .green
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .blue: return .systemBlue
        case .green: return .systemGreen
        }
    }
}

struct ScreenshotAnnotation: Identifiable {
    let id: UUID
    let tool: ScreenshotEditorTool
    let points: [CGPoint]
    let rect: CGRect
    let color: ScreenshotAnnotationColor
    let lineWidth: CGFloat
    let text: String
    let fontSize: CGFloat

    init(
        id: UUID = UUID(),
        tool: ScreenshotEditorTool,
        points: [CGPoint] = [],
        rect: CGRect = .zero,
        color: ScreenshotAnnotationColor,
        lineWidth: CGFloat,
        text: String = "",
        fontSize: CGFloat = 32
    ) {
        self.id = id
        self.tool = tool
        self.points = points
        self.rect = rect
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
    }
}

@MainActor
final class ScreenshotEditorModel: ObservableObject {
    let image: CGImage

    @Published var selectedTool: ScreenshotEditorTool = .pen
    @Published var selectedColor: ScreenshotAnnotationColor = .red
    @Published var lineWidth: CGFloat = 8
    @Published private(set) var annotations: [ScreenshotAnnotation] = []
    @Published var ocrText = ""
    @Published var ocrStatus = ""
    @Published private(set) var isOCRRunning = false
    @Published var isPinned = false

    init(image: CGImage) {
        self.image = image
    }

    func replaceAnnotations(_ annotations: [ScreenshotAnnotation]) {
        self.annotations = annotations
    }

    func undoLastAnnotation() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    func clearAnnotations() {
        annotations.removeAll()
    }

    func addTextAnnotation(at point: CGPoint, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        annotations.append(
            ScreenshotAnnotation(
                tool: .text,
                points: [point],
                color: selectedColor,
                lineWidth: lineWidth,
                text: trimmedText,
                fontSize: max(24, lineWidth * 4)
            )
        )
    }

    func renderedImage() -> CGImage? {
        ScreenshotImageRenderer.render(image: image, annotations: annotations)
    }

    func recognizeOCR() {
        guard !isOCRRunning else { return }
        isOCRRunning = true
        ocrStatus = "正在识别文字…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isOCRRunning = false }
            do {
                let text = try ScreenshotOCRService.recognizeText(in: self.image) ?? ""
                self.ocrText = text
                self.ocrStatus = text.isEmpty ? "没有识别到文字" : "OCR 完成"
            } catch {
                self.ocrText = ""
                self.ocrStatus = "OCR 失败：\(error.localizedDescription)"
            }
        }
    }
}

enum ScreenshotOCRService {
    static func recognizeText(in image: CGImage) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP", "ko-KR", "es-ES", "fr-FR", "de-DE"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

@MainActor
final class ScreenshotTranslationResultModel: ObservableObject {
    @Published private(set) var translatedText = ""
    @Published private(set) var status = "正在进行 OCR 翻译…"
    @Published private(set) var isTranslating = false

    func translate(_ text: String, using viewModel: TranslationViewModel) {
        guard !isTranslating else { return }
        translatedText = ""
        status = "正在使用 \(viewModel.provider.displayName) 翻译…"
        isTranslating = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTranslating = false }
            do {
                let result = try await viewModel.translateWithDefaultFallback(text)
                self.translatedText = result.text
                self.status = result.sourceName
            } catch {
                self.status = "翻译失败：\(error.localizedDescription)"
            }
        }
    }
}

struct ScreenshotTranslationResultView: View {
    @ObservedObject var model: ScreenshotTranslationResultModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("OCR 翻译")
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isTranslating {
                    ProgressView().controlSize(.small)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭翻译结果")
            }

            ScrollView {
                Text(model.translatedText.isEmpty ? (model.isTranslating ? "正在识别并翻译…" : model.status) : model.translatedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack {
                Spacer()
                Button("复制译文") {
                    guard !model.translatedText.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.translatedText, forType: .string)
                }
                .disabled(model.translatedText.isEmpty)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.12))
        }
    }
}

enum ScreenshotImageRenderer {
    private static let ciContext = CIContext(options: nil)
    private static let fullMosaicCacheID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func render(image: CGImage, annotations: [ScreenshotAnnotation]) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        var mosaicCache: [UUID: CGImage] = [:]
        draw(
            image: image,
            annotations: annotations,
            in: context,
            targetRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            mosaicCache: &mosaicCache
        )
        return context.makeImage()
    }

    static func draw(
        image: CGImage,
        annotations: [ScreenshotAnnotation],
        in context: CGContext,
        targetRect: CGRect,
        mosaicCache: inout [UUID: CGImage]
    ) {
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: targetRect)
        context.restoreGState()

        let scaleX = targetRect.width / CGFloat(image.width)
        let scaleY = targetRect.height / CGFloat(image.height)
        guard scaleX > 0, scaleY > 0 else { return }

        context.saveGState()
        context.translateBy(x: targetRect.minX, y: targetRect.minY)
        context.scaleBy(x: scaleX, y: scaleY)
        for annotation in annotations {
            draw(annotation: annotation, image: image, in: context, mosaicCache: &mosaicCache)
        }
        context.restoreGState()
    }

    private static func draw(
        annotation: ScreenshotAnnotation,
        image: CGImage,
        in context: CGContext,
        mosaicCache: inout [UUID: CGImage]
    ) {
        let color = (annotation.color.nsColor.usingColorSpace(.deviceRGB) ?? annotation.color.nsColor).cgColor
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .pen:
            drawPen(points: annotation.points, in: context)
        case .rectangle:
            context.stroke(annotation.rect.standardized)
        case .ellipse:
            context.strokeEllipse(in: annotation.rect.standardized)
        case .arrow:
            drawArrow(points: annotation.points, in: context, lineWidth: annotation.lineWidth)
        case .mosaic:
            guard let first = annotation.points.first else { return }
            if let mosaic = mosaicCache[fullMosaicCacheID] ?? pixelatedImage(from: image) {
                mosaicCache[fullMosaicCacheID] = mosaic
                context.saveGState()
                context.beginPath()
                if annotation.points.count == 1 {
                    context.addEllipse(in: CGRect(
                        x: first.x - annotation.lineWidth / 2,
                        y: first.y - annotation.lineWidth / 2,
                        width: annotation.lineWidth,
                        height: annotation.lineWidth
                    ))
                } else {
                    context.move(to: first)
                    for point in annotation.points.dropFirst() {
                        context.addLine(to: point)
                    }
                    context.setLineWidth(annotation.lineWidth)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    context.replacePathWithStrokedPath()
                }
                context.clip()
                context.draw(mosaic, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
                context.restoreGState()
            }
        case .text:
            guard let point = annotation.points.first else { return }
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            (annotation.text as NSString).draw(
                at: point,
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .medium),
                    .foregroundColor: annotation.color.nsColor
                ]
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawPen(points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            context.fillEllipse(in: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4))
            return
        }
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    private static func drawArrow(points: [CGPoint], in context: CGContext, lineWidth: CGFloat) {
        guard let start = points.first, let end = points.last else { return }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }

        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(dy, dx)
        let headLength = max(14, lineWidth * 3.5)
        let headAngle = CGFloat.pi / 7
        let first = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let second = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        context.beginPath()
        context.move(to: first)
        context.addLine(to: end)
        context.addLine(to: second)
        context.strokePath()
    }

    private static func pixelatedImage(from image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: 16), forKey: kCIInputScaleKey)
        filter.setValue(
            CIVector(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2),
            forKey: kCIInputCenterKey
        )
        guard let output = filter.outputImage else { return image }
        return ciContext.createCGImage(output, from: input.extent) ?? image
    }
}

@MainActor
final class ScreenshotCanvasView: NSView {
    let image: CGImage
    let canvasInset: CGFloat
    var annotations: [ScreenshotAnnotation] = [] {
        didSet { needsDisplay = true }
    }
    var selectedTool: ScreenshotEditorTool = .pen {
        didSet { needsDisplay = true }
    }
    var selectedColor: ScreenshotAnnotationColor = .red {
        didSet { needsDisplay = true }
    }
    var lineWidth: CGFloat = 8 {
        didSet { needsDisplay = true }
    }
    var onAnnotationsChanged: (([ScreenshotAnnotation]) -> Void)?
    var onTextAnnotationRequested: ((CGPoint) -> Void)?

    private var activeStart: CGPoint?
    private var activePoints: [CGPoint] = []
    private var activeAnnotationID = UUID()
    private var mosaicCache: [UUID: CGImage] = [:]

    init(image: CGImage, canvasInset: CGFloat = 16) {
        self.image = image
        self.canvasInset = canvasInset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let imageRect = fittedImageRect()
        ScreenshotImageRenderer.draw(
            image: image,
            annotations: annotations + activeAnnotations,
            in: context,
            targetRect: imageRect,
            mosaicCache: &mosaicCache
        )

        NSColor.white.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(rect: imageRect)
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = imagePoint(for: convert(event.locationInWindow, from: nil), clamp: false) else { return }
        if selectedTool == .text {
            onTextAnnotationRequested?(point)
            return
        }
        activeStart = point
        activePoints = [point]
        activeAnnotationID = UUID()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeStart != nil,
              let point = imagePoint(for: convert(event.locationInWindow, from: nil), clamp: true) else { return }
        if selectedTool == .pen || selectedTool == .mosaic {
            activePoints.append(point)
        } else {
            activePoints = [activePoints.first ?? point, point]
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = activeStart,
              let point = imagePoint(for: convert(event.locationInWindow, from: nil), clamp: true) else {
            resetActiveStroke()
            return
        }
        if selectedTool != .pen && selectedTool != .mosaic {
            activePoints = [start, point]
        }
        guard let annotation = makeActiveAnnotation(), annotationHasVisibleContent(annotation) else {
            resetActiveStroke()
            return
        }

        annotations.append(annotation)
        onAnnotationsChanged?(annotations)
        resetActiveStroke()
    }

    private var activeAnnotations: [ScreenshotAnnotation] {
        guard activeStart != nil, let annotation = makeActiveAnnotation() else { return [] }
        return [annotation]
    }

    private func makeActiveAnnotation() -> ScreenshotAnnotation? {
        guard !activePoints.isEmpty else { return nil }
        if selectedTool == .pen || selectedTool == .mosaic {
            return ScreenshotAnnotation(
                id: activeAnnotationID,
                tool: selectedTool,
                points: activePoints,
                color: selectedColor,
                lineWidth: lineWidth
            )
        }
        guard let first = activePoints.first, let last = activePoints.last else { return nil }
        let rect = CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
        return ScreenshotAnnotation(
            tool: selectedTool,
            points: selectedTool == .arrow ? [first, last] : [],
            rect: rect,
            color: selectedColor,
            lineWidth: lineWidth
        )
    }

    private func annotationHasVisibleContent(_ annotation: ScreenshotAnnotation) -> Bool {
        if annotation.tool == .pen || annotation.tool == .mosaic || annotation.tool == .arrow {
            guard let first = annotation.points.first, let last = annotation.points.last else { return false }
            return annotation.tool == .pen || annotation.tool == .mosaic || hypot(last.x - first.x, last.y - first.y) > 2
        }
        return annotation.rect.width > 2 && annotation.rect.height > 2
    }

    private func resetActiveStroke() {
        activeStart = nil
        activePoints.removeAll()
        needsDisplay = true
    }

    private func fittedImageRect() -> CGRect {
        let canvas = bounds.insetBy(dx: canvasInset, dy: canvasInset)
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: canvas.midX - size.width / 2,
            y: canvas.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func imagePoint(for viewPoint: CGPoint, clamp: Bool) -> CGPoint? {
        let rect = fittedImageRect()
        guard clamp || rect.contains(viewPoint) else { return nil }
        let x = min(max(viewPoint.x, rect.minX), rect.maxX)
        let y = min(max(viewPoint.y, rect.minY), rect.maxY)
        return CGPoint(
            x: (x - rect.minX) / rect.width * CGFloat(image.width),
            y: (y - rect.minY) / rect.height * CGFloat(image.height)
        )
    }
}

struct ScreenshotCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var model: ScreenshotEditorModel
    let canvasInset: CGFloat

    init(model: ScreenshotEditorModel, canvasInset: CGFloat = 16) {
        self.model = model
        self.canvasInset = canvasInset
    }

    func makeNSView(context: Context) -> ScreenshotCanvasView {
        let view = ScreenshotCanvasView(image: model.image, canvasInset: canvasInset)
        view.annotations = model.annotations
        view.selectedTool = model.selectedTool
        view.selectedColor = model.selectedColor
        view.lineWidth = model.lineWidth
        view.onAnnotationsChanged = { [weak model] annotations in
            model?.replaceAnnotations(annotations)
        }
        view.onTextAnnotationRequested = { [weak model] point in
            guard let model else { return }
            let alert = NSAlert()
            alert.messageText = "添加文字标注"
            alert.informativeText = "输入后将文字放置在截图中。"
            let field = NSTextField(string: "")
            field.placeholderString = "输入标注文字"
            field.frame.size = NSSize(width: 300, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "添加")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            alert.window.makeFirstResponder(field)
            if alert.runModal() == .alertFirstButtonReturn {
                model.addTextAnnotation(at: point, text: field.stringValue)
            }
        }
        return view
    }

    func updateNSView(_ nsView: ScreenshotCanvasView, context: Context) {
        nsView.annotations = model.annotations
        nsView.selectedTool = model.selectedTool
        nsView.selectedColor = model.selectedColor
        nsView.lineWidth = model.lineWidth
        nsView.needsDisplay = true
    }
}

struct CompactScreenshotEditorView: View {
    @StateObject private var model: ScreenshotEditorModel
    @State private var showingOCR = false

    let displaySize: NSSize
    let panelWidth: CGFloat
    let toolbarBelow: Bool
    let onCancel: () -> Void
    let onOCRTranslate: (CGImage) -> Void
    let onPin: (CGImage) -> Void

    init(
        image: CGImage,
        displaySize: NSSize,
        panelWidth: CGFloat,
        toolbarBelow: Bool,
        onCancel: @escaping () -> Void,
        onOCRTranslate: @escaping (CGImage) -> Void,
        onPin: @escaping (CGImage) -> Void
    ) {
        _model = StateObject(wrappedValue: ScreenshotEditorModel(image: image))
        self.displaySize = displaySize
        self.panelWidth = panelWidth
        self.toolbarBelow = toolbarBelow
        self.onCancel = onCancel
        self.onOCRTranslate = onOCRTranslate
        self.onPin = onPin
    }

    var body: some View {
        VStack(spacing: 6) {
            if toolbarBelow {
                screenshotCanvas
                toolArea
            } else {
                toolArea
                screenshotCanvas
            }
        }
        .frame(width: panelWidth)
        .background(Color.clear)
        .onExitCommand(perform: onCancel)
    }

    private var screenshotCanvas: some View {
        ScreenshotCanvasRepresentable(model: model, canvasInset: 0)
            .frame(width: displaySize.width, height: displaySize.height)
            .background(Color.black)
            .overlay {
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
            .overlay(alignment: .topLeading) {
                Text("\(Int(displaySize.width.rounded())) × \(Int(displaySize.height.rounded()))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
    }

    private var toolArea: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(ScreenshotEditorTool.allCases) { tool in
                    compactButton(tool.systemImage, help: tool.title, selected: model.selectedTool == tool) {
                        model.selectedTool = tool
                        if tool == .mosaic, model.lineWidth < 20 {
                            model.lineWidth = 36
                        } else if tool == .pen, model.lineWidth > 30 {
                            model.lineWidth = 8
                        }
                    }
                }

                divider

                Button {
                    showingOCR = true
                    model.recognizeOCR()
                } label: {
                    Image(systemName: "text.viewfinder")
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(model.isOCRRunning)
                .help("OCR 文字识别")
                .popover(isPresented: $showingOCR, arrowEdge: toolbarBelow ? .top : .bottom) {
                    ocrPopover
                }

                Button {
                    onOCRTranslate(model.image)
                } label: {
                    Text("译")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.plain)
                .help("OCR 识别并直接翻译")

                divider

                compactButton("arrow.uturn.backward", help: "撤销") {
                    model.undoLastAnnotation()
                }
                .disabled(model.annotations.isEmpty)

                compactButton("pin", help: "钉住截图") {
                    guard let image = model.renderedImage() else { return }
                    onPin(image)
                }

                compactButton("square.and.arrow.down", help: "保存截图") {
                    saveScreenshot()
                }

                compactButton("xmark", help: "取消") {
                    onCancel()
                }

                compactButton("checkmark", help: "完成并复制") {
                    copyScreenshotAndClose()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.black.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.24), radius: 8, y: 3)

            HStack(spacing: 10) {
                ForEach(ScreenshotAnnotationColor.allCases) { color in
                    Button {
                        model.selectedColor = color
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 14, height: 14)
                            .overlay {
                                Circle()
                                    .stroke(
                                        model.selectedColor == color ? Color.primary : Color.clear,
                                        lineWidth: 2
                                    )
                                    .padding(-3)
                            }
                    }
                    .buttonStyle(.plain)
                }

                divider

                Image(systemName: model.selectedTool == .mosaic ? "square.grid.3x3.fill" : "pencil.tip")
                    .foregroundStyle(.secondary)
                Slider(
                    value: $model.lineWidth,
                    in: model.selectedTool == .mosaic ? 16...100 : 2...30,
                    step: 1
                )
                .frame(width: 120)
                .help("笔触粗细：\(Int(model.lineWidth))")
                Text("\(Int(model.lineWidth))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.1))
            }
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .frame(height: 92, alignment: toolbarBelow ? .top : .bottom)
    }

    private var divider: some View {
        Divider()
            .frame(height: 22)
            .padding(.horizontal, 2)
    }

    private func compactButton(
        _ systemImage: String,
        help: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 30, height: 28)
                .background(
                    selected ? Color.accentColor.opacity(0.2) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var ocrPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OCR 文字")
                    .font(.headline)
                Spacer()
                if model.isOCRRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.ocrText.isEmpty {
                Text(model.ocrStatus.isEmpty ? "正在识别…" : model.ocrStatus)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            } else {
                TextEditor(text: $model.ocrText)
                    .frame(width: 360, height: 130)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.22))
                    }
                HStack {
                    Text(model.ocrStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("复制文字") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.ocrText, forType: .string)
                        model.ocrStatus = "文字已复制"
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 390)
    }

    private func renderedPNGData() -> Data? {
        guard let image = model.renderedImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func copyScreenshotAndClose() {
        guard let data = renderedPNGData() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        onCancel()
    }

    private func saveScreenshot() {
        guard let data = renderedPNGData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "截图-\(Self.fileDateFormatter.string(from: Date())).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                model.ocrStatus = "已保存：\(url.lastPathComponent)"
            } catch {
                model.ocrStatus = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct PinnedScreenshotView: View {
    let image: CGImage
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        ))
        .resizable()
        .scaledToFit()
        .overlay {
            Rectangle()
                .stroke(Color.black.opacity(0.22), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.62))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("关闭钉住的截图")
            }
        }
        .onHover { hovering = $0 }
    }
}

struct ScreenshotEditorView: View {
    @StateObject private var model: ScreenshotEditorModel
    let onPinnedChanged: (Bool) -> Void

    init(image: CGImage, onPinnedChanged: @escaping (Bool) -> Void) {
        _model = StateObject(wrappedValue: ScreenshotEditorModel(image: image))
        self.onPinnedChanged = onPinnedChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            ScreenshotCanvasRepresentable(model: model)
                .frame(minWidth: 780, minHeight: 470)
                .background(Color(nsColor: .underPageBackgroundColor))

            Divider()
            ocrPanel
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ScreenshotEditorTool.allCases) { tool in
                    Button {
                        model.selectedTool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .frame(width: 30, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(
                        model.selectedTool == tool
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .help(tool.title)
                }
            }

            Divider()

            HStack(spacing: 5) {
                ForEach(ScreenshotAnnotationColor.allCases) { color in
                    Button {
                        model.selectedColor = color
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 16, height: 16)
                            .overlay {
                                Circle()
                                    .stroke(
                                        model.selectedColor == color ? Color.primary : Color.clear,
                                        lineWidth: 2
                                    )
                                    .padding(-3)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("颜色：\(color.rawValue)")
                }
            }

            Picker("笔触", selection: $model.lineWidth) {
                Text("细").tag(CGFloat(4))
                Text("中").tag(CGFloat(8))
                Text("粗").tag(CGFloat(14))
            }
            .frame(width: 66)
            .help("标注笔触粗细")

            Spacer(minLength: 8)

            Button {
                model.undoLastAnnotation()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(model.annotations.isEmpty)
            .help("撤销上一个标注")

            Button {
                model.clearAnnotations()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.annotations.isEmpty)
            .help("清除全部标注")

            Button {
                model.isPinned.toggle()
                onPinnedChanged(model.isPinned)
            } label: {
                Label("置顶", systemImage: model.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.isPinned ? Color.accentColor : Color.primary)
            .help(model.isPinned ? "取消置顶" : "置顶截图窗口")

            Button {
                model.recognizeOCR()
            } label: {
                Label("OCR", systemImage: "text.viewfinder")
            }
            .buttonStyle(.borderless)
            .disabled(model.isOCRRunning)
            .help("识别截图中的文字")

            Button {
                copyScreenshot()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制带标注的截图")

            Button {
                saveScreenshot()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("保存带标注的截图")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var ocrPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("OCR 文字", systemImage: "text.viewfinder")
                    .font(.subheadline.weight(.semibold))
                if model.isOCRRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if !model.ocrText.isEmpty {
                    Button("复制文字") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.ocrText, forType: .string)
                        model.ocrStatus = "文字已复制"
                    }
                    .buttonStyle(.borderless)
                }
                Text(model.ocrStatus.isEmpty ? "可识别截图中的中、英、日、韩及常见欧洲语言" : model.ocrStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if model.ocrText.isEmpty {
                Text("点击工具栏中的 OCR 开始识别")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextEditor(text: $model.ocrText)
                    .font(.body)
                    .frame(height: 82)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.22))
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func renderedPNGData() -> Data? {
        guard let image = model.renderedImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func copyScreenshot() {
        guard let data = renderedPNGData() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        model.ocrStatus = "截图已复制"
    }

    private func saveScreenshot() {
        guard let data = renderedPNGData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "截图-\(Self.fileDateFormatter.string(from: Date())).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                model.ocrStatus = "已保存：\(url.lastPathComponent)"
            } catch {
                model.ocrStatus = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

final class ScreenshotEditorPanel: NSPanel {
    var closeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        closeHandler?()
    }
}
