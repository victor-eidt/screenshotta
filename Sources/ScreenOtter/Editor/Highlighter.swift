import AppKit

/// The shape of a highlighter stroke, in image pixels (top-left origin).
///
/// A highlighter is drawn the way a real chisel marker lays ink: a flat, slightly tilted nib swept along
/// the stroke. The sweep gives flat, slanted ends for free, a full-height band on the horizontal strokes
/// highlighters are mostly used for, and a narrower one going up and down, like the real thing.
nonisolated enum HighlighterGeometry {
    /// How far the nib leans from vertical. Enough for the ends to read as cut by a chisel, not by scissors.
    static let nibTilt: CGFloat = 14 * .pi / 180
    /// The nib's thickness, as a fraction of the stroke's height: what's left on vertical strokes.
    static let nibThickness: CGFloat = 0.3
    /// The nib's corners are eased a little, so the ends look inked rather than cut out with a knife.
    static let nibCornerRounding: CGFloat = 0.12

    /// Strokes shorter than this, in points, are a click.
    static let minimumLengthPoints: CGFloat = 3

    /// Shift keeps a stroke on the line it started on, straight across the text it's marking.
    static func snapped(_ p: CGPoint, from start: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: start.y)
    }

    /// The pointer's raw positions, eased into a smooth line: points closer than `spacing` are dropped
    /// (they only add jitter), then two passes of Chaikin's corner cutting round off what's left. The
    /// ends stay where the stroke started and finished, so a straight stroke keeps its length.
    static func smoothed(_ points: [CGPoint], spacing: CGFloat = 1) -> [CGPoint] {
        var path: [CGPoint] = []
        for p in points where path.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= spacing }) ?? true {
            path.append(p)
        }
        if let last = points.last, path.count > 1, path.last != last { path[path.count - 1] = last }
        guard path.count > 2 else { return path }
        for _ in 0..<2 {
            var cut = [path[0]]
            for (a, b) in zip(path, path.dropFirst()) {
                cut.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
                cut.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
            cut.append(path[path.count - 1])
            path = cut
        }
        return path
    }

    /// The nib's outline around the origin, for a stroke `height` pixels tall when drawn horizontally.
    static func nib(height: CGFloat) -> [CGPoint] {
        let thickness = height * nibThickness
        // Solve for the nib's length so a horizontal stroke is exactly `height` tall.
        let length = max((height - thickness * sin(nibTilt)) / cos(nibTilt), thickness)
        let along = CGPoint(x: sin(nibTilt), y: -cos(nibTilt)) // up the nib, leaning right
        let across = CGPoint(x: cos(nibTilt), y: sin(nibTilt))
        let r = min(thickness, length) * nibCornerRounding
        // A rounded rectangle in the nib's own axes (u along it, v across), each corner a short arc.
        var outline: [CGPoint] = []
        for (cu, cv, from) in [(1.0, 1.0, 0.0), (-1.0, 1.0, 0.5), (-1.0, -1.0, 1.0), (1.0, -1.0, 1.5)] {
            let center = (u: cu * (length / 2 - r), v: cv * (thickness / 2 - r))
            for k in 0...3 {
                let angle = (from + CGFloat(k) / 6) * .pi
                let u = center.u + r * cos(angle), v = center.v + r * sin(angle)
                outline.append(CGPoint(x: along.x * u + across.x * v, y: along.y * u + across.y * v))
            }
        }
        return convexHull(outline)
    }

    /// The filled outline of a stroke through `points`: the nib swept along each segment, as one path of
    /// convex pieces wound the same way, so filling it covers their union once and the translucent ink
    /// never doubles up where the pieces overlap.
    static func outline(_ points: [CGPoint], height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let nib = nib(height: height)
        // A tenth of the height: fine enough to follow any turn the band can show, coarse enough to
        // drop the pointer's jitter.
        let line = smoothed(points, spacing: height * 0.1)
        guard let first = line.first else { return path }
        func placed(at p: CGPoint) -> [CGPoint] { nib.map { CGPoint(x: $0.x + p.x, y: $0.y + p.y) } }
        if line.count == 1 {
            path.addLines(between: placed(at: first))
            path.closeSubpath()
            return path
        }
        for (a, b) in zip(line, line.dropFirst()) {
            path.addLines(between: convexHull(placed(at: a) + placed(at: b)))
            path.closeSubpath()
        }
        return path
    }

    /// The length of the stroke, along its points.
    static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Andrew's monotone chain. Every hull comes out wound the same way, which `outline` relies on.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

extension StrokeWeight {
    /// A highlighter's height in points: regular covers a line of interface text with a little to spare.
    nonisolated var highlighterPoints: CGFloat {
        switch self {
        case .fine: 12
        case .regular: 18
        case .bold: 26
        case .heavy: 36
        }
    }
}

/// Marker tints: light enough that multiplied over text the text stays dark and crisp, saturated enough
/// to read on a white page. Yellow first, because that's what a highlighter is.
nonisolated enum HighlighterPalette {
    static let swatches: [AnnotationPalette.Swatch] = [
        AnnotationPalette.Swatch(name: "Yellow", color: StyleColor(hex: "#FFE14A")!),
        AnnotationPalette.Swatch(name: "Mint", color: StyleColor(hex: "#9EF0B4")!),
        AnnotationPalette.Swatch(name: "Sky", color: StyleColor(hex: "#9CD8FF")!),
        AnnotationPalette.Swatch(name: "Pink", color: StyleColor(hex: "#FFB0D6")!),
        AnnotationPalette.Swatch(name: "Lilac", color: StyleColor(hex: "#CDB8FF")!),
    ]

    static let `default` = swatches[0].color

    /// The least luminance marker ink may have, like every tint above: darker ink, multiplied over text,
    /// would sink it into the band.
    static let minimumLuminance = 0.5

    /// A color as marker ink: kept when it is light enough, otherwise mixed toward white until it is, so
    /// a custom navy becomes a soft blue rather than a bar that buries the text.
    static func ink(_ color: StyleColor) -> StyleColor {
        guard color.luminance <= minimumLuminance else { return color }
        func mixed(_ t: Double) -> StyleColor {
            func channel(_ c: UInt8) -> UInt8 { UInt8((Double(c) + (255 - Double(c)) * t).rounded()) }
            return StyleColor(red: channel(color.red), green: channel(color.green), blue: channel(color.blue), alpha: color.alpha)
        }
        // The least white that clears the bar, so the hue stays as strong as it can.
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if mixed(mid).luminance > minimumLuminance { high = mid } else { low = mid }
        }
        return mixed(high)
    }
}

extension AnnotationRenderer {
    /// How strongly the ink multiplies over the screenshot. Below 1 so the page's own texture and the
    /// edges of the letters show through, like real ink.
    static let highlighterInk: CGFloat = 0.92
    /// A faint glow of the same tint, screened on top: invisible on a light page (screen leaves white
    /// white), it is what makes the mark show up on a dark interface, where multiply alone vanishes.
    static let highlighterGlow: CGFloat = 0.2

    /// Draws a highlighter stroke as translucent ink: multiplied over the screenshot, so the text under
    /// it keeps its color and contrast, with no shadow.
    static func drawHighlight(_ a: Annotation, in ctx: CGContext) {
        let outline = HighlighterGeometry.outline(a.points, height: a.highlighterHeight)
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(a.style.marker.withAlpha(highlighterInk).cgColor)
        ctx.addPath(outline)
        ctx.fillPath()
        ctx.setBlendMode(.screen)
        ctx.setFillColor(a.style.marker.withAlpha(highlighterGlow).cgColor)
        ctx.addPath(outline)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
