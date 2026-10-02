import AppKit
import Carbon.HIToolbox
import Combine

final class EditorCanvasView: NSView, NSTextViewDelegate {
    private let doc: EditorDocument
    private var cancellable: AnyCancellable?

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    private enum Drag {
        case drawing(Annotation)
        case moving(id: UUID, last: CGPoint, didMove: Bool)
        /// The text tool pressed on a label: a drag moves it, a click edits it.
        case pressingText(id: UUID, start: CGPoint)
        /// The corner handle of a label: `anchor` is the plate corner that stays put.
        case resizingText(id: UUID, anchor: CGPoint, corner: CGPoint, original: CGFloat, didResize: Bool)
        case newCrop(anchor: CGPoint)
        case moveCrop(start: CGPoint, original: CGRect)
        case resizeCrop(edges: Edges, original: CGRect)
    }

    private var drag: Drag?

    /// The inline editor of the label being typed: it takes the keystrokes and draws the caret and the
    /// selection, while the canvas draws the glyphs, so what you type is exactly what gets exported.
    private var textView: NSTextView?
    private var textViewID: UUID?
    private var textUndoManager = UndoManager()

    init(document: EditorDocument) {
        doc = document
        super.init(frame: .zero)
        cancellable = document.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value changes; redraw on the next pass.
            Task { @MainActor in
                guard let self else { return }
                self.needsDisplay = true
                self.syncTextEditor()
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor in self.window?.makeFirstResponder(self) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncTextEditor()
    }

    // MARK: - Geometry

    /// While cropping the whole image is shown, so the crop can also grow back.
    private var region: CGRect { doc.tool == .crop ? doc.imageBounds : doc.crop }

    /// View points per image pixel, and where the region's origin sits in the view.
    private var layoutInfo: (k: CGFloat, origin: CGPoint) {
        let region = region
        let available = bounds.insetBy(dx: 32, dy: 28)
        let k = max(0.01, min(available.width / region.width, available.height / region.height, 1 / doc.scale))
        let size = CGSize(width: region.width * k, height: region.height * k)
        let origin = CGPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded())
        return (k, origin)
    }

