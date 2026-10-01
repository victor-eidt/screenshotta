import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Handles clicks and drags on shelf files in AppKit: SwiftUI can't drag several files out at once.
struct FileDragArea: NSViewRepresentable {
    var items: () -> [ShelfItem]
    var onMouseDown: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// A click that didn't become a drag.
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menu: (() -> NSMenu)?
    var onDragEnded: () -> Void = {}

    func makeNSView(context: Context) -> FileDragView {
        FileDragView()
    }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.config = self
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var config: FileDragArea?
    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
        config?.onMouseDown(event.modifierFlags)
        if event.clickCount == 2 {
            config?.onDoubleClick()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !didDrag, let config else { return }
        let start = down.locationInWindow
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        didDrag = true

        let items = config.items()
        guard !items.isEmpty else { return }
        let anchor = convert(start, from: nil)
        let draggingItems = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let image = item.thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path)
            let size = Self.fit(image.size, in: NSSize(width: 96, height: 96))
            let shift = CGFloat(min(index, 4)) * 4
            let frame = NSRect(x: anchor.x - size.width / 2 + shift, y: anchor.y - size.height / 2 - shift, width: size.width, height: size.height)
            draggingItem.setDraggingFrame(frame, contents: image)
            return draggingItem
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        if draggingItems.count > 1 {
            session.draggingFormation = .pile
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        if !didDrag, event.clickCount < 2 {
            config?.onClick(event.modifierFlags)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let config, let menu = config.menu else { return nil }
        // Like Finder: right-clicking an unselected file selects it first.
        config.onMouseDown([])
        return menu()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: dropping into a folder never moves the original out from under the shelf. The Trash may delete.
        context == .withinApplication ? .copy : [.copy, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        config?.onDragEnded()
    }

    private static func fit(_ size: NSSize, in box: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height, 1)
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// The panel's background: drag to move the shelf, click to clear the selection.
struct WindowDragArea: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> WindowDragView {
        WindowDragView()
    }

    func updateNSView(_ view: WindowDragView, context: Context) {
        view.onClick = onClick
    }
}

final class WindowDragView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = window.frame.origin
        window.performDrag(with: event)
        if window.frame.origin == origin {
            onClick?()
        }
    }
}

/// The shelf panel's root view and drop target. Reading the pasteboard synchronously (unlike SwiftUI's
/// `onDrop`) lets the drop finish at once, and the dragged images fly into the stack instead of hovering.
final class ShelfDropView: NSView {
    var onTargetedChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    /// Where the dragged images land, in this view's coordinates.
    var landingRect: (() -> NSRect)?

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]
    private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + Self.imageTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        // Files dragged out of this same shelf would only land back where they came from.
        if let source = sender.draggingSource as? NSView, source.window === window { return [] }
        let pasteboard = sender.draggingPasteboard
        let readable = pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly)
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pasteboard.availableType(from: Self.imageTypes) != nil
        return readable ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = operation(for: sender)
        onTargetedChange?(operation != [])
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.animatesToDestination = true
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly) as? [URL], !urls.isEmpty {
            onDrop?(urls)
        } else if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            // Photos, Mail and some browsers hand over files that don't exist yet.
            let folder = ShelfManager.droppedFilesFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { [weak self] url, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated { self?.onDrop?([url]) }
                }
            }
        } else if let type = pasteboard.availableType(from: Self.imageTypes),
                  let data = pasteboard.data(forType: type),
                  let url = ShelfManager.storeDroppedImage(data) {
            onDrop?([url])
        } else {
            return false
        }

        // Shrink every dragged image into the stack.
        let target = landingRect?() ?? NSRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
            let shift = CGFloat(min(index, 3)) * 3
            item.draggingFrame = target.offsetBy(dx: shift, dy: -shift)
        }
        return true
    }
}
