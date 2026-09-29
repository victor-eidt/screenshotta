import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey: works system-wide without Accessibility permission.
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    enum Slot: UInt32 {
        case area = 1
        case window = 2
        case shelf = 3
        case escape = 10
        case space = 11
    }

    /// Capture shortcuts that another app already owns.
    @Published private(set) var conflicts: Set<Slot> = []

    private var refs: [Slot: EventHotKeyRef] = [:]
    private var actions: [Slot: () -> Void] = [:]
    private static let signature: OSType = 0x5353_5441 // "SSTA"

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            HotKeyEventBridge.handle(event)
        }, 1, &spec, nil, nil)
    }

    func reloadCaptureShortcuts() {
        let prefs = Preferences.shared
        register(.area, prefs.areaShortcut) { SelectionController.shared.begin(.area) }
        register(.window, prefs.windowShortcut) { SelectionController.shared.begin(.window) }
        register(.shelf, prefs.shelfShortcut) { ShelfManager.shared.newShelf() }
    }

    /// Used while recording a new shortcut, so pressing the current one doesn't start a capture.
    func suspendCaptureShortcuts() {
        unregister(.area)
        unregister(.window)
        unregister(.shelf)
    }

    func register(_ slot: Slot, _ shortcut: Shortcut?, action: @escaping () -> Void) {
        unregister(slot)
        guard let shortcut else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[slot] = ref
            actions[slot] = action
        } else {
            conflicts.insert(slot)
        }
    }

    func unregister(_ slot: Slot) {
        if let ref = refs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
        actions[slot] = nil
        conflicts.remove(slot)
    }

    fileprivate func fire(_ rawID: UInt32) {
        guard let slot = Slot(rawValue: rawID) else { return }
        actions[slot]?()
    }
}

nonisolated enum HotKeyEventBridge {
    static func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr else { return status }
        let rawID = hotKeyID.id
        // Carbon delivers hotkey events on the main run loop.
        MainActor.assumeIsolated {
            HotKeyManager.shared.fire(rawID)
        }
        return noErr
    }
}
