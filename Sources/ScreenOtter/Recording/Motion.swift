import CoreGraphics
import Foundation

/// Finds the moments worth zooming into: clusters of clicks.
nonisolated enum AutoZoom {
    /// Zoom starts this long before the first click of a cluster, so it has fully arrived by the click.
    private static let lead = MotionTrack.zoomInDuration + 0.2
    /// And holds this long after the last one, before easing out.
    private static let tail = 1.5
    /// Clicks closer together than this share one zoom.
    private static let clusterGap = 2.6
    private static let minimumLength = 2.4

    /// Auto zooms for `clicks`, merged with the hand-made zooms in `manual` (which always win).
    static func segments(clicks: [CursorRecording.Sample], duration: Double, scale: Double, keeping manual: [ZoomSegment]) -> [ZoomSegment] {
        var clusters: [(start: Double, end: Double)] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            if let last = clusters.last, click.t - last.end <= clusterGap {
                clusters[clusters.count - 1].end = click.t
            } else {
                clusters.append((click.t, click.t))
            }
        }

        var auto: [ZoomSegment] = []
        for cluster in clusters {
            let start = max(0, cluster.start - lead)
            var end = min(duration, cluster.end + tail)
            if end - start < minimumLength { end = min(duration, start + minimumLength) }
            guard end - start >= 1 else { continue }
            if let last = auto.last, start <= last.end + 0.5 {
                auto[auto.count - 1].end = max(last.end, end)
                continue
            }
            auto.append(ZoomSegment(start: start, end: end, scale: scale, isAuto: true))
        }
        let kept = auto.filter { zoom in !manual.contains { $0.start < zoom.end && $0.end > zoom.start } }
        return (manual + kept).sorted { $0.start < $1.start }
    }
}

/// How the output view relates to the recording as framed (cut, and with a new title bar).
nonisolated struct CameraGeometry: Sendable, Equatable {
    /// Half the full output view, in units of the framed recording: above 0.5 where there's padding.
    var viewHalf = CGSize(width: 0.5, height: 0.5)
    /// Recording (normalized) to framed recording (normalized): `x * scale.width + offset.x`, and so on.
    var scale = CGSize(width: 1, height: 1)
    var offset = CGPoint.zero
    /// The framed recording's height over its width, so distances count the same both ways.
    var aspect: CGFloat = 1

    func framed(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale.width + offset.x, y: p.y * scale.height + offset.y)
    }
}

/// Where the camera looks: a zoom factor and the center of the view, in the framed recording
/// (normalized, top-left origin).
nonisolated struct CameraState: Sendable {
    var scale: Double
    var x: Double
    var y: Double

    static let identity = CameraState(scale: 1, x: 0.5, y: 0.5)
}

nonisolated struct CursorState: Sendable {
    /// Normalized position in the recording, top-left origin.
    var point: CGPoint
    /// Normalized units per second of the recording.
    var velocity: CGVector
    var opacity: Double
}

