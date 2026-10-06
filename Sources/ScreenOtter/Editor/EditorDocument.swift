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
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { styleEditTarget = nil } }
    }
    /// The style new annotations get. Changing it with a selection restyles that annotation too.
    /// It starts as the last used style and is saved back on every change.
    @Published private(set) var style: AnnotationStyle {
        didSet { if style != oldValue { style.rememberAsDefault(in: styleDefaults) } }
    }
    @Published private(set) var isDirty = false
    /// Display zoom relative to the image's point size, reported by the canvas.
    @Published var zoom: CGFloat = 1

    @Published var tool: EditorTool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            endTextEditing()
            if oldValue == .crop { applyCrop() }
            if tool == .crop { pendingCrop = crop }
            // The text and redaction tools keep a selection of their own kind, so it can be restyled
            // (or resized) without switching tools.
            if let selected = selectedAnnotation, !tool.keepsSelection(of: selected.kind) { selectedID = nil }
        }
    }

    /// The text annotation being typed into, if any. Its edits are one undo step, taken when it ends.
    @Published private(set) var editingTextID: UUID?
    /// The annotations as they were when the text edit began.
    private var textEditBaseline: [Annotation]?

    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect
        var windowFrame: WindowFrame?
    }

    /// The annotation whose live style edit (color panel drag) already has an undo step.
    private var styleEditTarget: UUID?
    private let styleDefaults: UserDefaults

    @Published private var undoStack: [Snapshot] = []
    @Published private var redoStack: [Snapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    /// Draws the redactions from this screenshot and keeps their results while the editor is open.
    private(set) var redactions: RedactionRenderer
    /// Draws the dim and blur around the spotlights, and keeps their mask while the editor is open.
    private(set) var spotlights: SpotlightRenderer

    /// - Parameter defaults: where the last used style is read from and saved to (a suite in tests).
    init(capture: CapturedImage, fileURL: URL?, defaults: UserDefaults = .standard) {
        image = capture.image
        scale = capture.scale
        windowShot = capture.window?.shot
        windowFrame = capture.window?.frame
        composedFrame = capture.window?.frame
        self.fileURL = fileURL
        styleDefaults = defaults
        style = .lastUsed(in: defaults)
        crop = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
        redactions = RedactionRenderer(image: capture.image)
        spotlights = SpotlightRenderer(image: capture.image, scale: capture.scale)
    }

    // MARK: - Editing

    /// Call before every change so it can be undone.
    func checkpoint() {
        checkpoint(annotations: annotations)
    }

    private func checkpoint(annotations before: [Annotation]) {
        styleEditTarget = nil
        undoStack.append(Snapshot(annotations: before, crop: crop, windowFrame: composedFrame))
        redoStack.removeAll()
        isDirty = true
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    var selectedAnnotation: Annotation? {
        selectedID.flatMap { id in annotations.first { $0.id == id } }
    }

    /// What the style picker shows: the selected annotation's style, otherwise the style for new ones.
    var displayedStyle: AnnotationStyle { selectedAnnotation?.style ?? style }

    /// Whether the style picker is styling text (a selected label, or the text tool with nothing
    /// selected), so it offers fonts and label styles and reads weights as sizes.
    var isStylingText: Bool { selectedAnnotation.map { $0.kind == .text } ?? (tool == .text) }

    /// Whether the style picker is styling a redaction (a selected one, or the tool with nothing
    /// selected), so it offers blur and pixelate instead of colors and weights.
    var isStylingRedaction: Bool { selectedAnnotation.map { $0.kind == .redact } ?? (tool == .redact) }

    /// Picks blur or pixelate, for new redactions and the selected one.
    func pickRedaction(_ mode: RedactionMode) {
        updateStyle { $0.redaction = mode }
    }

    /// Whether the style picker is styling the highlighter (a selected stroke, or the tool with nothing
    /// selected), so it offers marker tints and reads weights as marker heights.
    var isStylingHighlight: Bool { selectedAnnotation.map { $0.kind == .highlight } ?? (tool == .highlight) }

    /// Whether the style picker is styling spotlights (a selected one, or the tool with nothing
    /// selected), so it offers dim and blur instead of colors and weights.
    var isStylingSpotlight: Bool { selectedAnnotation.map { $0.kind == .spotlight } ?? (tool == .spotlight) }

    /// The color the style picker shows and changes: the highlighter has its own ink.
    var displayedColor: StyleColor { isStylingHighlight ? displayedStyle.marker : displayedStyle.color }

    /// The weight the style picker shows and changes: the highlighter has its own height.
    var displayedWeight: StrokeWeight { isStylingHighlight ? displayedStyle.markerWeight : displayedStyle.weight }

    /// The swatches the style picker and the number keys offer: marker tints for the highlighter.
    var palette: [AnnotationPalette.Swatch] { isStylingHighlight ? HighlighterPalette.swatches : AnnotationPalette.swatches }

    /// Picks a color for what the style picker is styling: marker ink for the highlighter (lifted until
    /// text stays readable under it), the shared color for everything else.
    func pickColor(_ color: StyleColor, coalescing: Bool = false) {
        if isStylingHighlight {
            let ink = HighlighterPalette.ink(color)
            updateStyle(coalescing: coalescing) { $0.marker = ink }
        } else {
            updateStyle(coalescing: coalescing) { $0.color = color }
        }
    }

    /// Picks dim or blur for new spotlights and every existing one, in one undo step: they share one
    /// overlay, so a mix would have no single look. `style.spotlight` always matches the spotlights in the
    /// document (undo and redo sync it back), so new ones join the overlay as it looks.
    func pickSpotlight(_ mode: SpotlightMode) {
        style.spotlight = mode
        guard annotations.contains(where: { $0.kind == .spotlight && $0.style.spotlight != mode }) else { return }
        checkpoint()
        for index in annotations.indices where annotations[index].kind == .spotlight {
            annotations[index].style.spotlight = mode
        }
    }

    /// Changes the style for new annotations and, when one is selected, that annotation (undoably).
    /// Only the parts `change` touches are applied, so picking a color keeps the selection's own weight.
    /// - Parameters:
    ///   - coalescing: live edits (dragging in the color panel) share one undo step per annotation.
    ///   - resettingTextSize: a weight was picked, so a resized label goes back to that weight's size,
    ///     even when the weight is the one it already has.
    func updateStyle(coalescing: Bool = false, resettingTextSize: Bool = false, _ change: (inout AnnotationStyle) -> Void) {
        change(&style)
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var restyled = annotations[index].style
        change(&restyled)
        let resetsSize = annotations[index].fontSize != nil
            && (resettingTextSize || restyled.weight != annotations[index].style.weight)
        guard restyled != annotations[index].style || resetsSize else { return }
        // A label being typed is restyled inside its edit's undo step.
        if id != editingTextID, !(coalescing && styleEditTarget == id) {
            checkpoint()
            if coalescing { styleEditTarget = id }
        }
        annotations[index].style = restyled
        if resetsSize { annotations[index].fontSize = nil }
    }

    /// Picks a stroke weight (for text, a size preset; for the highlighter, its own height).
    func pickWeight(_ weight: StrokeWeight) {
        if isStylingHighlight {
            updateStyle { $0.markerWeight = weight }
        } else {
            updateStyle(resettingTextSize: true) { $0.weight = weight }
        }
    }

    /// Ends a run of coalesced style edits, so the next one gets its own undo step.
    func endStyleCoalescing() {
        styleEditTarget = nil
    }

    func deleteSelected() {
        guard editingTextID == nil, let id = selectedID else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func undo() {
        endTextEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        endTextEditing()
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
            setImage(framed)
            composedFrame = frame
        }
        windowFrame = composedFrame
        annotations = snapshot.annotations
        crop = snapshot.crop
        // The spotlights share one mode, which the restored ones may not have had: keep new ones in step.
        if let spotlight = annotations.last(where: { $0.kind == .spotlight }) { style.spotlight = spotlight.style.spotlight }
        selectedID = nil
        if tool == .crop { pendingCrop = crop }
        isDirty = true
    }

    // MARK: - Text

    /// Places an empty label at `origin` (its first line's cap top) and starts typing into it.
    @discardableResult
    func beginNewText(at origin: CGPoint) -> UUID {
        endTextEditing()
        let annotation = Annotation(kind: .text, start: origin, end: origin, style: style, scale: scale)
        textEditBaseline = annotations
        annotations.append(annotation)
        selectedID = annotation.id
        editingTextID = annotation.id
        return annotation.id
    }

    /// Starts typing into an existing label (double-click, or Return with it selected).
    func beginEditingText(_ id: UUID) {
        guard editingTextID != id, annotations.contains(where: { $0.id == id && $0.kind == .text }) else { return }
        endTextEditing()
        textEditBaseline = annotations
        selectedID = id
        editingTextID = id
    }

    /// The live text of the label being edited.
    func setEditingText(_ text: String) {
        guard let id = editingTextID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        // Pasted text may bring other line endings; labels break lines on \n only.
        annotations[index].text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    /// Commits the label being edited: an empty one disappears, a changed one becomes one undo step,
    /// and it stays selected so it can be restyled, moved or resized right away.
    func endTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        let baseline = textEditBaseline ?? annotations
        textEditBaseline = nil
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            if annotations[index].isDegenerate {
                annotations.remove(at: index)
                if selectedID == id { selectedID = nil }
            } else {
                // Only the end is trimmed: the label is anchored at its first line, so dropping leading
                // spaces or blank lines would move the text away from where it was typed.
                annotations[index].text = annotations[index].text.trimmingTrailingWhitespace
            }
        }
        guard annotations != baseline else { return }
        checkpoint(annotations: baseline)
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
    /// stay smooth. Call `checkpoint()` first, once per gesture. The minimal title bar and its color are
    /// remembered for the next window shots.
    func setWindowFrame(_ frame: WindowFrame) {
        guard windowShot != nil, frame != windowFrame else { return }
        windowFrame = frame
        let prefs = Preferences.shared
        if prefs.windowMinimalTitleBar != frame.minimalTitleBar { prefs.windowMinimalTitleBar = frame.minimalTitleBar }
        if prefs.windowBarColor != frame.barColor { prefs.windowBarColor = frame.barColor }
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

    /// A new picture to draw on: redactions and spotlights are worked out from it, so they start over too.
    private func setImage(_ framed: CGImage) {
        image = framed
        redactions = RedactionRenderer(image: framed)
        spotlights = SpotlightRenderer(image: framed, scale: scale)
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
        setImage(framed)
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
        AnnotationRenderer.drawAll(annotations, redactions: redactions, spotlights: spotlights, visible: crop, in: ctx, unit: 1)
        return ctx.makeImage()
    }

    func copyToClipboard() {
        endTextEditing()
        if let rendered = render() {
            CaptureOutput.copy(rendered, scale: scale)
        }
    }

    /// Writes the edits back to the screenshot file and the clipboard.
    func commit() {
        endTextEditing()
        guard let rendered = render() else { return }
        CaptureOutput.copy(rendered, scale: scale)
        if let fileURL {
            try? CaptureOutput.write(rendered, scale: scale, to: fileURL)
        }
        isDirty = false
    }

    func save(to url: URL) throws {
        endTextEditing()
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

extension String {
    /// The string without trailing spaces, tabs and newlines.
    nonisolated var trimmingTrailingWhitespace: String {
        var scalars = unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }
}
