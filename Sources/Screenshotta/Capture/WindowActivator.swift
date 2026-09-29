import AppKit

/// Brings a window to the front before capturing it, so it renders as the key window
/// (colored traffic lights instead of gray ones).
enum WindowActivator {
    static func bringToFront(_ candidate: WindowCandidate) async {
        if Permissions.accessibilityGranted {
            raise(candidate)
        }
        NSRunningApplication(processIdentifier: candidate.pid)?.activate()
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != candidate.pid {
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Give the app a moment to redraw its window as active.
        try? await Task.sleep(for: .milliseconds(220))
    }

    private static func raise(_ candidate: WindowCandidate) {
        let app = AXUIElementCreateApplication(candidate.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }

        for window in windows {
            guard let frame = frame(of: window),
                  abs(frame.minX - candidate.quartzFrame.minX) < 2,
                  abs(frame.minY - candidate.quartzFrame.minY) < 2,
                  abs(frame.width - candidate.quartzFrame.width) < 2,
                  abs(frame.height - candidate.quartzFrame.height) < 2
            else { continue }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
