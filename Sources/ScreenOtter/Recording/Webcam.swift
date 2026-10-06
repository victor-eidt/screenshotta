import CoreGraphics
import Foundation

// The webcam bubble: the camera recorded next to the screen, drawn over the edited video.
// ("Camera" alone already names the zoom's virtual camera in the renderer, hence "webcam" in code.)

/// The camera file recorded with the screen. Its time zero is its own first frame, `offset` seconds after
/// the first screen frame (negative when the camera was already rolling), so file seconds + offset are
/// recording seconds.
nonisolated struct RecordedWebcam: Codable, Equatable, Sendable {
    /// File name inside the draft folder.
    var file: String
    /// The camera's name, for the editor.
    var deviceName: String?
    var offset: Double

    static let fileName = "camera.mov"
}

nonisolated extension ClipTimeMapping {
    /// The pieces of a file whose first frame is `fileOffset` recording seconds in (negative when it started
    /// before the screen), in file seconds. The part of the file before the screen's first frame never plays.
    static func pieces(segments: [ClipSegment], videoDuration: Double, fileDuration: Double, fileOffset: Double) -> [Piece] {
        let shifted = segments.map { segment in
            var segment = segment
            segment.start -= fileOffset
            segment.end -= fileOffset
            return segment
        }
        return pieces(segments: shifted, videoDuration: videoDuration - fileOffset, fileDuration: fileDuration)
    }
}

nonisolated enum WebcamShape: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A rounded square with continuous (superellipse) corners, like an app icon.
    case squircle
    case circle
    /// ScreenOtter's own: a smooth, slightly irregular stone, like the one the otter keeps under its arm.
    case pebble

    var id: String { rawValue }

    var title: String {
        switch self {
        case .squircle: "Rounded"
        case .circle: "Circle"
        case .pebble: "Pebble"
        }
    }

    /// Width over height.
    var aspect: CGFloat {
        switch self {
        case .squircle, .circle: 1
        case .pebble: 1.1
        }
    }
}

nonisolated enum WebcamSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    /// The full name, for VoiceOver and tooltips (the pills only show the letter).
    var name: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Height of the bubble, as a fraction of the video's shorter side.
    var fraction: CGFloat {
        switch self {
        case .small: 0.2
        case .medium: 0.26
        case .large: 0.34
        }
    }
}

/// What the bubble does while the video is zoomed in, so it never sits on top of what the zoom is showing.
nonisolated enum WebcamZoomBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case shrink, hide, keep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shrink: "Shrink"
        case .hide: "Hide"
        case .keep: "Keep"
        }
    }
}

/// How the bubble looks. Part of the recording style, so it carries over to the next recording.
nonisolated struct WebcamStyle: Codable, Equatable, Sendable {
    var shape: WebcamShape = .squircle
    var size: WebcamSize = .medium
    /// Where the bubble sits in the room it has to move: 0 is against the left (top) margin, 1 against the
    /// right (bottom) one. The corners stay corners whatever the size or aspect ratio.
    var x: Double = 1
    var y: Double = 1
    /// Shows you as in a mirror, the way you saw yourself while recording.
    var mirror = true
    /// A thin light ring around the edge.
    var border = true
    var shadow = true
    var duringZoom: WebcamZoomBehavior = .shrink

    init() {}

    // Field by field, so older styles (and styles from before a new option) still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WebcamStyle()
        shape = (try? c.decode(WebcamShape.self, forKey: .shape)) ?? d.shape
        size = (try? c.decode(WebcamSize.self, forKey: .size)) ?? d.size
        x = (try? c.decode(Double.self, forKey: .x)).map { min(max($0, 0), 1) } ?? d.x
        y = (try? c.decode(Double.self, forKey: .y)).map { min(max($0, 0), 1) } ?? d.y
        mirror = (try? c.decode(Bool.self, forKey: .mirror)) ?? d.mirror
        border = (try? c.decode(Bool.self, forKey: .border)) ?? d.border
        shadow = (try? c.decode(Bool.self, forKey: .shadow)) ?? d.shadow
        duringZoom = (try? c.decode(WebcamZoomBehavior.self, forKey: .duringZoom)) ?? d.duringZoom
    }

    private enum CodingKeys: String, CodingKey {
        case shape, size, x, y, mirror, border, shadow, duringZoom
    }
}

nonisolated enum WebcamCorner: CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: Self { self }

    var position: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .topRight: (1, 0)
        case .bottomLeft: (0, 1)
        case .bottomRight: (1, 1)
        }
    }

    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

// MARK: - Layout

