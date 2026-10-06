import AppKit
import Combine
import ImageIO

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var recordingObserver: AnyCancellable?
    private var recordingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFolders.migrateFromOldName()
        MainMenu.install()
        BackgroundCursor.enable()
        setupStatusItem()
        recordingObserver = RecordingController.shared.$state.sink { [weak self] state in
            self?.updateStatusItem(for: state)
        }
        HotKeyManager.shared.reloadCaptureShortcuts()
        ShakeDetector.shared.isEnabled = Preferences.shared.shakeToOpenShelf
        MenuThumbnail.prefetch(ShelfManager.shared.history.compactMap(\.urls.first))

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            SettingsWindowController.shared.show(.permissions)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// Opening an image with ScreenOtter (Dock drop, "Open With") edits it in place.
    func application(_ sender: NSApplication, open urls: [URL]) {
        urls.forEach(EditorWindowController.open(fileURL:))
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        updateStatusItem(for: .idle)
    }

    /// While recording, the menu bar item shows the elapsed time and a click stops the recording.
    private func updateStatusItem(for state: RecordingController.State) {
        guard let button = statusItem.button else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil

        guard case let .recording(since) = state else {
            let image = Brand.menuBarIcon ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: Brand.name)
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.action = nil
            statusItem.length = NSStatusItem.variableLength
            statusItem.menu = statusMenu
            return
        }

        statusItem.menu = nil
        statusItem.length = NSStatusItem.variableLength
        button.title = ""
        button.target = self
        button.action = #selector(toggleRecording)
        button.toolTip = "Stop Recording"
        let tick = { [weak button] in
            let seconds = Int(Date().timeIntervalSince(since))
            button?.image = Self.recordingImage(elapsed: "\(seconds / 60):\(String(format: "%02d", seconds % 60))")
        }
        tick()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    /// A red stop square and the elapsed time, as one narrow image whose width doesn't change as the seconds
    /// tick. Next to the notch, menu bar items that don't fit are hidden (ours first, being the newest), and
    /// macOS adds its own recording indicator while we record: a wider item, or one that keeps resizing, vanishes.
    private static func recordingImage(elapsed: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let stop: CGFloat = 8, gap: CGFloat = 4
        let textWidth = ceil((elapsed as NSString).size(withAttributes: [.font: font]).width)
        let image = NSImage(size: NSSize(width: stop + gap + textWidth, height: 18), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: (rect.height - stop) / 2, width: stop, height: stop), xRadius: 2, yRadius: 2).fill()
            // Drawn in the menu bar's appearance, so labelColor follows it.
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = (elapsed as NSString).size(withAttributes: attributes)
            (elapsed as NSString).draw(at: NSPoint(x: stop + gap, y: ((rect.height - size.height) / 2).rounded()), withAttributes: attributes)
            return true
        }
        image.accessibilityDescription = "Stop Recording, \(elapsed)"
        return image
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

        let record = NSMenuItem(title: "Record Screen", action: #selector(toggleRecording), keyEquivalent: "")
        record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        prefs.recordShortcut?.apply(to: record)
        menu.addItem(record)
        addRecentRecordings(to: menu)

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
        menu.addItem(NSMenuItem(title: "Quit ScreenOtter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    private func addRecentRecordings(to menu: NSMenu) {
        let recent = RecordingProject.recent(limit: 6)
        guard !recent.isEmpty else { return }
        let item = NSMenuItem(title: "Drafts", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)
        let submenu = NSMenu()
        for (project, metadata) in recent {
            let entry = NSMenuItem(title: metadata.title, action: #selector(reopenRecording(_:)), keyEquivalent: "")
            entry.representedObject = project.folder
            entry.target = self
            let length = Self.durationFormatter.string(from: metadata.duration) ?? ""
            if #available(macOS 14.4, *) {
                entry.subtitle = length
            } else {
                entry.title = "\(metadata.title)  ·  \(length)"
            }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: "Show All Drafts…", action: #selector(openDrafts), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        item.submenu = submenu
        menu.addItem(item)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    @objc private func toggleRecording() {
        RecordingController.shared.toggle()
    }

    @objc private func reopenRecording(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        RecordingEditorWindowController.open(RecordingProject(folder: folder))
    }

    @objc private func openDrafts() {
        DraftsWindowController.shared.show()
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
        if let url = record.urls.first {
            item.image = MenuThumbnail.image(for: url) { [weak item] image in item?.image = image }
        }
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

/// A small preview of a file for a menu item. Decoding a full-size screenshot takes tens of milliseconds,
/// which adds up to a menu that opens late, so previews are made in the background and kept. Until one
/// is ready, the menu shows the file's icon and swaps in the preview when it arrives.
enum MenuThumbnail {
    private static let box = NSSize(width: 26, height: 20)
    private static var cache: [String: NSImage] = [:]
    private static var waiting: [String: [(NSImage) -> Void]] = [:]

    static func image(for url: URL, whenReady update: @escaping (NSImage) -> Void) -> NSImage {
        let key = cacheKey(url)
        if let cached = cache[key] { return cached }
        load(url, key: key, then: update)
        return icon(for: url)
    }

    /// Makes previews ahead of time, so the menu opens with them in place.
    static func prefetch(_ urls: [URL]) {
        for url in urls {
            let key = cacheKey(url)
            if cache[key] == nil { load(url, key: key, then: nil) }
        }
    }

    /// The modification date is part of the key, so an edited screenshot gets a new preview.
    private static func cacheKey(_ url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
    }

    private static func load(_ url: URL, key: String, then update: ((NSImage) -> Void)?) {
        let alreadyLoading = waiting[key] != nil
        waiting[key, default: []].append(contentsOf: update.map { [$0] } ?? [])
        guard !alreadyLoading else { return }
        Task {
            let cgImage = await decode(url)
            let image = cgImage.map(framed) ?? icon(for: url)
            cache[key] = image
            waiting.removeValue(forKey: key)?.forEach { $0(image) }
        }
    }

    @concurrent
    private static func decode(_ url: URL) async -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// The file's icon in the same box as a preview, so swapping one for the other doesn't shift the menu.
    private static func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return NSImage(size: box, flipped: false) { rect in
            icon.draw(in: NSRect(x: (rect.width - rect.height) / 2, y: 0, width: rect.height, height: rect.height))
            return true
        }
    }

    private static func framed(_ cgImage: CGImage) -> NSImage {
        let box = box
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
        appMenu.addItem(withTitle: "About ScreenOtter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuActions.openSettings), keyEquivalent: ",")
        settings.target = MenuActions.shared
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ScreenOtter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ScreenOtter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
