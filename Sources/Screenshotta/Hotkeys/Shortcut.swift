import AppKit
import Carbon.HIToolbox

nonisolated struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultArea = Shortcut(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(optionKey | shiftKey))
    static let defaultWindow = Shortcut(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(optionKey | shiftKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    /// Global shortcuts need a real modifier, except for function keys.
    var isValid: Bool {
        let strong = UInt32(cmdKey | optionKey | controlKey)
        return carbonModifiers & strong != 0 || KeyNames.functionKeys.contains(keyCode)
    }

    var modifierSymbols: [String] {
        var symbols: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { symbols.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols.append("⌘") }
        return symbols
    }

    var keyName: String { KeyNames.name(for: keyCode) }

    var displayString: String { modifierSymbols.joined() + keyName }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
}

extension Shortcut {
    /// Shows the shortcut next to a menu item (display only; the hotkey itself is global).
    func apply(to item: NSMenuItem) {
        let name = keyName
        guard name.count == 1 else { return }
        item.keyEquivalent = name.lowercased()
        item.keyEquivalentModifierMask = cocoaModifiers
    }
}

nonisolated enum KeyNames {
    static let functionKeys: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5), UInt32(kVK_F6),
        UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16), UInt32(kVK_F17), UInt32(kVK_F18),
        UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Uses the current keyboard layout, so a Brazilian keyboard shows "Ç" instead of ";".
    static func name(for keyCode: UInt32) -> String {
        if let name = special[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
