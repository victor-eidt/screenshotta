import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Input Monitoring, which a listen-only event tap needs to see key presses in other apps. It has no
/// Info.plist purpose string: macOS names the app in its own prompt and in Privacy & Security.
enum KeystrokePermission {
    static var isGranted: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; after that only System Settings can change the answer.
    @discardableResult
    static func request() -> Bool { CGRequestListenEventAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Listens to key presses while recording, for the keystroke overlay. A listen-only tap: it sees presses
/// but can never change or block them. What it keeps follows `KeystrokeFilter`: shortcuts and special keys
/// unless `allKeys`, and nothing at all while a password field has the keyboard.
final class KeystrokeTracker {
    /// A press as seen, in host seconds, with the key code kept to recognise ScreenOtter's own shortcut.
    nonisolated struct Press: Equatable, Sendable {
        var hostTime: Double
        var keyCode: Int
        var event: KeystrokeEvent
    }

    private let allKeys: Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var presses: [Press] = []

    init(allKeys: Bool) {
        self.allKeys = allKeys
    }

    /// Starts listening. False when macOS won't allow it (Input Monitoring is off): the recording goes on
    /// without keys.
    func start() -> Bool {
        // Without the permission a tap may still be made but sees no keys: the draft would then claim
        // that none were pressed.
        guard KeystrokePermission.isGranted else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: keystrokeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    /// Stops and returns the presses with times relative to `start` (the first video frame), cut to
    /// `duration`, leaving out `ignoring` (the shortcut that stops the recording).
    func stop(start: Double, duration: Double, ignoring shortcut: Shortcut?) -> KeystrokeRecording {
        cancel()
        return Self.recording(presses, start: start, duration: duration, ignoring: shortcut, allKeys: allKeys)
    }

    func cancel() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    nonisolated static func recording(_ presses: [Press], start: Double, duration: Double, ignoring shortcut: Shortcut?, allKeys: Bool) -> KeystrokeRecording {
        let stopModifiers = shortcut.map { KeystrokeModifiers(carbon: $0.carbonModifiers) }
        let events = presses.compactMap { press -> KeystrokeEvent? in
            if let shortcut, press.keyCode == Int(shortcut.keyCode), press.event.modifiers == stopModifiers { return nil }
            let t = press.hostTime - start
            guard t >= 0, t <= duration else { return nil }
            var event = press.event
            event.t = t
            return event
        }
        return KeystrokeRecording(events: events, allKeys: allKeys)
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a tap off if it's ever slow to answer; this one only listens, so just turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        case .keyDown:
            break
        default:
            return
        }
        // Held keys repeat; the pill shows the press once.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = KeystrokeModifiers(event.flags)
        guard KeystrokeFilter.records(keyCode: keyCode, modifiers: modifiers, allKeys: allKeys, secureInput: IsSecureEventInputEnabled()) else { return }

        let key = KeystrokeGlyphs.label(keyCode: keyCode, character: KeyNames.layoutCharacter(for: UInt32(keyCode)))
        var text: String?
        if allKeys, KeystrokeFilter.isTyping(keyCode: keyCode, modifiers: modifiers) {
            text = keyCode == kVK_Space ? " " : Self.typed(by: event)
        }
        presses.append(Press(
            hostTime: CursorTracker.hostTime(), keyCode: keyCode,
            event: KeystrokeEvent(t: 0, key: key, modifiers: modifiers, text: text)
        ))
    }

    /// The characters a press typed, or nil when it typed nothing printable.
    private static func typed(by event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let string = String(utf16CodeUnits: chars, count: length)
        let printable = string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return printable.isEmpty ? nil : String(String.UnicodeScalarView(printable))
    }
}

/// The tap is added to the main run loop, so its callback runs on the main thread.
nonisolated private func keystrokeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let tracker = Unmanaged<KeystrokeTracker>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated { tracker.handle(type, event) }
    }
    return Unmanaged.passUnretained(event)
}
