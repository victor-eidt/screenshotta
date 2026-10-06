import AppKit
import Carbon.HIToolbox
import SwiftUI

final class RecordingEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [RecordingEditorWindowController] = []

    private let doc: RecordingDocument

    /// Keeps an open editor's title in step with a rename in the Drafts window.
    static func titleChanged(for project: RecordingProject, to title: String) {
        guard let editor = openEditors.first(where: { $0.doc.project.folder == project.folder }) else { return }
        editor.doc.titleChanged(to: title)
        editor.window?.title = title
    }

    static func close(_ project: RecordingProject) {
        openEditors.first { $0.doc.project.folder == project.folder }?.window?.close()
    }

    static func open(_ project: RecordingProject) {
        if let existing = openEditors.first(where: { $0.doc.project.folder == project.folder }) {
            AppActivation.present(existing.window!)
            return
        }
        Task {
            do {
                let doc = try await RecordingDocument.load(project)
                let controller = RecordingEditorWindowController(document: doc)
                openEditors.append(controller)
                AppActivation.present(controller.window!)
                controller.positionTrafficLights()
            } catch {
                CaptureOutput.presentError(error)
            }
        }
    }

    private init(document: RecordingDocument) {
        doc = document

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: min(1360, visible.width * 0.9), height: min(880, visible.height * 0.9))
        let window = RecordingEditorWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.barHeight = RecordingEditorView.barHeight
        window.title = document.metadata.title
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.075, alpha: 1)
        window.minSize = NSSize(width: 1040, height: 660)
        window.collectionBehavior.insert(.fullScreenPrimary)

        super.init(window: window)

        let actions = RecordingEditorActions(
            delete: { [weak self] in self?.deleteRecording() },
            showDrafts: { DraftsWindowController.shared.show() },
            showInFinder: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            addToShelf: { url in ShelfManager.shared.add([url]) }
        )
        window.contentView = NSHostingView(rootView: RecordingEditorView(doc: document, actions: actions))
        window.doc = document
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func deleteRecording() {
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "The recording and its edits move to the Trash. Exported videos are kept."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.doc.close()
            try? FileManager.default.trashItem(at: self.doc.project.folder, resultingItemURL: nil)
            self.window?.close()
            DraftsLibrary.shared.reload()
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        doc.close()
        Self.openEditors.removeAll { $0 === self }
        DraftsLibrary.shared.reload()
        AppActivation.windowClosed()
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }

    private func positionTrafficLights() {
        window?.centerTrafficLights(inBarOfHeight: RecordingEditorView.barHeight)
    }
}

/// Editor shortcuts that work wherever focus is, except while typing in a text field.
final class RecordingEditorWindow: TallTitleBarWindow {
    weak var doc: RecordingDocument?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let doc, flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, flags.contains(.shift)) {
        case ("z", false): doc.undo()
        case ("z", true): doc.redo()
        case ("e", false): doc.startExport()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let doc, !(firstResponder is NSText), handleKey(event, doc: doc) {
            return
        }
        super.sendEvent(event)
    }

    private func handleKey(_ event: NSEvent, doc: RecordingDocument) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Space: doc.togglePlayback()
        case kVK_Delete, kVK_ForwardDelete: doc.deleteSelection()
        case kVK_LeftArrow: doc.step(frames: event.modifierFlags.contains(.shift) ? -60 : -1)
        case kVK_RightArrow: doc.step(frames: event.modifierFlags.contains(.shift) ? 60 : 1)
        case kVK_Escape: doc.selection = nil
        case kVK_ANSI_S: doc.splitAtPlayhead()
        default: return false
        }
        return true
    }
}
