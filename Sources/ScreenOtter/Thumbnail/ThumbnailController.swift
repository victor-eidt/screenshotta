import AppKit

/// The small floating preview in the bottom-right corner after a capture.
final class ThumbnailController {
    static let shared = ThumbnailController()

    private var panel: ThumbnailPanel?
    private var hideTask: Task<Void, Never>?

    private let maxSize = NSSize(width: 168, height: 118)
    private let margin: CGFloat = 16

    func show(_ capture: CapturedImage, fileURL: URL?, on screen: NSScreen?) {
        dismiss(animated: false)
        guard let screen = screen ?? NSScreen.main else { return }

        let aspect = CGFloat(capture.image.width) / CGFloat(capture.image.height)
        var size = NSSize(width: maxSize.width, height: maxSize.width / aspect)
        if size.height > maxSize.height {
            size = NSSize(width: maxSize.height * aspect, height: maxSize.height)
        }
        size = NSSize(width: max(size.width, 48).rounded(), height: max(size.height, 36).rounded())

        let visible = screen.visibleFrame
        let target = NSRect(x: visible.maxX - size.width - margin, y: visible.minY + margin, width: size.width, height: size.height)
        let start = target.offsetBy(dx: size.width + margin * 2, dy: 0)

        let panel = ThumbnailPanel(frame: start, capture: capture, fileURL: fileURL)
        panel.thumbnail.onOpen = { [weak self] in
            self?.dismiss(animated: false)
            EditorWindowController.open(capture, fileURL: fileURL)
        }
        panel.thumbnail.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        panel.thumbnail.onAddToShelf = { [weak self] in
            guard let url = fileURL ?? CaptureOutput.temporaryFile(for: capture) else { return }
            ShelfManager.shared.add([url])
            self?.dismiss(animated: true)
        }
        panel.thumbnail.onHover = { [weak self] hovering in
            if hovering { self?.hideTask?.cancel() } else { self?.scheduleHide() }
        }
        self.panel = panel

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    func dismiss(animated: Bool) {
        hideTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: panel.frame.width + margin * 2, dy: 0), display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let delay = Preferences.shared.thumbnailDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }
}

final class ThumbnailPanel: NSPanel {
    let thumbnail: ThumbnailView

    init(frame: NSRect, capture: CapturedImage, fileURL: URL?) {
        thumbnail = ThumbnailView(frame: NSRect(origin: .zero, size: frame.size), capture: capture, fileURL: fileURL)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = thumbnail
    }
}

final class ThumbnailView: NSView, NSDraggingSource {
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onAddToShelf: (() -> Void)?

    private let capture: CapturedImage
    private let fileURL: URL?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false
    private var swipeDistance: CGFloat = 0
    private let closeButton = NSButton()
    private let shelfButton = NSButton()

    init(frame: NSRect, capture: CapturedImage, fileURL: URL?) {
        self.capture = capture
        self.fileURL = fileURL
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer?.contents = capture.image
        layer?.contentsGravity = .resizeAspectFill

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [.white, NSColor(white: 0, alpha: 0.55)])))
        closeButton.frame = NSRect(x: 5, y: frame.height - 25, width: 20, height: 20)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.isHidden = true
        addSubview(closeButton)

        shelfButton.bezelStyle = .regularSquare
        shelfButton.isBordered = false
        shelfButton.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Add to Shelf")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        shelfButton.contentTintColor = .white
        shelfButton.wantsLayer = true
        shelfButton.layer?.cornerRadius = 10
        shelfButton.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        shelfButton.frame = NSRect(x: frame.width - 25, y: frame.height - 25, width: 20, height: 20)
        shelfButton.autoresizingMask = [.minXMargin, .minYMargin]
        shelfButton.target = self
        shelfButton.action = #selector(addToShelf)
        shelfButton.toolTip = "Add to Shelf"
        shelfButton.isHidden = true
        addSubview(shelfButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        shelfButton.isHidden = false
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        shelfButton.isHidden = true
        onHover?(false)
    }

    @objc private func close() {
        onDismiss?()
    }

    @objc private func addToShelf() {
        onAddToShelf?()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didDrag else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        didDrag = true
        guard let url = fileURL ?? CaptureOutput.temporaryFile(for: capture) else { return }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(cgImage: capture.image, size: bounds.size)
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
        window?.alphaValue = 0.35
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if !didDrag { onOpen?() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began { swipeDistance = 0 }
        swipeDistance += event.scrollingDeltaX
        if abs(swipeDistance) > 40 {
            swipeDistance = 0
            onDismiss?()
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        window?.alphaValue = 1
        if operation != [] {
            onDismiss?()
        }
    }
}