/// Where the bubble goes on the output, in top-left-origin output pixels. Shared by the renderer and the
/// editor's drag handle, so what you drag is what gets drawn.
nonisolated enum WebcamLayout {
    /// Space between the bubble and the video's edges, as a fraction of the shorter side.
    static let margin: CGFloat = 0.04
    /// How small the bubble gets at full zoom with `.shrink`.
    static let shrunkScale: CGFloat = 0.62
    /// Releasing a drag this close to a corner (in position units) lands exactly in it.
    static let snapDistance = 0.08

    /// The bubble at rest on a `canvas`-sized output.
    static func frame(_ style: WebcamStyle, canvas: CGSize) -> CGRect {
        let short = min(canvas.width, canvas.height)
        let margin = (self.margin * short).rounded()
        var height = (style.size.fraction * short).rounded()
        var width = (height * style.shape.aspect).rounded()
        // Never wider or taller than the room between the margins.
        let fit = min(1, (canvas.width - margin * 2) / max(width, 1), (canvas.height - margin * 2) / max(height, 1))
        width = (width * fit).rounded()
        height = (height * fit).rounded()
        let roomX = max(canvas.width - margin * 2 - width, 0)
        let roomY = max(canvas.height - margin * 2 - height, 0)
        return CGRect(
            x: (margin + roomX * CGFloat(min(max(style.x, 0), 1))).rounded(),
            y: (margin + roomY * CGFloat(min(max(style.y, 0), 1))).rounded(),
            width: width,
            height: height
        )
    }

    /// 0 with no zoom, easing to 1 once the zoom is about a third of the way in, so the bubble is out of
    /// the way before the zoom lands.
    static func zoomProgress(scale: Double) -> Double {
        let p = min(max((scale - 1) / 0.35, 0), 1)
        return p * p * (3 - 2 * p)
    }

    /// The bubble's frame and opacity at a moment where the zoom is at `zoomScale`.
    static func presentation(_ style: WebcamStyle, canvas: CGSize, zoomScale: Double) -> (frame: CGRect, opacity: Double) {
        let rest = frame(style, canvas: canvas)
        let p = zoomProgress(scale: zoomScale)
        switch style.duringZoom {
        case .keep:
            return (rest, 1)
        case .shrink:
            return (scaled(rest, by: 1 - (1 - shrunkScale) * CGFloat(p), style: style), 1)
        case .hide:
            return (scaled(rest, by: 1 - 0.12 * CGFloat(p), style: style), 1 - p)
        }
    }

    /// Whether a bubble at `opacity` can be hovered and dragged in the editor: not once it has mostly faded
    /// out for a zoom, when there'd be nothing to see under the pointer.
    static func isGrabbable(opacity: Double) -> Bool {
        opacity >= 0.05
    }

    /// Scales toward the side the bubble sits on: one in a corner tucks into that corner.
    private static func scaled(_ rect: CGRect, by k: CGFloat, style: WebcamStyle) -> CGRect {
        let anchor = CGPoint(x: rect.minX + rect.width * CGFloat(style.x), y: rect.minY + rect.height * CGFloat(style.y))
        return CGRect(
            x: anchor.x - (anchor.x - rect.minX) * k,
            y: anchor.y - (anchor.y - rect.minY) * k,
            width: rect.width * k,
            height: rect.height * k
        )
    }

    /// The position that puts the bubble's top-left corner at `origin`, clamped to the room it has.
    static func position(origin: CGPoint, style: WebcamStyle, canvas: CGSize) -> (x: Double, y: Double) {
        let rest = frame(style, canvas: canvas)
        let short = min(canvas.width, canvas.height)
        let margin = (self.margin * short).rounded()
        let roomX = canvas.width - margin * 2 - rest.width
        let roomY = canvas.height - margin * 2 - rest.height
        let x = roomX > 0.5 ? Double((origin.x - margin) / roomX) : 0.5
        let y = roomY > 0.5 ? Double((origin.y - margin) / roomY) : 0.5
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// A dropped position, pulled into a corner when it's close to one.
    static func snapped(_ position: (x: Double, y: Double)) -> (x: Double, y: Double) {
        for corner in WebcamCorner.allCases {
            let c = corner.position
            if abs(position.x - c.x) <= snapDistance, abs(position.y - c.y) <= snapDistance { return c }
        }
        return position
    }

    /// The corner the bubble is in, if it's exactly in one.
    static func corner(of style: WebcamStyle) -> WebcamCorner? {
        WebcamCorner.allCases.first { $0.position.x == style.x && $0.position.y == style.y }
    }

    /// How a camera frame of `source` size fills a bubble of `size`: the scale, and the part of the scaled
    /// frame that shows (centered, cropped to the bubble).
    static func fill(source: CGSize, into size: CGSize) -> (scale: CGFloat, crop: CGRect) {
        guard source.width > 0, source.height > 0 else { return (1, CGRect(origin: .zero, size: size)) }
        let scale = max(size.width / source.width, size.height / source.height)
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        return (scale, CGRect(x: (scaled.width - size.width) / 2, y: (scaled.height - size.height) / 2, width: size.width, height: size.height))
    }
}

// MARK: - Shapes

nonisolated extension WebcamShape {
    /// The outline filling `rect`, as a closed polygon fine enough to read as a smooth curve at any size
    /// the bubble is drawn (a degree or less of turn between neighbouring points).
    func outline(in rect: CGRect) -> [CGPoint] {
        switch self {
        case .circle: Self.superellipse(in: rect, exponent: 2, count: 360)
        case .squircle: Self.continuousRoundedRect(in: rect, cornerFraction: 0.3, exponent: 4.2, pointsPerCorner: 90)
        case .pebble: Self.pebble(in: rect, count: 540)
        }
    }

    func path(in rect: CGRect) -> CGPath {
        if self == .circle { return CGPath(ellipseIn: rect, transform: nil) }
        let path = CGMutablePath()
        path.addLines(between: outline(in: rect))
        path.closeSubpath()
        return path
    }

    /// |x/a|^n + |y/b|^n = 1 filling `rect`; n = 2 is an ellipse.
    static func superellipse(in rect: CGRect, exponent n: Double, count: Int) -> [CGPoint] {
        let a = rect.width / 2, b = rect.height / 2
        return (0..<count).map { i in
            let t = Double(i) / Double(count) * 2 * .pi
            let c = cos(t), s = sin(t)
            return CGPoint(
                x: rect.midX + a * CGFloat(copysign(pow(abs(c), 2 / n), c)),
                y: rect.midY + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
            )
        }
    }

    /// Straight sides joined by superellipse quarters. Unlike circular arcs, the curvature grows from zero
    /// where a side ends, so the corner flows out of the edge instead of starting abruptly: Apple's
    /// "continuous" corners. Each corner spans `cornerFraction` of the shorter side along both edges.
    static func continuousRoundedRect(in rect: CGRect, cornerFraction: CGFloat, exponent n: Double, pointsPerCorner: Int) -> [CGPoint] {
        let e = min(rect.width, rect.height) * min(max(cornerFraction, 0), 0.5)
        // Corner centers and the direction of each corner's x and y axes, clockwise from the top right
        // (top-left origin: y grows downward).
        let corners: [(center: CGPoint, sx: CGFloat, sy: CGFloat)] = [
            (CGPoint(x: rect.maxX - e, y: rect.minY + e), 1, -1),
            (CGPoint(x: rect.maxX - e, y: rect.maxY - e), 1, 1),
            (CGPoint(x: rect.minX + e, y: rect.maxY - e), -1, 1),
            (CGPoint(x: rect.minX + e, y: rect.minY + e), -1, -1),
        ]
        var points: [CGPoint] = []
        for (index, corner) in corners.enumerated() {
            for i in 0...pointsPerCorner {
                // Top right runs from the top edge to the right edge, the next from the right edge down, and so on.
                var u = Double(i) / Double(pointsPerCorner) * .pi / 2
                if index % 2 == 0 { u = .pi / 2 - u }
                let cx = CGFloat(pow(cos(u), 2 / n)), cy = CGFloat(pow(sin(u), 2 / n))
                points.append(CGPoint(x: corner.center.x + corner.sx * e * cx, y: corner.center.y + corner.sy * e * cy))
            }
        }
        return points
    }

    /// A smooth river stone: a soft superellipse, one end a little broader than the other, turned slightly
    /// off axis and stretched to fill `rect`. Only low harmonics, so it has character but no bumps.
    static func pebble(in rect: CGRect, count: Int) -> [CGPoint] {
        let tilt = -0.1
        let raw: [CGPoint] = (0..<count).map { i in
            let t = Double(i) / Double(count) * 2 * .pi
            let c = cos(t), s = sin(t)
            let n = 2.6
            let base = pow(pow(abs(c), n) + pow(abs(s), n), -1 / n)
            let r = base * (1 + 0.035 * cos(t + 0.8) + 0.015 * cos(2 * t + 1.2) + 0.008 * cos(3 * t + 0.3))
            let x = r * c * 1.08, y = r * s
            return CGPoint(x: x * cos(tilt) - y * sin(tilt), y: x * sin(tilt) + y * cos(tilt))
        }
        let minX = raw.map(\.x).min()!, maxX = raw.map(\.x).max()!
        let minY = raw.map(\.y).min()!, maxY = raw.map(\.y).max()!
        return raw.map { p in
            CGPoint(
                x: rect.minX + (p.x - minX) / (maxX - minX) * rect.width,
                y: rect.minY + (p.y - minY) / (maxY - minY) * rect.height
            )
        }
    }
}
