import AppKit
import CoreMedia

/// Samples the pointer and clicks while recording, in the recorded content's own coordinates.
final class CursorTracker {
    /// Maps a global Cocoa point to points from the content's top-left corner.
    private let locate: (CGPoint) -> CGPoint?
    private var timer: Timer?
    private var monitors: [Any] = []
    private var samples: [CursorRecording.Sample] = []
    private var clicks: [CursorRecording.Sample] = []

    init(locate: @escaping (CGPoint) -> CGPoint?) {
        self.locate = locate
    }

    static func hostTime() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func start() {
        sample()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // Common modes, so sampling goes on while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.click() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.click()
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Stops and returns the track with times relative to `start` (the first video frame), cut to `duration`.
    func stop(start: Double, duration: Double) -> CursorRecording {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()

        func relative(_ list: [CursorRecording.Sample]) -> [CursorRecording.Sample] {
            list.map { CursorRecording.Sample(t: $0.t - start, x: $0.x, y: $0.y) }
        }
        var moves = relative(samples)
        // Keep the last sample before the first frame, so the pointer is known from the very start.
        if let firstInside = moves.firstIndex(where: { $0.t >= 0 }), firstInside > 0 {
            moves.removeFirst(firstInside - 1)
            moves[0].t = 0
        }
        moves.removeAll { $0.t > duration + 0.1 }
        let presses = relative(clicks).filter { $0.t >= 0 && $0.t <= duration }
        return CursorRecording(samples: moves, clicks: presses)
    }

    private func sample() {
        guard let point = locate(NSEvent.mouseLocation) else { return }
        samples.append(CursorRecording.Sample(t: Self.hostTime(), x: point.x, y: point.y))
    }

    private func click() {
        guard let point = locate(NSEvent.mouseLocation) else { return }
        clicks.append(CursorRecording.Sample(t: Self.hostTime(), x: point.x, y: point.y))
    }
}