/// Pointer and camera paths, worked out once over the whole recording so any frame can be looked up
/// directly: playback, scrubbing and export all see exactly the same motion. Knowing the whole recording
/// lets the smoothing look ahead, so the camera and pointer glide without trailing behind.
nonisolated struct MotionTrack: Sendable {
    static let rate = 60.0
    static let zoomInDuration = 0.85
    static let zoomOutDuration = 0.9

    let clicks: [CursorRecording.Sample]
    private let cursor: [CGPoint]
    private let opacity: [Double]
    private let camera: [CameraState]

    static let empty = MotionTrack(clicks: [], cursor: [], opacity: [], camera: [])

    private init(clicks: [CursorRecording.Sample], cursor: [CGPoint], opacity: [Double], camera: [CameraState]) {
        self.clicks = clicks
        self.cursor = cursor
        self.opacity = opacity
        self.camera = camera
    }

    init(recording: CursorRecording, pointSize: CGSize, duration: Double, zooms: [ZoomSegment], style: RecordingStyle, geometry: CameraGeometry = CameraGeometry()) {
        let count = max(2, Int((duration * Self.rate).rounded(.up)) + 2)
        let w = max(pointSize.width, 1)
        let h = max(pointSize.height, 1)
        let samples = recording.samples.map { CursorRecording.Sample(t: $0.t, x: $0.x / w, y: $0.y / h) }
        let raw = Self.resample(samples, count: count)

        clicks = recording.clicks.map { CursorRecording.Sample(t: $0.t, x: $0.x / w, y: $0.y / h) }
        cursor = style.smoothCursor ? Self.smooth(raw, sigma: 0.09) : raw
        opacity = Self.visibility(raw: raw, hasSamples: !samples.isEmpty, hideIdle: style.hideIdleCursor)
        camera = Self.camera(pointer: raw.map(geometry.framed), zooms: zooms.sorted { $0.start < $1.start }, geometry: geometry)
    }

    // MARK: - Lookup

    func cursor(at t: Double) -> CursorState {
        guard cursor.count > 1 else { return CursorState(point: CGPoint(x: 0.5, y: 0.5), velocity: .zero, opacity: 0) }
        let (i, f) = index(t, count: cursor.count)
        let a = cursor[i], b = cursor[i + 1]
        let point = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        let previous = cursor[max(i - 1, 0)], next = cursor[min(i + 2, cursor.count - 1)]
        let span = Double(min(i + 2, cursor.count - 1) - max(i - 1, 0)) / Self.rate
        let velocity = CGVector(dx: (next.x - previous.x) / span, dy: (next.y - previous.y) / span)
        let alpha = opacity[i] + (opacity[i + 1] - opacity[i]) * f
        return CursorState(point: point, velocity: velocity, opacity: alpha)
    }

    func camera(at t: Double) -> CameraState {
        guard camera.count > 1 else { return .identity }
        let (i, f) = index(t, count: camera.count)
        let a = camera[i], b = camera[i + 1]
        return CameraState(scale: a.scale + (b.scale - a.scale) * f, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    private func index(_ t: Double, count: Int) -> (Int, Double) {
        let position = min(max(t * Self.rate, 0), Double(count - 1) - 0.0001)
        let i = Int(position)
        return (i, position - Double(i))
    }

    // MARK: - Pointer

    /// The raw pointer at a fixed rate, interpolated between samples.
    private static func resample(_ samples: [CursorRecording.Sample], count: Int) -> [CGPoint] {
        guard let first = samples.first else { return Array(repeating: CGPoint(x: 0.5, y: 0.5), count: count) }
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let t = Double(i) / rate
            while j + 1 < samples.count, samples[j + 1].t <= t { j += 1 }
            let a = samples[j]
            if t <= first.t || j + 1 >= samples.count {
                result.append(CGPoint(x: a.x, y: a.y))
            } else {
                let b = samples[j + 1]
                let f = (t - a.t) / max(b.t - a.t, 0.0001)
                result.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return result
    }

    /// A centered Gaussian: it looks as far ahead as it looks back, so the path is smoothed without any delay.
    private static func smooth(_ points: [CGPoint], sigma: Double) -> [CGPoint] {
        let radius = Int((sigma * 3 * rate).rounded(.up))
        guard radius > 0, points.count > 1 else { return points }
        let weights = (-radius...radius).map { k in exp(-0.5 * pow(Double(k) / (sigma * rate), 2)) }
        return points.indices.map { i in
            var x = 0.0, y = 0.0, total = 0.0
            for (offset, weight) in zip(-radius...radius, weights) {
                let j = i + offset
                guard j >= 0, j < points.count else { continue }
                x += points[j].x * weight
                y += points[j].y * weight
                total += weight
            }
            return CGPoint(x: x / total, y: y / total)
        }
    }

    private static func visibility(raw: [CGPoint], hasSamples: Bool, hideIdle: Bool) -> [Double] {
        guard hasSamples else { return Array(repeating: 0, count: raw.count) }
        let idleAfter = 1.6, fade = 0.35
        var lastMove = 0.0
        return raw.indices.map { i in
            let t = Double(i) / rate
            if i > 0, hypot(raw[i].x - raw[i - 1].x, raw[i].y - raw[i - 1].y) > 0.0004 { lastMove = t }
            // Outside the recorded area there is nothing to point at.
            let p = raw[i]
            guard p.x > -0.01, p.x < 1.01, p.y > -0.01, p.y < 1.01 else { return 0 }
            guard hideIdle else { return 1 }
            let idle = t - lastMove
            return idle < idleAfter ? 1 : max(0, 1 - (idle - idleAfter) / fade)
        }
    }

    // MARK: - Camera

    /// Zoom eases in on a fixed curve, so it arrives on time, and eases back out after the zoom ends.
    /// Zooms close together are bridged: the camera stays in and pans instead of bouncing out and back.
    ///
    /// While zoomed, the camera holds still as long as the pointer stays near the middle, follows it in the
    /// direction it moves once it heads away, and is smoothed looking both ways, so it moves with the pointer
    /// rather than after it. Zooming in and out travels in one straight line: the view scales around the one
    /// point that stays put on screen, so it never needs nudging back inside the edges halfway.
    private static func camera(pointer: [CGPoint], zooms: [ZoomSegment], geometry: CameraGeometry) -> [CameraState] {
        let count = pointer.count
        let frames = { (t: Double) in min(max(Int((t * rate).rounded()), 0), count) }

        var bridged = zooms
        for i in bridged.indices.dropLast() where bridged[i + 1].start - bridged[i].end < zoomOutDuration + 0.8 {
            bridged[i].end = max(bridged[i].end, bridged[i + 1].start + zoomInDuration)
        }

        // How far in (as log(scale)), and how far in the current run of bridged zooms goes at most.
        var logScale = [Double](repeating: 0, count: count)
        var heldScale = [Double](repeating: 1, count: count)
        for zoom in bridged {
            let target = log(max(zoom.scale, 1))
            for i in frames(zoom.start)..<frames(zoom.end + zoomOutDuration) {
                let t = Double(i) / rate
                let zoomIn = ease((t - zoom.start) / zoomInDuration)
                let zoomOut = 1 - ease((t - zoom.end) / zoomOutDuration)
                logScale[i] = max(logScale[i], target * min(zoomIn, zoomOut))
            }
        }
        var group = 0
        while group < bridged.count {
            var last = group
            var top = bridged[group].scale
            var end = bridged[group].end
            while last + 1 < bridged.count, bridged[last + 1].start <= end {
                last += 1
                top = max(top, bridged[last].scale)
                end = max(end, bridged[last].end)
            }
            for i in frames(bridged[group].start)..<frames(end + zoomOutDuration) {
                heldScale[i] = max(heldScale[i], top)
            }
            group = last + 1
        }

        // Zooms that start from the full view land centered on the pointer; until then the camera aims there.
        var arrivals: [(first: Int, arrival: Int)] = []
        for zoom in zooms {
            let first = frames(zoom.start)
            let arrival = min(frames(zoom.start + zoomInDuration), count - 1)
            if first < arrival, logScale[first] < 0.05 { arrivals.append((first, arrival)) }
        }
        let landings = Set(arrivals.map(\.arrival))

        // Where to look: the pointer, with a round dead zone around the current focus.
        let aspect = Double(geometry.aspect)
        var targets: [CGPoint] = []
        targets.reserveCapacity(count)
        var anchor = pointer.first ?? CGPoint(x: 0.5, y: 0.5)
        for (i, p) in pointer.enumerated() {
            if landings.contains(i) {
                anchor = p
            } else {
                let radius = 0.17 / heldScale[i]
                let dx = p.x - anchor.x, dy = (p.y - anchor.y) * aspect
                let distance = hypot(dx, dy)
                if distance > radius {
                    let k = (distance - radius) / distance
                    anchor.x += dx * k
                    anchor.y += dy * k / aspect
                }
            }
            targets.append(anchor)
        }
        for (first, arrival) in arrivals {
            for i in first..<arrival { targets[i] = targets[arrival] }
        }

        // Kept inside the recording at full zoom before smoothing, so reaching an edge or a corner
        // rounds off into the same motion instead of stopping one direction first.
        func inside(_ v: Double, half: Double) -> Double {
            half < 0.5 ? min(max(v, half), 1 - half) : 0.5
        }
        let held = targets.indices.map { i in
            CGPoint(
                x: inside(targets[i].x, half: geometry.viewHalf.width / heldScale[i]),
                y: inside(targets[i].y, half: geometry.viewHalf.height / heldScale[i])
            )
        }
        let focus = smooth(held, sigma: 0.32)

        return (0..<count).map { i in
            let scale = exp(logScale[i])
            let top = heldScale[i]
            guard top > 1.0001 else { return .identity }
            // Straight from the full view to the zoomed view, in step with the view's size.
            let progress = min(max((1 - 1 / scale) / (1 - 1 / top), 0), 1)
            return CameraState(scale: scale, x: 0.5 + (focus[i].x - 0.5) * progress, y: 0.5 + (focus[i].y - 0.5) * progress)
        }
    }

    /// Ease in and out (cubic), clamped to 0...1.
    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
