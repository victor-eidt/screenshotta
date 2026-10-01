import CoreGraphics
import Foundation

/// Finds the moments worth zooming into: clusters of clicks.
nonisolated enum AutoZoom {
    /// Zoom starts this long before the first click of a cluster, so it has arrived by the click.
    private static let lead = 0.8
    /// And holds this long after the last one.
    private static let tail = 1.8
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

/// Where the camera looks: a zoom factor and the focus point (normalized, top-left origin).
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

/// Pointer and camera paths, simulated once over the whole recording so any frame can be looked up
/// directly: playback, scrubbing and export all see exactly the same motion.
nonisolated struct MotionTrack: Sendable {
    static let rate = 60.0

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

    init(recording: CursorRecording, pointSize: CGSize, duration: Double, zooms: [ZoomSegment], style: RecordingStyle) {
        let count = max(2, Int((duration * Self.rate).rounded(.up)) + 2)
        let w = max(pointSize.width, 1)
        let h = max(pointSize.height, 1)
        let samples = recording.samples.map { CursorRecording.Sample(t: $0.t, x: $0.x / w, y: $0.y / h) }
        let raw = Self.resample(samples, count: count)
        let cursor = style.smoothCursor ? Self.smooth(raw) : raw

        clicks = recording.clicks.map { CursorRecording.Sample(t: $0.t, x: $0.x / w, y: $0.y / h) }
        self.cursor = cursor
        opacity = Self.visibility(raw: raw, hasSamples: !samples.isEmpty, hideIdle: style.hideIdleCursor)
        camera = Self.simulateCamera(cursor: cursor, zooms: zooms.sorted { $0.start < $1.start })
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

    // MARK: - Building

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

    /// A slightly underdamped spring chasing the real pointer: removes the jitter and makes
    /// every movement glide, while still landing where the pointer actually stopped.
    private static func smooth(_ raw: [CGPoint]) -> [CGPoint] {
        guard var position = raw.first else { return raw }
        var velocity = CGVector.zero
        let omega = 15.0, zeta = 0.86, substeps = 4
        let dt = 1 / rate / Double(substeps)
        var result: [CGPoint] = []
        result.reserveCapacity(raw.count)
        for target in raw {
            for _ in 0..<substeps {
                let ax = omega * omega * (target.x - position.x) - 2 * zeta * omega * velocity.dx
                let ay = omega * omega * (target.y - position.y) - 2 * zeta * omega * velocity.dy
                velocity.dx += ax * dt
                velocity.dy += ay * dt
                position.x += velocity.dx * dt
                position.y += velocity.dy * dt
            }
            result.append(position)
        }
        return result
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

    /// Critically damped springs on zoom (in log space, so zooming feels even) and on the focus point.
    /// While zoomed, the focus only moves once the pointer nears the edge of the view.
    private static func simulateCamera(cursor: [CGPoint], zooms: [ZoomSegment]) -> [CameraState] {
        var logScale = 0.0, scaleVelocity = 0.0
        var focus = CGPoint(x: 0.5, y: 0.5), focusVelocity = CGVector.zero
        var target = focus
        var activeZoom: UUID?
        let scaleOmega = 6.2, focusOmega = 5.0, substeps = 4
        let dt = 1 / rate / Double(substeps)
        var zoomIndex = 0

        var result: [CameraState] = []
        result.reserveCapacity(cursor.count)
        for (i, pointer) in cursor.enumerated() {
            let t = Double(i) / rate
            while zoomIndex < zooms.count, zooms[zoomIndex].end <= t { zoomIndex += 1 }
            let zoom = zoomIndex < zooms.count && zooms[zoomIndex].start <= t ? zooms[zoomIndex] : nil

            let targetScale = zoom?.scale ?? 1
            if let zoom {
                let half = 0.5 / targetScale
                if activeZoom != zoom.id { target = pointer }
                let margin = half * 0.5
                target.x = min(max(target.x, pointer.x - margin), pointer.x + margin)
                target.y = min(max(target.y, pointer.y - margin), pointer.y + margin)
                target.x = min(max(target.x, half), 1 - half)
                target.y = min(max(target.y, half), 1 - half)
            } else {
                target = CGPoint(x: 0.5, y: 0.5)
            }
            activeZoom = zoom?.id

            let targetLog = log(targetScale)
            for _ in 0..<substeps {
                scaleVelocity += (scaleOmega * scaleOmega * (targetLog - logScale) - 2 * scaleOmega * scaleVelocity) * dt
                logScale += scaleVelocity * dt
                focusVelocity.dx += (focusOmega * focusOmega * (target.x - focus.x) - 2 * focusOmega * focusVelocity.dx) * dt
                focusVelocity.dy += (focusOmega * focusOmega * (target.y - focus.y) - 2 * focusOmega * focusVelocity.dy) * dt
                focus.x += focusVelocity.dx * dt
                focus.y += focusVelocity.dy * dt
            }
            result.append(CameraState(scale: max(1, exp(logScale)), x: focus.x, y: focus.y))
        }
        return result
    }
}
