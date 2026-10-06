import AppKit

enum EditorTool: String, CaseIterable, Identifiable {
    case select, crop, arrow, line, rectangle, ellipse, pen, highlight, text, redact, spotlight

    var id: String { rawValue }

    static let drawing: [EditorTool] = [.select, .arrow, .line, .rectangle, .ellipse, .pen, .highlight, .text, .redact, .spotlight]

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "rectangle.center.inset.filled"
        }
    }

    var help: String {
        switch self {
        case .select: "Select and move (V)"
        case .crop: "Crop (C)"
        case .arrow: "Arrow (A)"
        case .line: "Line (L)"
        case .rectangle: "Rectangle (R)"
        case .ellipse: "Circle (O)"
        case .pen: "Pen (P)"
        case .highlight: "Highlighter (H)"
        case .text: "Text (T)"
        case .redact: "Blur and pixelate (B)"
        case .spotlight: "Spotlight (S)"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlight: "h"
        case .text: "t"
        case .redact: "b"
        case .spotlight: "s"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlight: .highlight
        case .text: .text
        case .redact: .redact
        case .spotlight: .spotlight
        case .select, .crop: nil
        }
    }

    /// Whether switching to this tool keeps an annotation of `kind` selected: tools that edit their own
    /// kind in place (restyle a label, resize a redaction or a spotlight, recolor a highlight) keep it,
    /// so the style chip still applies.
    func keepsSelection(of kind: Annotation.Kind) -> Bool {
        switch self {
        case .select: true
        case .text: kind == .text
        case .redact: kind == .redact
        case .highlight: kind == .highlight
        case .spotlight: kind == .spotlight
        default: false
        }
    }
}

/// A shape drawn on the screenshot. Coordinates are image pixels, top-left origin.
struct Annotation: Identifiable, Equatable {
    enum Kind {
        case arrow, line, rectangle, ellipse, pen, text
        /// Blurs or pixelates the screenshot under its rect (the style's `redaction` picks which).
        case redact
        /// Translucent marker ink along `points`, multiplied over the screenshot.
        case highlight
        /// Keeps its rect lit while everything outside every spotlight is dimmed.
        case spotlight

        /// A rect on the screenshot that is moved and resized by its corners and edges, and stays on it.
        var isRegion: Bool { self == .redact || self == .spotlight }
    }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var style: AnnotationStyle
    /// Image pixels per point, so the stroke weight keeps its visual size on Retina captures.
    /// No default: a tool that forgot it would draw at half width on Retina.
    var scale: CGFloat
    /// The words of a text annotation, which is anchored at `start` (its first line's cap top).
    var text = ""
    /// A text size set by resizing, in points. Nil follows the style's weight.
    var fontSize: CGFloat?

    /// Stroke width in image pixels.
    var width: CGFloat { style.weight.points * scale }

    /// Text size in points: a resized label keeps its own, otherwise the weight picks one.
    var fontPointSize: CGFloat { fontSize ?? style.weight.textPoints }
    var fontPixelSize: CGFloat { fontPointSize * scale }

    /// A highlighter stroke's height in image pixels.
    var highlighterHeight: CGFloat { style.markerWeight.highlighterPoints * scale }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var bounds: CGRect {
        if kind == .text { return TextLayout(self).plate }
        if kind.isRegion { return rect }
        if kind == .highlight { return HighlighterGeometry.outline(points, height: highlighterHeight).boundingBoxOfPath }
        let base: CGRect
        if kind == .pen, let first = points.first {
            base = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        } else {
            base = rect
        }
        return base.insetBy(dx: -width * 2, dy: -width * 2)
    }

    /// Too small to be intentional (a click rather than a drag).
    var isDegenerate: Bool {
        switch kind {
        case .pen: points.count < 2
        case .text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .redact, .spotlight: min(rect.width, rect.height) < Self.minimumRegionSide * scale
        case .highlight: HighlighterGeometry.length(of: points) < HighlighterGeometry.minimumLengthPoints * scale
        default: hypot(end.x - start.x, end.y - start.y) < width
        }
    }

    /// The smallest side of a redaction or a spotlight, in points: smaller is a click, and couldn't hide
    /// (or show) anything anyway.
    static let minimumRegionSide: CGFloat = 4

    mutating func translate(by delta: CGPoint) {
        start = start + delta
        end = end + delta
        points = points.map { $0 + delta }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let t = tolerance + width
        switch kind {
        case .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .rectangle, .ellipse:
            return rect.insetBy(dx: -t, dy: -t).contains(p)
        case .redact, .spotlight:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .highlight:
            let reach = tolerance + highlighterHeight / 2
            guard points.count > 1 else { return points.first.map { hypot(p.x - $0.x, p.y - $0.y) <= reach } ?? false }
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= reach }
        case .line, .arrow:
            return distance(from: p, toSegment: start, end) <= t
        case .pen:
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= t }
        }
    }
}

