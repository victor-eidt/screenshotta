import AppKit
import Carbon.HIToolbox

struct WindowCandidate: Equatable {
    let id: CGWindowID
    let pid: pid_t
    /// Global Cocoa coordinates (bottom-left origin).
    let frame: CGRect
    /// Global Quartz coordinates (top-left origin), as the Accessibility API reports them.
    let quartzFrame: CGRect

    /// The screen showing most of the window: the one holding its center.
    var screen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }
}

/// Runs one screenshot selection: a transparent overlay panel on every screen.
final class SelectionController {
    static let shared = SelectionController()

    enum Mode {
        case area
        case window
    }

    /// A screenshot, what to record, or where to read text.
    enum Purpose {
        case screenshot
        case recording
        case text
    }

    private(set) var mode: Mode = .area
    private(set) var purpose: Purpose = .screenshot
    private(set) var candidates: [WindowCandidate] = []
    private var panels: [OverlayPanel] = []
    private var isCapturing = false

    var hovered: WindowCandidate? {
        didSet {
            if hovered != oldValue { redrawAll() }
        }
    }

    var isActive: Bool { !panels.isEmpty }

    func begin(_ mode: Mode, purpose: Purpose = .screenshot) {
        if isActive {
            if self.purpose != purpose {
                self.purpose = purpose
                applyCursor()
                updateOptionsBar()
                redrawAll()
            }
            if self.mode != mode { toggleMode() }
            return
        }
        guard !isCapturing else { return }
        guard Permissions.screenRecordingGranted else {
            CGRequestScreenCaptureAccess()
            SettingsWindowController.shared.show(.permissions)
            return
        }

        self.mode = mode
        self.purpose = purpose
        candidates = Self.onScreenWindows()
        ThumbnailController.shared.dismiss(animated: false)

        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, controller: self)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        let mouse = NSEvent.mouseLocation

        // The overlay never becomes key or active: that would turn the target window's traffic lights gray.
        // Esc and Space work through temporary global hotkeys instead.
        let hotKeys = HotKeyManager.shared
        hotKeys.register(.escape, Shortcut(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)) { [weak self] in self?.cancel() }
        hotKeys.register(.space, Shortcut(keyCode: UInt32(kVK_Space), carbonModifiers: 0)) { [weak self] in self?.toggleMode() }

        updateHover(at: mouse)
        applyCursor()
        updateOptionsBar()
    }

    /// Recording shows its audio options at the bottom of the screen with the pointer.
    private func updateOptionsBar() {
        if purpose == .recording { RecordingOptionsBar.shared.show() } else { RecordingOptionsBar.shared.hide() }
    }

    func toggleMode() {
        mode = mode == .area ? .window : .area
        hovered = nil
        panels.forEach { $0.overlay.resetDrag() }
        updateHover(at: NSEvent.mouseLocation)
        applyCursor()
        redrawAll()
    }

    func cancel() {
        tearDown()
    }

    func applyCursor() {
        switch mode {
        case .area: NSCursor.crosshair.set()
        // No photo is taken when reading text, so no camera.
        case .window: (purpose == .text ? Cursors.textViewfinder : Cursors.camera).set()
        }
    }

    func updateHover(at point: CGPoint) {
        if purpose == .recording { RecordingOptionsBar.shared.follow(point) }
        guard mode == .window else { return }
        hovered = candidates.first { $0.frame.contains(point) }
    }

    // MARK: - Finishing

    func finishArea(_ rect: CGRect, on screen: NSScreen) {
        tearDown()
        if purpose == .recording {
            RecordingController.shared.start(.area(rect, screen))
            return
        }
        let purpose = purpose
        isCapturing = true
        Task {
            defer { isCapturing = false }
            if purpose == .text {
                await TextCapture.captureArea(rect, on: screen)
                return
            }
            do {
                let capture = try await CaptureService.captureArea(rect, on: screen)
                CaptureOutput.deliver(capture, screen: screen)
            } catch {
                CaptureOutput.presentError(error)
            }
        }
    }

    func finishWindow(_ candidate: WindowCandidate) {
        let isFrontmost = candidates.first { $0.pid == candidate.pid } == candidate
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.pid
        let purpose = purpose
        tearDown()
        isCapturing = true
        Task {
            defer { isCapturing = false }
            if purpose == .text {
                // Window content is captured even when covered, so there's no need to raise it.
                await TextCapture.captureWindow(candidate)
                return
            }
            if Preferences.shared.bringWindowToFront, !isFrontmost {
                await WindowActivator.bringToFront(candidate)
            }
            if purpose == .recording {
                RecordingController.shared.start(.window(candidate))
                return
            }
            do {
                let capture = try await CaptureService.captureStyledWindow(candidate.id)
                CaptureOutput.deliver(capture, screen: candidate.screen)
            } catch {
                CaptureOutput.presentError(error)
            }
        }
    }

    /// Recording only: a click without a drag records the whole screen.
    func finishDisplay(_ screen: NSScreen) {
        tearDown()
        RecordingController.shared.start(.display(screen))
    }

    private func tearDown() {
        HotKeyManager.shared.unregister(.escape)
        HotKeyManager.shared.unregister(.space)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        RecordingOptionsBar.shared.hide()
        hovered = nil
        NSCursor.arrow.set()
    }

    private func redrawAll() {
        panels.forEach { $0.overlay.needsDisplay = true }
    }

    // MARK: - Window list

    /// Normal app windows, front to back, ours included (our panels sit above the normal window layer).
    private static func onScreenWindows() -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            let cocoa = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowCandidate(id: number, pid: pid, frame: cocoa, quartzFrame: bounds)
        }
    }
}

