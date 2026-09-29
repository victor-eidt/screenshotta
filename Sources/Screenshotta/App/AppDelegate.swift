import AppKit
import ImageIO

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        BackgroundCursor.enable()
        setupStatusItem()
        HotKeyManager.shared.reloadCaptureShortcuts()
        ShakeDetector.shared.isEnabled = Preferences.shared.shakeToOpenShelf

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
        urls.forEach(EditorWindowController.open(fileURL:))
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
        addShelfItems(to: menu)

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

    private func addShelfItems(to menu: NSMenu) {
        let newShelf = NSMenuItem(title: "New Shelf", action: #selector(openNewShelf), keyEquivalent: "")
        newShelf.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        Preferences.shared.shelfShortcut?.apply(to: newShelf)
        menu.addItem(newShelf)

        let history = ShelfManager.shared.history
        guard !history.isEmpty else { return }
        menu.addItem(.sectionHeader(title: "Recent Shelves"))
        for record in history.prefix(4) {
            menu.addItem(shelfMenuItem(record))
        }

        let all = NSMenuItem(title: "All Shelves", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for record in history {
            submenu.addItem(shelfMenuItem(record))
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearShelfHistory), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)
        all.submenu = submenu
        menu.addItem(all)
    }

    private func shelfMenuItem(_ record: ShelfRecord) -> NSMenuItem {
        let item = NSMenuItem(title: record.title, action: #selector(reopenShelf(_:)), keyEquivalent: "")
        item.representedObject = record.id
        item.target = self
        let date = Self.shelfDateFormatter.string(from: record.updatedAt)
        if #available(macOS 14.4, *) {
            item.subtitle = date
        } else {
            item.title = "\(record.title)  ·  \(date)"
        }
        item.image = record.urls.first.flatMap { MenuThumbnail.image(for: $0) }
        return item
    }

    private static let shelfDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    @objc private func openNewShelf() {
        ShelfManager.shared.newShelf()
    }

    @objc private func reopenShelf(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = ShelfManager.shared.history.first(where: { $0.id == id })
        else { return }
        ShelfManager.shared.reopen(record)
    }

    @objc private func clearShelfHistory() {
        ShelfManager.shared.clearHistory()
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

/// A small preview of a file for a menu item.
enum MenuThumbnail {
    static func image(for url: URL) -> NSImage? {
        let box = NSSize(width: 26, height: 20)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: box.height, height: box.height)
            return icon
        }
        let scale = min(box.width / CGFloat(cgImage.width), box.height / CGFloat(cgImage.height))
        let size = NSSize(width: (CGFloat(cgImage.width) * scale).rounded(), height: (CGFloat(cgImage.height) * scale).rounded())
        return NSImage(size: box, flipped: false) { rect in
            let frame = NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height)
            NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5).addClip()
            NSImage(cgImage: cgImage, size: size).draw(in: frame)
            return true
        }
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
