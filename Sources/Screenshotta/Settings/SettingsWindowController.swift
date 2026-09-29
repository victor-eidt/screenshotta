import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, output, windowStyle, shortcuts, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .output: "After Capture"
        case .windowStyle: "Window Style"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .output: "photo.on.rectangle.angled"
        case .windowStyle: "macwindow"
        case .shortcuts: "keyboard.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .output: .blue
        case .windowStyle: .purple
        case .shortcuts: .red
        case .permissions: .green
        case .about: .indigo
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane? = .general
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
        window.title = "Screenshotta Settings"
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 780, height: 560))
        window.minSize = NSSize(width: 700, height: 460)
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
