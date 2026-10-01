import AppKit
import SwiftUI

/// One floating shelf: a small glass panel that expands into a file browser.
final class ShelfController: NSObject, ObservableObject {
    static let collapsedSize = NSSize(width: 184, height: 204)
    static let expandedSize = NSSize(width: 468, height: 348)
    static let cornerRadius: CGFloat = 28
    /// Transparent room around the glass for its shadow. Without it the window edge clips the shadow
    /// into a visible rectangle, which macOS then outlines when the panel becomes key.
    private static let shadowMargin: CGFloat = 36

    let shelf: Shelf
    @Published private(set) var isExpanded = false
    @Published private(set) var isDropTargeted = false
    private let panel: ShelfPanel

    init(shelf: Shelf) {
        self.shelf = shelf
        panel = ShelfPanel(contentRect: NSRect(origin: .zero, size: Self.collapsedSize))
        super.init()
        let hosting = NSHostingView(rootView: ShelfView(shelf: shelf, controller: self))
        hosting.sizingOptions = []
        let glass = GlassBackground.make(content: hosting, cornerRadius: Self.cornerRadius)
        let container = ShelfDropView(frame: NSRect(origin: .zero, size: Self.collapsedSize))
        glass.frame = container.bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        container.onTargetedChange = { [weak self] in self?.isDropTargeted = $0 }
        container.onDrop = { [weak self] urls in self?.shelf.add(urls) }
        container.landingRect = { [weak glass] in
            // Where dropped files fly to: the middle of the stack.
            guard let glass else { return .zero }
            return NSRect(x: glass.frame.midX - 32, y: glass.frame.midY - 24, width: 64, height: 48)
        }
        panel.contentView = container
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
    }

    /// The glass, in screen coordinates.
    var frame: NSRect { Self.glassFrame(panel.frame) }

    private static func panelFrame(_ glass: NSRect) -> NSRect {
        glass.insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }

    private static func glassFrame(_ panel: NSRect) -> NSRect {
        panel.insetBy(dx: shadowMargin, dy: shadowMargin)
    }

    // MARK: - Window

    func show(centeredAt point: NSPoint?, cascadeIndex: Int) {
        let size = Self.collapsedSize
        let screen = point.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin: NSPoint
        if let point {
            origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        } else {
            let offset = CGFloat(cascadeIndex % 6) * 28
            origin = NSPoint(x: visible.maxX - size.width - 24 - offset, y: visible.midY - size.height / 2 - offset)
        }
        let glass = Self.clamp(NSRect(origin: origin, size: size), to: visible)
        panel.setFrame(Self.panelFrame(glass), display: false)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        let size = expanded ? Self.expandedSize : Self.collapsedSize
        let current = frame
        // The top-left corner stays put, unless the bigger panel would leave the screen.
        var target = NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
        if let visible = panel.screen?.visibleFrame {
            target = Self.clamp(target, to: visible)
        }
        if !expanded { shelf.selection = [] }
        withAnimation(.smooth(duration: 0.28)) {
            isExpanded = expanded
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(Self.panelFrame(target), display: true)
        }
    }

    func close() {
        ShelfManager.shared.closed(self)
        let panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            // The hosting view holds this controller; dropping it breaks the cycle.
            panel.contentView = nil
        }
    }

    private static func clamp(_ rect: NSRect, to bounds: NSRect) -> NSRect {
        var rect = rect
        rect.origin.x = min(max(rect.minX, bounds.minX + 8), bounds.maxX - rect.width - 8)
        rect.origin.y = min(max(rect.minY, bounds.minY + 8), bounds.maxY - rect.height - 8)
        return rect
    }

    // MARK: - Actions

    func open(_ items: [ShelfItem]) {
        items.forEach { NSWorkspace.shared.open($0.url) }
    }

    func reveal(_ items: [ShelfItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    /// Files on the pasteboard: pasting into Finder copies them, chat apps attach them.
    func copy(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { $0.url as NSURL })
    }

    func dragEnded() {
        // Dragging to the Trash deletes the files; they leave the shelf with them.
        shelf.removeMissing()
    }

    /// The items a menu or key command acts on: the selection, or everything when nothing is selected.
    private var targetItems: [ShelfItem] {
        shelf.selection.isEmpty ? shelf.items : shelf.selectedItems
    }

    func showShelfMenu() {
        let menu = NSMenu()
        if !shelf.isEmpty {
            menu.addItem(ClosureMenuItem("Show Files", symbol: "square.grid.2x2") { [weak self] in self?.setExpanded(true) })
            menu.addItem(ClosureMenuItem("Reveal in Finder", symbol: "folder") { [weak self] in
                guard let self else { return }
                reveal(shelf.items)
            })
            menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc") { [weak self] in
                guard let self else { return }
                copy(shelf.items)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Close Shelf", symbol: "xmark") { [weak self] in self?.close() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func itemMenu() -> NSMenu {
        let items = shelf.selectedItems
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak self] in self?.open(items) })
        if items.count == 1, let item = items.first, item.isImage {
            menu.addItem(ClosureMenuItem("Edit in Screenshotta", symbol: "pencil.tip.crop.circle") {
                EditorWindowController.open(fileURL: item.url)
            })
        }
        menu.addItem(ClosureMenuItem("Reveal in Finder", symbol: "folder") { [weak self] in self?.reveal(items) })
        menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc") { [weak self] in self?.copy(items) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from Shelf", symbol: "minus.circle") { [weak self] in
            self?.shelf.remove(Set(items.map(\.id)))
        })
        return menu
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                if !isExpanded { setExpanded(true) }
                shelf.selectAll()
            case "c": copy(targetItems)
            case "w": close()
            case "o": open(shelf.selectedItems)
            default: return false
            }
            return true
        }
        switch Int(event.keyCode) {
        case 51, 117: // Delete, Forward Delete
            shelf.remove(shelf.selection)
        case 53: // Escape
            if !shelf.selection.isEmpty { shelf.selection = [] } else if isExpanded { setExpanded(false) }
        case 36: // Return
            open(shelf.selectedItems)
        default:
            return false
        }
        return true
    }
}

final class ShelfPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own shadow (see ShelfController.shadowMargin).
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Becomes key (for Delete, Esc, ⌘A…) without activating the app, so the app you're dragging from stays in front.
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Liquid Glass on macOS 26, a HUD blur before that.
enum GlassBackground {
    static func make(content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: cornerRadius)
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        handler()
    }
}
