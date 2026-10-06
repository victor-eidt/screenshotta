import Carbon.HIToolbox
import Foundation
import Testing
@testable import ScreenOtter

@Suite struct CaptureTextShortcutTests {
    @Test func preferencesFromBeforeCaptureTextGetTheDefaultShortcut() {
        // Saved by an older version: there is no Capture Text key at all.
        #expect(Preferences.decodeShortcut(nil, default: .defaultText) == .defaultText)
    }

    @Test func aClearedShortcutStaysCleared() {
        #expect(Preferences.decodeShortcut(Data(), default: .defaultText) == nil)
    }

    @Test func aRecordedShortcutRoundTrips() throws {
        let custom = Shortcut(keyCode: 0x11, carbonModifiers: Shortcut.defaultText.carbonModifiers)
        #expect(Preferences.decodeShortcut(try JSONEncoder().encode(custom), default: .defaultText) == custom)
    }

    @Test func defaultFollowsTheOptionShiftScheme() {
        let others = [Shortcut.defaultArea, .defaultWindow, .defaultRecord, .defaultShelf]
        #expect(!others.contains(.defaultText))
        #expect(Shortcut.defaultText.carbonModifiers == Shortcut.defaultArea.carbonModifiers)
        #expect(Shortcut.defaultText.isValid)
    }

    /// A global hotkey swallows the keystroke everywhere, so the default must not be how people type a
    /// common character on popular layouts.
    @Test(arguments: ["com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.USInternational-PC",
                      "com.apple.keylayout.Brazilian", "com.apple.keylayout.German", "com.apple.keylayout.Spanish",
                      "com.apple.keylayout.Italian", "com.apple.keylayout.French", "com.apple.keylayout.British"])
    func defaultDoesNotTakeACommonCharacter(layout: String) throws {
        let typed = try #require(Self.character(typedBy: .defaultText, layout: layout))
        let common = Set("€£$#@&%\"'“”‘’«»¿¡|\\/[]{}~^`<>")
        #expect(typed.allSatisfy { !common.contains($0) }, "\(layout) types \(typed)")
    }

    /// What `shortcut` types on `layout`, read from the layout's key map.
    static func character(typedBy shortcut: Shortcut, layout: String) -> String? {
        let filter = [kTISPropertyInputSourceID as String: layout] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let keyboard = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                keyboard, UInt16(shortcut.keyCode), UInt16(kUCKeyActionDown), (shortcut.carbonModifiers >> 8) & 0xFF,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
