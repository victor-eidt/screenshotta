import AppKit

final class EditorDocument: ObservableObject {
    @Published private(set) var image: CGImage
    let scale: CGFloat
    /// Window screenshots: the window apart from its background, so it can be framed again.
    let windowShot: WindowShot?
    /// How the window is framed, as last set; `image` follows once it's composed.
    @Published private(set) var windowFrame: WindowFrame?
    /// The frame `image` was composed with. Annotations and the crop are placed on that image.
    private var composedFrame: WindowFrame?
    private var isComposing = false
    private var composeGeneration = 0

    @Published var fileURL: URL?
    @Published var annotations: [Annotation] = []
    /// The visible part of the image, in image pixels (top-left origin).
    @Published private(set) var crop: CGRect
    /// The crop being edited while the crop tool is active.
    @Published var pendingCrop: CGRect?
    @Published var selectedID: UUID?
    @Published var color: NSColor = AnnotationPalette.colors[0]
    @Published var stroke: StrokeSize = .medium
    @Published private(set) var isDirty = false
    /// Display zoom relative to the image's point size, reported by the canvas.
    @Published var zoom: CGFloat = 1

    @Published var tool: EditorTool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .crop { applyCrop() }
            if tool == .crop { pendingCrop = crop }
            if tool != .select { selectedID = nil }
        }
    }

    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect
        var windowFrame: WindowFrame?
    }

    @Published private var undoStack: [Snapshot] = []
    @Published private var redoStack: [Snapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    init(capture: CapturedImage, fileURL: URL?) {
        image = capture.image
        scale = capture.scale
        windowShot = capture.window?.shot
        windowFrame = capture.window?.frame
        composedFrame = capture.window?.frame
        self.fileURL = fileURL
        crop = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
    }

    // MARK: - Editing

    /// Call before every change so it can be undone.
    func checkpoint() {
        undoStack.append(snapshot)
        redoStack.removeAll()
        isDirty = true
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    /// With the frame of the image on screen, which is what the annotations and the crop are placed on.
    private var snapshot: Snapshot {
        Snapshot(annotations: annotations, crop: crop, windowFrame: composedFrame)
    }

    private func restore(_ snapshot: Snapshot) {
        // A frame still being composed is dropped: the image goes back to the one the snapshot was taken on.
        composeGeneration += 1
        if let frame = snapshot.windowFrame, frame != composedFrame, let shot = windowShot, let framed = shot.compose(frame) {
            image = framed
            composedFrame = frame
        }
        windowFrame = composedFrame
        annotations = snapshot.annotations
        crop = snapshot.crop
        selectedID = nil
        if tool == .crop { pendingCrop = crop }
        isDirty = true
    }

    func applyCrop() {
        guard let pending = pendingCrop?.integral.intersection(imageBounds),
              pending.width >= 4, pending.height >= 4, pending != crop
        else { return }
        checkpoint()
        crop = pending
        pendingCrop = tool == .crop ? pending : nil
    }

    func cancelCrop() {
        pendingCrop = crop
        tool = .arrow
    }

    // MARK: - Window frame

    /// Frames the window anew; the image follows as soon as it's composed, off the main thread so sliders
    /// stay smooth. Call `checkpoint()` first, once per gesture. The minimal title bar is remembered for
    /// the next window shots.
    func setWindowFrame(_ frame: WindowFrame) {
        guard windowShot != nil, frame != windowFrame else { return }
        windowFrame = frame
        if Preferences.shared.windowMinimalTitleBar != frame.minimalTitleBar {
            Preferences.shared.windowMinimalTitleBar = frame.minimalTitleBar
        }
        composeLatest()
    }

    private func composeLatest() {
        guard !isComposing, let shot = windowShot, let frame = windowFrame, frame != composedFrame else { return }
        isComposing = true
        let generation = composeGeneration
        Task {
            let framed = await Self.compose(shot, frame)
            isComposing = false
            if generation == composeGeneration {
                if let framed {
                    show(framed, framedAs: frame)
                } else if windowFrame == frame {
                    // Couldn't be drawn: the controls go back to what's shown rather than retrying.
                    windowFrame = composedFrame
                }
            }
            composeLatest()
        }
    }

    @concurrent
    private static func compose(_ shot: WindowShot, _ frame: WindowFrame) async -> CGImage? {
        shot.compose(frame)
    }

    /// Swaps in a newly framed image, moving the annotations and the crop with the window.
    private func show(_ framed: CGImage, framedAs frame: WindowFrame) {
        guard let shot = windowShot, let old = composedFrame else { return }
        let from = shot.contentOrigin(old), to = shot.contentOrigin(frame)
        let delta = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let wasWhole = crop == imageBounds
        image = framed
        composedFrame = frame
        for index in annotations.indices {
            annotations[index].translate(by: delta)
        }
        let moved = crop.offsetBy(dx: delta.x, dy: delta.y).intersection(imageBounds)
        crop = wasWhole || moved.width < 4 || moved.height < 4 ? imageBounds : moved
        if tool == .crop { pendingCrop = crop }
    }

    // MARK: - Output

    func render() -> CGImage? {
        let width = Int(crop.width)
        let height = Int(crop.height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: WindowStyler.rgbColorSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        AnnotationRenderer.drawImage(image, in: ctx)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, in: ctx, unit: 1)
        }
        return ctx.makeImage()
    }

    func copyToClipboard() {
        if let rendered = render() {
            CaptureOutput.copy(rendered, scale: scale)
        }
    }

    /// Writes the edits back to the screenshot file and the clipboard.
    func commit() {
        guard let rendered = render() else { return }
        CaptureOutput.copy(rendered, scale: scale)
        if let fileURL {
            try? CaptureOutput.write(rendered, scale: scale, to: fileURL)
        }
        isDirty = false
    }

    func save(to url: URL) throws {
        guard let rendered = render() else { throw CocoaError(.fileWriteUnknown) }
        try CaptureOutput.write(rendered, scale: scale, to: url)
    }

    func discardChanges() {
        isDirty = false
    }

    var fileSizeDescription: String? {
        guard let fileURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
