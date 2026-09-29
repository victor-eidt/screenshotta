import AppKit
import Carbon.HIToolbox
import Combine

final class EditorCanvasView: NSView {
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
        case newCrop(anchor: CGPoint)
        case moveCrop(start: CGPoint, original: CGRect)
        case resizeCrop(edges: Edges, original: CGRect)
    }

    private var drag: Drag?

    init(document: EditorDocument) {
        doc = document
        super.init(frame: .zero)
        cancellable = document.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value changes; redraw on the next pass.
            Task { @MainActor in
                guard let self else { return }
                self.needsDisplay = true
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
            let rect = toView(selected.bounds).insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
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
        default: addCursorRect(imageFrame, cursor: .crosshair)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = toImage(viewPoint)
        let (k, _) = layoutInfo

        switch doc.tool {
        case .select:
            if let hit = doc.annotations.last(where: { $0.hitTest(p, tolerance: 6 / k) }) {
                doc.selectedID = hit.id
                drag = .moving(id: hit.id, last: p, didMove: false)
            } else {
                doc.selectedID = nil
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
            drag = .drawing(Annotation(kind: kind, start: p, end: p, points: [p], color: doc.color, width: doc.stroke.points * doc.scale))
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
            if doc.tool == .crop { doc.applyCrop(); doc.tool = .arrow }
        case kVK_Escape:
            if doc.tool == .crop { doc.cancelCrop() } else { doc.selectedID = nil }
        default:
            if flags.isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = EditorTool.allCases.first(where: { $0.shortcutKey == character }) {
                doc.tool = tool
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