private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let ab = b - a
    let lengthSquared = ab.x * ab.x + ab.y * ab.y
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
    let projection = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
    return hypot(p.x - projection.x, p.y - projection.y)
}

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
}

/// Draws the image and annotations into a context whose user space is image pixels with a top-left origin.
enum AnnotationRenderer {
    static func drawImage(_ image: CGImage, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
    }

    /// Draws every annotation over the screenshot, in layers: the spotlight's blur, then redactions (from
    /// the screenshot's own pixels, so nothing on top gets blurred into them), highlighter ink, the
    /// spotlight's dim, and the shapes and labels last, so they stay crisp and bright over all of it.
    /// - Parameters:
    ///   - visible: the part of the image being drawn (the crop), in image pixels.
    ///   - unit: device units per image pixel (shadows ignore the CTM, so they need it).
    static func drawAll(
        _ annotations: [Annotation], redactions: RedactionRenderer, spotlights: SpotlightRenderer,
        visible: CGRect, in ctx: CGContext, unit: CGFloat
    ) {
        let lit = SpotlightRenderer.shown(annotations, in: visible)
        // The spotlight's mask is smooth, so on screen it is made at the screen's resolution (device
        // pixels per image pixel), and never finer than the image.
        let device = ctx.userSpaceToDeviceSpaceTransform
        let resolution = min(1, hypot(device.a, device.b))
        let redacted = annotations.filter { $0.kind == .redact }
        spotlights.drawBlur(lit, redacted: redacted, redactions: redactions, visible: visible, resolution: resolution, in: ctx)
        for a in redacted {
            redactions.draw(a, visible: visible, in: ctx)
        }
        redactions.keepOnly(Set(redacted.map(\.id)))
        for a in annotations where a.kind == .highlight {
            drawHighlight(a, in: ctx)
        }
        spotlights.drawDim(lit, visible: visible, resolution: resolution, in: ctx)
        for a in annotations where !a.kind.isRegion && a.kind != .highlight {
            draw(a, in: ctx, unit: unit)
        }
    }

    /// - Parameter unit: device units per image pixel (shadows ignore the CTM, so they need it).
    static func draw(_ a: Annotation, in ctx: CGContext, unit: CGFloat) {
        if a.kind == .text { return drawText(a, in: ctx, unit: unit) }
        // Regions and highlights are drawn in their own layers by `drawAll`.
        if a.kind.isRegion || a.kind == .highlight { return }
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -a.width * 0.3 * unit),
            blur: a.width * 1.4 * unit,
            color: CGColor(gray: 0, alpha: 0.32)
        )
        ctx.setStrokeColor(a.style.color.cgColor)
        ctx.setFillColor(a.style.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .rectangle:
            let r = a.rect
            let radius = min(a.width * 1.6, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        case .ellipse:
            ctx.strokeEllipse(in: a.rect)
        case .line:
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .arrow:
            if let path = arrowPath(a) {
                ctx.setLineWidth(a.width * 0.35)
                ctx.addPath(path)
                ctx.drawPath(using: .fillStroke)
            }
        case .pen:
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .text, .redact, .highlight, .spotlight:
            break
        }
        ctx.restoreGState()
    }

    /// Tapered shaft plus a solid head, as one shape so the shadow isn't doubled.
    private static func arrowPath(_ a: Annotation) -> CGPath? {
        let d = a.end - a.start
        let length = hypot(d.x, d.y)
        guard length > 1 else { return nil }
        let dir = CGPoint(x: d.x / length, y: d.y / length)
        let normal = CGPoint(x: -dir.y, y: dir.x)

        let headLength = min(a.width * 4.2, length * 0.7)
        let headHalfWidth = headLength * 0.62
        let base = a.end - CGPoint(x: dir.x * headLength, y: dir.y * headLength)
        let tailHalf = a.width * 0.2
        let baseHalf = a.width * 0.62

        func offset(_ p: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + normal.x * k, y: p.y + normal.y * k) }

        let path = CGMutablePath()
        path.move(to: offset(a.start, tailHalf))
        path.addLine(to: offset(base, baseHalf))
        path.addLine(to: offset(base, headHalfWidth))
        path.addLine(to: a.end)
        path.addLine(to: offset(base, -headHalfWidth))
        path.addLine(to: offset(base, -baseHalf))
        path.addLine(to: offset(a.start, -tailHalf))
        path.closeSubpath()
        return path
    }

    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
