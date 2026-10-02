import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, output, windowStyle, recording, shelf, shortcuts, permissions, about

    var id: String { rawValue }

    /// The sidebar's groups, top to bottom.
    static let groups: [[SettingsPane]] = [
        [.general, .output, .windowStyle, .recording, .shelf],
        [.shortcuts, .permissions],
        [.about],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .output: "After Capture"
        case .windowStyle: "Window Style"
        case .recording: "Recording"
        case .shelf: "Shelf"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Capture and record from anywhere, right from the menu bar."
        case .output: "Where screenshots go, and the preview that follows them."
        case .windowStyle: "How window screenshots look: background, frame and shadow."
        case .recording: "Screen recordings, and the drafts they leave behind."
        case .shelf: "A floating spot to hold files for a moment."
        case .shortcuts: "Global shortcuts, active in any app."
        case .permissions: "What macOS needs to allow before ScreenOtter can capture."
        case .about: Brand.tagline
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .output: "photo.on.rectangle.angled"
        case .windowStyle: "macwindow"
        case .recording: "record.circle.fill"
        case .shelf: "tray.2.fill"
        case .shortcuts: "command"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(white: 0.55)
        case .output: Brand.accent
        case .windowStyle: .purple
        case .recording: .red
        case .shelf: .orange
        case .shortcuts: .teal
        case .permissions: .green
        case .about: .indigo
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane = .general
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let model = SettingsModel()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "ScreenOtter Settings"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 840, height: 600))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }
        AppActivation.present(window!)
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.windowClosed()
    }
}
