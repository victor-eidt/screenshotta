import AppKit
import ImageIO

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        BackgroundCursor.enable()
        setupStatusItem()
        HotKeyManager.shared.reloadCaptureShortcuts()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            SettingsWindowController.shared.show(.permissions)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// Opening an image with Screenshotta (Dock drop, "Open With") edits it in place.
    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpi = properties?[kCGImagePropertyDPIWidth] as? Double ?? 72
            EditorWindowController.open(CapturedImage(image: image, scale: max(1, dpi / 72)), fileURL: url)
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshotta")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared

        let area = NSMenuItem(title: "Capture Area", action: #selector(captureArea), keyEquivalent: "")
        area.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        prefs.areaShortcut?.apply(to: area)
        menu.addItem(area)

        let window = NSMenuItem(title: "Capture Window", action: #selector(captureWindow), keyEquivalent: "")
        window.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        prefs.windowShortcut?.apply(to: window)
        menu.addItem(window)

        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(folder)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screenshotta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    @objc private func captureArea() {
        SelectionController.shared.begin(.area)
    }

    @objc private func captureWindow() {
        SelectionController.shared.begin(.window)
    }

    @objc private func openFolder() {
        let folder = Preferences.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}

/// Switches between menu-bar-only and a regular app while one of our real windows is open,
/// so Settings and the editor get a Dock icon, Cmd-Tab and proper focus.
enum AppActivation {
    static func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        Task { @MainActor in
            let hasVisibleWindow = NSApp.windows.contains {
                $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Screenshotta", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuActions.openSettings), keyEquivalent: ",")
        settings.target = MenuActions.shared
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Screenshotta", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Screenshotta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }
}
