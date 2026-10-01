import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [EditorWindowController] = []

    private let doc: EditorDocument

    static func open(_ capture: CapturedImage, fileURL: URL?) {
        let controller = EditorWindowController(document: EditorDocument(capture: capture, fileURL: fileURL))
        openEditors.append(controller)
        AppActivation.present(controller.window!)
        controller.positionTrafficLights()
    }

    /// Edits an image file in place. Does nothing if the file isn't a readable image.
    static func open(fileURL url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? Double ?? 72
        open(CapturedImage(image: image, scale: max(1, dpi / 72)), fileURL: url)
    }

    private init(document: EditorDocument) {
        doc = document

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let pointSize = NSSize(width: CGFloat(document.image.width) / document.scale, height: CGFloat(document.image.height) / document.scale)
        let chrome = NSSize(width: 64, height: EditorView.barHeight * 2 + 56)
        let size = NSSize(
            width: min(max(pointSize.width + chrome.width, 860), visible.width * 0.86),
            height: min(max(pointSize.height + chrome.height, 520), visible.height * 0.86)
        )

        let window = EditorWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = document.fileURL?.deletingPathExtension().lastPathComponent ?? "Screenshot"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 860, height: 420)
        window.collectionBehavior.insert(.fullScreenPrimary)

        super.init(window: window)

        let actions = EditorActions(
            delete: { [weak self] in self?.deleteScreenshot() },
            copy: { [weak self] in self?.copy() },
            saveAs: { [weak self] in self?.saveAs() },
            showInFinder: { [weak self] in self?.showInFinder() }
        )
        window.contentView = NSHostingView(rootView: EditorView(doc: document, actions: actions))
        window.onUndo = { [weak document] in document?.undo() }
        window.onRedo = { [weak document] in document?.redo() }
        window.onCopy = { [weak self] in self?.copy() }
        window.onSave = { [weak self] in self?.doc.commit() }
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Actions

    private func copy() {
        doc.applyCrop()
        doc.commit()
    }

    private func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? "Screenshot.png"
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent() ?? Preferences.shared.saveFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.doc.save(to: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func showInFinder() {
        guard let url = doc.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func deleteScreenshot() {
        if let url = doc.fileURL {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        doc.discardChanges()
        window?.close()
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        // Closing means "done": edits go to the file and the clipboard.
        doc.applyCrop()
        if doc.isDirty { doc.commit() }
        Self.openEditors.removeAll { $0 === self }
        AppActivation.windowClosed()
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }

    func positionTrafficLights() {
        window?.centerTrafficLights(inBarOfHeight: EditorView.barHeight)
    }
}

extension NSWindow {
    /// Vertically centers the traffic lights in a top bar taller than the standard title bar.
    func centerTrafficLights(inBarOfHeight height: CGFloat) {
        guard let close = standardWindowButton(.closeButton),
              let titlebarView = close.superview,
              let container = titlebarView.superview,
              !styleMask.contains(.fullScreen)
        else { return }
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = self.frame.height - height
        container.frame = frame
        titlebarView.frame = container.bounds

        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: ((height - button.frame.height) / 2).rounded()))
        }
    }
}

final class EditorWindow: NSWindow {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, flags.contains(.shift)) {
        case ("z", false): onUndo?()
        case ("z", true): onRedo?()
        case ("c", false): onCopy?()
        case ("s", false): onSave?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