// MARK: - Overlay

final class OverlayPanel: NSPanel {
    let overlay: OverlayView

    init(screen: NSScreen, controller: SelectionController) {
        overlay = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.controller = controller
        overlay.targetScreen = screen
        contentView = overlay
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
}

final class OverlayView: NSView {
    weak var controller: SelectionController?
    var targetScreen: NSScreen!

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resetDrag() {
        dragStart = nil
        dragCurrent = nil
    }

    private var selectionRect: NSRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = NSRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        )
        // On the device pixel grid, so the border is crisp and matches the captured pixels.
        return backingAlignedRect(rect, options: .alignAllEdgesNearest)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) { controller?.applyCursor() }
    override func mouseEntered(with event: NSEvent) { controller?.applyCursor() }

    override func mouseMoved(with event: NSEvent) {
        controller?.applyCursor()
        controller?.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        switch controller.mode {
        case .area:
            let point = convert(event.locationInWindow, from: nil)
            dragStart = point
            dragCurrent = point
        case .window:
            controller.updateHover(at: NSEvent.mouseLocation)
            if let window = controller.hovered {
                controller.finishWindow(window)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        controller?.applyCursor()
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = NSPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller, controller.mode == .area, let rect = selectionRect else { return }
        resetDrag()
        needsDisplay = true
        guard rect.width >= 2, rect.height >= 2 else {
            if controller.purpose == .recording { controller.finishDisplay(targetScreen) }
            return
        }
        let global = rect.offsetBy(dx: targetScreen.frame.minX, dy: targetScreen.frame.minY)
        controller.finishArea(global, on: targetScreen)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }


    override func draw(_ dirtyRect: NSRect) {
        // A near-invisible fill keeps every pixel clickable.
        NSColor(white: 0, alpha: 0.004).setFill()
        bounds.fill(using: .copy)

        guard let controller else { return }
        switch controller.mode {
        case .area:
            if let rect = selectionRect {
                drawSelection(rect)
            }
        case .window:
            if let hovered = controller.hovered {
                drawHighlight(hovered.frame.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY), recording: controller.purpose == .recording)
            }
        }
        if controller.purpose != .screenshot, dragStart == nil {
            drawHint(controller.purpose, controller.mode)
        }
    }

    private static let textHintSymbol = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white])))

    /// Recording and text capture say what a drag or a click will do, since it isn't a plain screenshot.
    private func drawHint(_ purpose: SelectionController.Purpose, _ mode: SelectionController.Mode) {
        let text = switch (purpose, mode) {
        case (.text, .area): "Drag over text to copy it  ·  Space for a window  ·  Esc to cancel"
        case (.text, .window): "Click a window to copy its text  ·  Space for an area  ·  Esc to cancel"
        case (_, .area): "Drag to record an area  ·  Click to record the whole screen  ·  Space for a window  ·  Esc to cancel"
        case (_, .window): "Click a window to record it  ·  Space for an area  ·  Esc to cancel"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let leading: CGFloat = purpose == .text ? 32 : 26
        let pill = NSRect(x: (bounds.width - size.width - leading - 18) / 2, y: bounds.height - size.height - 64, width: size.width + leading + 18, height: size.height + 16)
        NSColor(white: 0.08, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        if purpose == .text, let symbol = Self.textHintSymbol {
            let symbolRect = NSRect(x: pill.minX + 12, y: pill.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: symbolRect)
        } else {
            let dot = NSRect(x: pill.minX + 13, y: pill.midY - 3.5, width: 7, height: 7)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        string.draw(at: NSPoint(x: pill.minX + leading, y: pill.minY + 8))
    }

    private func drawSelection(_ rect: NSRect) {
        NSColor(white: 0.45, alpha: 0.22).setFill()
        rect.fill(using: .sourceOver)

        let outer = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 1
        NSColor(white: 0, alpha: 0.35).setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        NSColor(white: 1, alpha: 0.9).setStroke()
        inner.stroke()

        // Pixel sizes mean nothing when reading text.
        if let current = dragCurrent, controller?.purpose != .text {
            drawPill("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))", near: current)
        }
    }

    private func drawHighlight(_ rect: NSRect, recording: Bool) {
        let tint: NSColor = recording ? .systemRed : .systemBlue
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        tint.withAlphaComponent(0.22).setFill()
        path.fill()
        path.lineWidth = 2
        tint.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }

    private func drawPill(_ text: String, near point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var pill = NSRect(x: point.x + 14, y: point.y - size.height - 20, width: size.width + 14, height: size.height + 6)
        if pill.maxX > bounds.maxX - 6 { pill.origin.x = point.x - pill.width - 14 }
        if pill.minY < bounds.minY + 6 { pill.origin.y = point.y + 14 }
        NSColor(white: 0.08, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3))
    }
}
