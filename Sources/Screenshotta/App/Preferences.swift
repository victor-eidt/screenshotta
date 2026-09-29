import AppKit

enum WindowBackground: String, CaseIterable, Identifiable {
    case wallpaper
    case transparent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallpaper: "Desktop Wallpaper"
        case .transparent: "Transparent"
        }
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let saveToFolder = "saveToFolder"
        static let saveFolder = "saveFolder"
        static let copyToClipboard = "copyToClipboard"
        static let showThumbnail = "showThumbnail"
        static let thumbnailDuration = "thumbnailDuration"
        static let playSound = "playSound"
        static let windowBackground = "windowBackground"
        static let windowPadding = "windowPadding"
        static let windowCornerRadius = "windowCornerRadius"
        static let windowShadow = "windowShadow"
        static let bringWindowToFront = "bringWindowToFront"
        static let areaShortcut = "areaShortcut"
        static let windowShortcut = "windowShortcut"
    }

    static let defaultFolder = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenshots", isDirectory: true)

    private let defaults = UserDefaults.standard

    @Published var saveToFolder: Bool { didSet { defaults.set(saveToFolder, forKey: Key.saveToFolder) } }
    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }
    @Published var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Key.copyToClipboard) } }
    @Published var showThumbnail: Bool { didSet { defaults.set(showThumbnail, forKey: Key.showThumbnail) } }
    @Published var thumbnailDuration: Double { didSet { defaults.set(thumbnailDuration, forKey: Key.thumbnailDuration) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Key.playSound) } }

    @Published var windowBackground: WindowBackground { didSet { defaults.set(windowBackground.rawValue, forKey: Key.windowBackground) } }
    @Published var windowPadding: Double { didSet { defaults.set(windowPadding, forKey: Key.windowPadding) } }
    @Published var windowCornerRadius: Double { didSet { defaults.set(windowCornerRadius, forKey: Key.windowCornerRadius) } }
    @Published var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: Key.windowShadow) } }
    @Published var bringWindowToFront: Bool { didSet { defaults.set(bringWindowToFront, forKey: Key.bringWindowToFront) } }

    @Published var areaShortcut: Shortcut? {
        didSet {
            storeShortcut(areaShortcut, forKey: Key.areaShortcut)
            HotKeyManager.shared.reloadCaptureShortcuts()
        }
    }

    @Published var windowShortcut: Shortcut? {
        didSet {
            storeShortcut(windowShortcut, forKey: Key.windowShortcut)
            HotKeyManager.shared.reloadCaptureShortcuts()
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.saveToFolder: true,
            Key.copyToClipboard: true,
            Key.showThumbnail: true,
            Key.thumbnailDuration: 6.0,
            Key.playSound: true,
            Key.windowBackground: WindowBackground.wallpaper.rawValue,
            Key.windowPadding: 64.0,
            Key.windowCornerRadius: 12.0,
            Key.windowShadow: true,
            Key.bringWindowToFront: true,
        ])

        saveToFolder = defaults.bool(forKey: Key.saveToFolder)
        saveFolder = defaults.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        copyToClipboard = defaults.bool(forKey: Key.copyToClipboard)
        showThumbnail = defaults.bool(forKey: Key.showThumbnail)
        thumbnailDuration = defaults.double(forKey: Key.thumbnailDuration)
        playSound = defaults.bool(forKey: Key.playSound)
        windowBackground = WindowBackground(rawValue: defaults.string(forKey: Key.windowBackground) ?? "") ?? .wallpaper
        windowPadding = defaults.double(forKey: Key.windowPadding)
        windowCornerRadius = defaults.double(forKey: Key.windowCornerRadius)
        windowShadow = defaults.bool(forKey: Key.windowShadow)
        bringWindowToFront = defaults.bool(forKey: Key.bringWindowToFront)
        // Optionals are already initialized to nil, so a plain assignment here would run didSet.
        _areaShortcut = Published(initialValue: Self.loadShortcut(Key.areaShortcut, from: defaults, default: .defaultArea))
        _windowShortcut = Published(initialValue: Self.loadShortcut(Key.windowShortcut, from: defaults, default: .defaultWindow))
    }

    /// A missing key means "never configured" (use the default); empty data means "cleared by the user".
    private static func loadShortcut(_ key: String, from defaults: UserDefaults, default fallback: Shortcut) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        if data.isEmpty { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private func storeShortcut(_ shortcut: Shortcut?, forKey key: String) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }
}
