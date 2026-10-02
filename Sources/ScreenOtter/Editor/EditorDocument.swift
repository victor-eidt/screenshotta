import AppKit

final class EditorDocument: ObservableObject {
    let image: CGImage
    let scale: CGFloat

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
    }

    @Published private var undoStack: [Snapshot] = []
    @Published private var redoStack: [Snapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    init(capture: CapturedImage, fileURL: URL?) {
        image = capture.image
        scale = capture.scale
        self.fileURL = fileURL
        crop = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
    }

    // MARK: - Editing

    /// Call before every change so it can be undone.
    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
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
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
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