    private func toImage(_ p: NSPoint) -> CGPoint {
        let (k, origin) = layoutInfo
        return CGPoint(x: region.minX + (p.x - origin.x) / k, y: region.minY + (p.y - origin.y) / k)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let (k, origin) = layoutInfo
        return CGPoint(x: origin.x + (p.x - region.minX) * k, y: origin.y + (p.y - region.minY) * k)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let (k, origin) = layoutInfo
        return CGRect(
            x: origin.x + (r.minX - region.minX) * k, y: origin.y + (r.minY - region.minY) * k,
            width: r.width * k, height: r.height * k
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.115, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let (k, origin) = layoutInfo
        let region = region
        let imageFrame = toView(region)
        reportZoom(k)

        // Soft drop shadow under the image.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(imageFrame)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: imageFrame)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        ctx.interpolationQuality = .high
        AnnotationRenderer.drawImage(doc.image, in: ctx)
        for annotation in doc.annotations {
            AnnotationRenderer.draw(annotation, in: ctx, unit: k)
        }
        if case let .drawing(draft) = drag {
            AnnotationRenderer.draw(draft, in: ctx, unit: k)
        }
        ctx.restoreGState()

        if let id = doc.selectedID, let selected = doc.annotations.first(where: { $0.id == id }) {
            let outline = selectionOutline(for: selected)
            let path = NSBezierPath(cgPath: ContinuousCorners.path(in: outline.rect, radius: outline.radius))
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            if selected.kind == .text, doc.editingTextID == nil {
                drawResizeHandle(at: resizeHandleCenter(for: selected), in: ctx)
            }
        }

        if doc.tool == .crop, let pending = doc.pendingCrop {
            drawCropOverlay(toView(pending), imageFrame: imageFrame, pixelSize: pending.size)
        }
    }

    private func drawCropOverlay(_ crop: CGRect, imageFrame: CGRect, pixelSize: CGSize) {
        let dim = NSBezierPath(rect: imageFrame)
        dim.append(NSBezierPath(rect: crop))
        dim.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.55).setFill()
        dim.fill()

        NSColor(white: 1, alpha: 0.3).setStroke()
        for i in 1...2 {
            let x = crop.minX + crop.width * CGFloat(i) / 3
            let y = crop.minY + crop.height * CGFloat(i) / 3
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: x, y: crop.minY))
            grid.line(to: NSPoint(x: x, y: crop.maxY))
            grid.move(to: NSPoint(x: crop.minX, y: y))
            grid.line(to: NSPoint(x: crop.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
        }

        let border = NSBezierPath(rect: crop)
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()

        // L-shaped corner handles.
        let arm = min(18, crop.width / 3, crop.height / 3)
        let handles = NSBezierPath()
        handles.lineWidth = 4
        handles.lineCapStyle = .round
        for (corner, dx, dy) in [
            (NSPoint(x: crop.minX, y: crop.minY), 1.0, 1.0), (NSPoint(x: crop.maxX, y: crop.minY), -1.0, 1.0),
            (NSPoint(x: crop.minX, y: crop.maxY), 1.0, -1.0), (NSPoint(x: crop.maxX, y: crop.maxY), -1.0, -1.0),
        ] {
            handles.move(to: NSPoint(x: corner.x + dx * arm, y: corner.y))
            handles.line(to: corner)
            handles.line(to: NSPoint(x: corner.x, y: corner.y + dy * arm))
        }
        handles.stroke()

        let label = "\(Int(pixelSize.width / doc.scale)) × \(Int(pixelSize.height / doc.scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: label, attributes: attributes)
        let size = string.size()
        var pill = NSRect(x: crop.midX - size.width / 2 - 7, y: crop.maxY + 8, width: size.width + 14, height: size.height + 5)
        if pill.maxY > bounds.maxY - 4 { pill.origin.y = crop.maxY - pill.height - 8 }
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 2.5))
    }

    private func drawResizeHandle(at center: CGPoint, in ctx: CGContext) {
        let r = Self.handleRadius
        let dot = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: dot.insetBy(dx: 0.75, dy: 0.75))
    }

    private static let handleRadius: CGFloat = 5

    /// The dashed outline around a selection, in view coordinates. A label's plate has soft continuous
    /// corners, so its outline follows them at the same distance instead of boxing them in.
    private func selectionOutline(for a: Annotation) -> (rect: CGRect, radius: CGFloat) {
        let gap: CGFloat = 3
        let rect = toView(a.bounds).insetBy(dx: -gap, dy: -gap)
        guard a.kind == .text, a.style.label != .plain else { return (rect, 4) }
        let (k, _) = layoutInfo
        let plate = a.bounds
        let radius = TextLabelMetrics(label: a.style.label, fontSize: a.fontPixelSize).cornerRadius(for: plate) * k + gap
        return (rect, min(radius, ContinuousCorners.maxRadius(for: rect)))
    }

    /// The bottom-right corner of the selection outline, on its curve.
    private func resizeHandleCenter(for a: Annotation) -> CGPoint {
        let outline = selectionOutline(for: a)
        let inset = outline.radius * ContinuousCorners.diagonalInset
        return CGPoint(x: outline.rect.maxX - inset, y: outline.rect.maxY - inset)
    }

    /// Where the resize handle can be grabbed: a little larger than the drawn dot.
    private func resizeHandleHitRect(for a: Annotation) -> CGRect {
        let c = resizeHandleCenter(for: a)
        let r = Self.handleRadius + 4
        return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    /// The selected label, when it shows a resize handle (not while typing into it).
    private var resizableLabel: Annotation? {
        guard doc.tool == .select || doc.tool == .text, doc.editingTextID == nil,
              let selected = doc.selectedAnnotation, selected.kind == .text
        else { return nil }
        return selected
    }

    /// The selected label, when the pointer is on its resize handle.
    private func textResizeTarget(at viewPoint: CGPoint) -> Annotation? {
        resizableLabel.flatMap { resizeHandleHitRect(for: $0).contains(viewPoint) ? $0 : nil }
    }

    private func reportZoom(_ k: CGFloat) {
        let zoom = (k * doc.scale * 100).rounded() / 100
        guard zoom != doc.zoom else { return }
        Task { @MainActor in self.doc.zoom = zoom }
    }

    override func resetCursorRects() {
        let imageFrame = toView(region)
        switch doc.tool {
        case .select: addCursorRect(imageFrame, cursor: .arrow)
        case .crop: addCursorRect(bounds, cursor: .crosshair)
        case .text: addCursorRect(imageFrame, cursor: .iBeam)
        default: addCursorRect(imageFrame, cursor: .crosshair)
        }
        if let label = resizableLabel {
            let cursor: NSCursor
            if #available(macOS 15, *) {
                cursor = .frameResize(position: .bottomRight, directions: .all)
            } else {
                cursor = .crosshair
            }
            addCursorRect(resizeHandleHitRect(for: label), cursor: cursor)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = toImage(viewPoint)
        let (k, _) = layoutInfo

        // A click on the padding of the label being typed keeps typing; anywhere else commits it.
        let wasEditing = doc.editingTextID != nil
        if let id = doc.editingTextID, let editing = doc.annotations.first(where: { $0.id == id }),
           editing.hitTest(p, tolerance: 4 / k) {
            window?.makeFirstResponder(textView)
            return
        }
        window?.makeFirstResponder(self)
        doc.endTextEditing()

        if let label = textResizeTarget(at: viewPoint) {
            // Scaling is measured from where the handle was grabbed, so the label doesn't jump on the first move.
            drag = .resizingText(
                id: label.id, anchor: label.bounds.origin, corner: p,
                original: label.fontPixelSize, didResize: false
            )
            return
        }

        switch doc.tool {
        case .select:
            if let hit = doc.annotations.last(where: { $0.hitTest(p, tolerance: 6 / k) }) {
                if hit.kind == .text, event.clickCount == 2 {
                    doc.beginEditingText(hit.id)
                    return
                }
                doc.selectedID = hit.id
                drag = .moving(id: hit.id, last: p, didMove: false)
            } else {
                doc.selectedID = nil
            }
        case .text:
            // A click away from a label being typed only commits it.
            guard !wasEditing else { break }
            if let hit = doc.annotations.last(where: { $0.kind == .text && $0.hitTest(p, tolerance: 4 / k) }) {
                doc.selectedID = hit.id
                drag = .pressingText(id: hit.id, start: p)
            } else if !region.contains(p) {
                // Labels are drawn and exported inside the image only.
                doc.selectedID = nil
            } else {
                // Center the first line's capitals on the click, where the caret appears.
                let capHeight = CTFontGetCapHeight(doc.style.font.ctFont(size: doc.style.weight.textPoints * doc.scale))
                doc.beginNewText(at: CGPoint(x: p.x, y: p.y - capHeight / 2))
            }
        case .crop:
            let current = doc.pendingCrop ?? doc.crop
            let edges = cropEdges(at: viewPoint, crop: toView(current))
            if !edges.isEmpty {
                drag = .resizeCrop(edges: edges, original: current)
            } else if current.contains(p) {
                drag = .moveCrop(start: p, original: current)
            } else {
                let anchor = clampToImage(p)
                doc.pendingCrop = CGRect(origin: anchor, size: .zero)
                drag = .newCrop(anchor: anchor)
            }
        default:
            guard let kind = doc.tool.annotationKind else { return }
            doc.selectedID = nil
            drag = .drawing(Annotation(kind: kind, start: p, end: p, points: [p], style: doc.style, scale: doc.scale))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case var .drawing(annotation):
            if annotation.kind == .pen {
                annotation.points.append(p)
            } else {
                annotation.end = shift ? constrained(p, from: annotation.start, kind: annotation.kind) : p
            }
            drag = .drawing(annotation)
        case let .moving(id, last, didMove):
            guard let index = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
            if !didMove { doc.checkpoint() }
            doc.annotations[index].translate(by: p - last)
            drag = .moving(id: id, last: p, didMove: true)
        case let .pressingText(id, start):
            let (k, _) = layoutInfo
            guard hypot(p.x - start.x, p.y - start.y) * k > 3,
                  let index = doc.annotations.firstIndex(where: { $0.id == id })
            else { return }
            doc.checkpoint()
            doc.annotations[index].translate(by: p - start)
            drag = .moving(id: id, last: p, didMove: true)
        case let .resizingText(id, anchor, corner, original, didResize):
            guard let index = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
            if !didResize { doc.checkpoint() }
            let size = TextResize.fontSize(original: original, anchor: anchor, corner: corner, current: p, scale: doc.scale)
            doc.annotations[index].fontSize = size / doc.scale
            doc.annotations[index].start = TextLabelMetrics(label: doc.annotations[index].style.label, fontSize: size)
                .inkOrigin(forPlateAt: anchor)
            drag = .resizingText(id: id, anchor: anchor, corner: corner, original: original, didResize: true)
        case let .newCrop(anchor):
            var end = clampToImage(p)
            if shift {
                let side = max(abs(end.x - anchor.x), abs(end.y - anchor.y))
                end = clampToImage(CGPoint(x: anchor.x + (end.x < anchor.x ? -side : side), y: anchor.y + (end.y < anchor.y ? -side : side)))
            }
            doc.pendingCrop = CGRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y), width: abs(end.x - anchor.x), height: abs(end.y - anchor.y))
        case let .moveCrop(start, original):
            let bounds = doc.imageBounds
            var moved = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            doc.pendingCrop = moved
        case let .resizeCrop(edges, original):
            let q = clampToImage(p)
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if edges.contains(.left) { minX = q.x }
            if edges.contains(.right) { maxX = q.x }
            if edges.contains(.top) { minY = q.y }
            if edges.contains(.bottom) { maxY = q.y }
            doc.pendingCrop = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case let .drawing(annotation) = drag, !annotation.isDegenerate {
            doc.add(annotation)
        }
        if case let .pressingText(id, _) = drag {
            doc.beginEditingText(id)
        }
        if case .newCrop = drag, let pending = doc.pendingCrop, pending.width < 4 || pending.height < 4 {
            doc.pendingCrop = doc.crop
        }
        drag = nil
        needsDisplay = true
    }

    private func cropEdges(at p: NSPoint, crop: CGRect) -> Edges {
        let tolerance: CGFloat = 8
        guard crop.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return [] }
        var edges: Edges = []
        if abs(p.x - crop.minX) < tolerance { edges.insert(.left) }
        if abs(p.x - crop.maxX) < tolerance { edges.insert(.right) }
        if abs(p.y - crop.minY) < tolerance { edges.insert(.top) }
        if abs(p.y - crop.maxY) < tolerance { edges.insert(.bottom) }
        return edges
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), CGFloat(doc.image.width)), y: min(max(p.y, 0), CGFloat(doc.image.height)))
    }

    /// Shift: squares and circles, or lines snapped to 45°.
    private func constrained(_ p: CGPoint, from start: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = p.x - start.x
        let dy = p.y - start.y
        switch kind {
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            doc.deleteSelected()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if doc.tool == .crop {
                doc.applyCrop()
                doc.tool = .arrow
            } else if let selected = doc.selectedAnnotation, selected.kind == .text {
                doc.beginEditingText(selected.id)
            }
        case kVK_Escape:
            if doc.tool == .crop { doc.cancelCrop() } else { doc.selectedID = nil }
        default:
            let character = flags.isEmpty ? event.charactersIgnoringModifiers?.lowercased().first : nil
            if let character, let tool = EditorTool.allCases.first(where: { $0.shortcutKey == character }) {
                doc.tool = tool
            } else if let character, let swatch = AnnotationPalette.swatch(forKey: character) {
                doc.updateStyle { $0.color = swatch.color }
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

// MARK: - Inline text editing

extension EditorCanvasView {
    /// Creates, moves or removes the inline text editor to match the document's edit.
    fileprivate func syncTextEditor() {
        guard let id = doc.editingTextID, let label = doc.annotations.first(where: { $0.id == id }) else {
            tearDownTextEditor()
            return
        }
        if textViewID != id { tearDownTextEditor() }
        let editor = textView ?? makeTextEditor(for: label)

        let (k, _) = layoutInfo
        let layout = TextLayout(label)
        let font = CTFontCreateCopyWithAttributes(layout.font, layout.fontSize * k, nil, nil) as NSFont
        if editor.font != font {
            editor.font = font
            editor.typingAttributes[.font] = font
        }
        let caret = caretColor(for: label)
        editor.insertionPointColor = caret.nsColor
        // On a filled label the accent would vanish into the plate; the text color's tint shows instead.
        let highlight = label.style.label == .filled ? caret.withAlpha(0.3).nsColor : NSColor.controlAccentColor.withAlphaComponent(0.35)
        if (editor.layoutManager as? LabelLayoutManager)?.highlight != highlight {
            (editor.layoutManager as? LabelLayoutManager)?.highlight = highlight
            editor.selectedTextAttributes = [.backgroundColor: highlight]
        }
        // An em of slack on the right keeps the caret inside the view before the next sync widens it.
        var frame = toView(layout.lineBoxesFrame)
        frame.size.width += layout.fontSize * k
        if editor.frame != frame { editor.frame = frame }
    }

    private func makeTextEditor(for label: Annotation) -> NSTextView {
        let editor = NSTextView(usingTextLayoutManager: false)
        editor.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.focusRingType = .none
        // The canvas draws the glyphs; the editor only shows the caret and the selection.
        editor.textColor = .clear
        editor.typingAttributes[.foregroundColor] = NSColor.clear
        // A translucent highlight with no text color of its own, so selected glyphs stay the label's.
        editor.textContainer?.replaceLayoutManager(LabelLayoutManager())
        editor.string = label.text
        editor.delegate = self
        textUndoManager = UndoManager()
        addSubview(editor)
        textView = editor
        textViewID = label.id
        window?.makeFirstResponder(editor)
        // Re-editing selects everything, so typing replaces it and a click places the caret.
        editor.selectAll(nil)
        return editor
    }

    private func tearDownTextEditor() {
        guard let editor = textView else { return }
        // Cleared first: removing a focused editor ends its editing, which mustn't end the next edit.
        textView = nil
        textViewID = nil
        let hadFocus = window?.firstResponder === editor
        editor.delegate = nil
        editor.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(self) }
    }

    private func caretColor(for label: Annotation) -> StyleColor {
        label.style.label == .filled ? TextContrast.textColor(onPlate: label.style.color) : label.style.color
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === textView else { return }
        doc.setEditingText(editor.string)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === textView else { return }
        doc.endTextEditing()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        // Typing undo stays inside the edit; the whole edit is one step in the editor's own history.
        textUndoManager
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return commits; Shift- or Option-Return starts a new line.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                doc.endTextEditing()
            }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)), #selector(NSResponder.insertTab(_:)):
            doc.endTextEditing()
            return true
        default:
            return false
        }
    }
}

/// Draws the text selection translucent even while another window is key (the style popover), where
/// AppKit would otherwise paint an opaque gray over the label being restyled.
private final class LabelLayoutManager: NSLayoutManager {
    var highlight = NSColor.controlAccentColor.withAlphaComponent(0.35)

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        highlight.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: highlight)
    }
}
