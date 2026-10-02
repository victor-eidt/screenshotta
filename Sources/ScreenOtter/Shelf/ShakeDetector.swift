import AppKit

/// Shaking the pointer left and right while dragging files (from any app) opens a shelf under it.
///
/// Mouse-down monitors need no permission. While the button is held, a timer samples the pointer;
/// it only counts as a file drag once the drag pasteboard changes, so window moves and selections are ignored.
final class ShakeDetector {
    static let shared = ShakeDetector()

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? startMonitoring() : stopMonitoring()
        }
    }

    /// Direction changes needed, each after at least `minimumTravel` points, within `window` seconds.
    private let reversalsNeeded = 3
    private let minimumTravel: CGFloat = 28
    private let window: TimeInterval = 0.75

    private var monitors: [Any] = []
    private var timer: Timer?
    private var dragChangeCount = 0
    private var lastX: CGFloat = 0
    private var direction: CGFloat = 0
    private var travel: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var didFire = false

    private func startMonitoring() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.beginTracking()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.beginTracking()
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        endTracking()
    }

    private func beginTracking() {
        endTracking()
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        lastX = NSEvent.mouseLocation.x
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // .common keeps it firing during drag sessions, which run the loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func endTracking() {
        timer?.invalidate()
        timer = nil
        direction = 0
        travel = 0
        reversals = []
        didFire = false
    }

    private func sample() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endTracking()
            return
        }
        let location = NSEvent.mouseLocation
        let dx = location.x - lastX
        lastX = location.x
        guard dx != 0, !didFire, NSPasteboard(name: .drag).changeCount != dragChangeCount else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let step: CGFloat = dx > 0 ? 1 : -1
        if step == direction {
            travel += abs(dx)
        } else {
            if direction != 0, travel >= minimumTravel {
                reversals.append(now)
            }
            direction = step
            travel = abs(dx)
        }
        reversals.removeAll { now - $0 > window }

        if reversals.count >= reversalsNeeded {
            didFire = true
            guard ShelfManager.shared.shelf(at: location) == nil else { return }
            ShelfManager.shared.newShelf(centeredAt: location)
        }
    }
}
