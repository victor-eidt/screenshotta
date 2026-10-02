import Carbon.HIToolbox
import CoreGraphics
import Foundation

// The keystroke overlay: the shortcuts pressed while recording, shown as a small pill over the edited video.
// Off unless turned on in Settings, and by default only shortcuts are kept, never plain typing.

/// ⌃ ⌥ ⇧ ⌘, the modifiers a keystroke was pressed with.
nonisolated struct KeystrokeModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let control = KeystrokeModifiers(rawValue: 1 << 0)
    static let option = KeystrokeModifiers(rawValue: 1 << 1)
    static let shift = KeystrokeModifiers(rawValue: 1 << 2)
    static let command = KeystrokeModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: CGEventFlags) {
        var modifiers: KeystrokeModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        self = modifiers
    }

    /// Carbon modifiers, as `Shortcut` stores them.
    init(carbon: UInt32) {
        var modifiers: KeystrokeModifiers = []
        if carbon & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if carbon & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        self = modifiers
    }

    /// In the order macOS menus use: ⌃⌥⇧⌘.
    var glyphs: [String] {
        [(KeystrokeModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }
            .map(\.1)
    }

    /// ⌘, ⌃ or ⌥: what makes a key press a shortcut rather than typing. Shift alone only types capitals.
    var makesShortcut: Bool { !isDisjoint(with: [.command, .control, .option]) }
}

/// One key press, in recording seconds from the first video frame.
nonisolated struct KeystrokeEvent: Codable, Equatable, Sendable {
    var t: Double
    /// The key as printed on its keycap: "K", "↩", "Space", "F5".
    var key: String
    var modifiers: KeystrokeModifiers
    /// What the press typed, for plain typing kept with "All keys" on ("k", "K", "!"). Nil for shortcuts
    /// and special keys, which show as keys.
    var text: String?

    init(t: Double, key: String, modifiers: KeystrokeModifiers = [], text: String? = nil) {
        self.t = t
        self.key = key
        self.modifiers = modifiers
        self.text = text
    }
}

/// The keys recorded with a draft, in `keys.json`. Drafts recorded without the overlay have no file.
nonisolated struct KeystrokeRecording: Codable, Equatable, Sendable {
    var events: [KeystrokeEvent] = []
    /// Recorded with "All keys" on: typing is in there too, not only shortcuts.
    var allKeys = false
    /// Keystrokes were on, but macOS wouldn't let ScreenOtter see key presses (Input Monitoring was off).
    var blocked = false

    init(events: [KeystrokeEvent] = [], allKeys: Bool = false, blocked: Bool = false) {
        self.events = events
        self.allKeys = allKeys
        self.blocked = blocked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? c.decodeIfPresent([KeystrokeEvent].self, forKey: .events)) ?? []
        allKeys = (try? c.decodeIfPresent(Bool.self, forKey: .allKeys)) ?? false
        blocked = (try? c.decodeIfPresent(Bool.self, forKey: .blocked)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case events, allKeys, blocked
    }
}

// MARK: - What gets recorded

/// Decides which presses are kept. Pure, so the privacy rules are tested on their own.
nonisolated enum KeystrokeFilter {
    /// Keys worth showing even without a modifier: they move, confirm or cancel, they don't type.
    static let specialKeyCodes: Set<Int> = Set(KeyNames.functionKeys.map(Int.init)).union([
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_Tab,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ])

    /// Whether a press goes into the recording. Nothing is kept while a secure text field (a password)
    /// has the keyboard; otherwise shortcuts and special keys are, and plain typing only with `allKeys`.
    static func records(keyCode: Int, modifiers: KeystrokeModifiers, allKeys: Bool, secureInput: Bool) -> Bool {
        if secureInput { return false }
        if allKeys { return true }
        return modifiers.makesShortcut || specialKeyCodes.contains(keyCode)
    }

    /// Whether a kept press shows as typed text rather than as a key: plain typing, with "All keys" on.
    static func isTyping(keyCode: Int, modifiers: KeystrokeModifiers) -> Bool {
        !modifiers.makesShortcut && (keyCode == kVK_Space || KeystrokeGlyphs.special[keyCode] == nil)
    }
}

/// How keys are labelled on the pill.
nonisolated enum KeystrokeGlyphs {
    /// Keys whose name isn't the character they type: the shortcut recorder's names, with words rather than
    /// symbols where the symbol is obscure (Esc, not ⎋), the way they read in a tutorial.
    static let special: [Int: String] = KeyNames.special.merging([
        kVK_Escape: "Esc", kVK_ANSI_KeypadEnter: "⌤", kVK_CapsLock: "⇪", kVK_Help: "Help",
    ]) { _, override in override }

    /// The keycap label: a special key's name, or the character the key types on the current layout
    /// without modifiers (`character`), in capitals like on a keyboard.
    static func label(keyCode: Int, character: String?) -> String {
        if let name = special[keyCode] { return name }
        let trimmed = (character ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty else { return "Key \(keyCode)" }
        return trimmed.uppercased()
    }
}

// MARK: - Grouping

/// What a pill shows: shortcuts, each with how many times in a row it was pressed, and runs of typing.
nonisolated enum KeystrokeItem: Equatable, Sendable {
    case chord(modifiers: KeystrokeModifiers, key: String, count: Int)
    case text(String)
}

/// Presses close together share one pill, which grows as they come in and stays a moment after the last.
/// Times are output seconds (after cuts and speed changes).
nonisolated struct KeystrokeGroup: Equatable, Sendable {
    /// How long the pill stays after its last press, fade-out included.
    static let hold = 1.5
    /// A press made while the pill is still up, even fading out, joins it: two pills are never on screen at
    /// once, and one is never cut off mid-fade by the next.
    static let joinGap = hold

    struct Press: Equatable, Sendable {
        var t: Double
        var event: KeystrokeEvent
    }

    var presses: [Press]

    var start: Double { presses.first?.t ?? 0 }
    var lastPress: Double { presses.last?.t ?? 0 }
    var end: Double { lastPress + Self.hold }

    /// Splits presses (sorted by time) into pills.
    static func groups(_ presses: [Press]) -> [KeystrokeGroup] {
        var groups: [KeystrokeGroup] = []
        for press in presses {
            if let last = groups.last, press.t - last.lastPress <= joinGap {
                groups[groups.count - 1].presses.append(press)
            } else {
                groups.append(KeystrokeGroup(presses: [press]))
            }
        }
        return groups
    }

    /// The pill's contents at output time `t`: only presses made by then, repeats folded into a count.
    func items(at t: Double) -> [KeystrokeItem] {
        var items: [KeystrokeItem] = []
        for press in presses where press.t <= t + 1e-9 {
            let event = press.event
            if let text = event.text {
                if case let .text(run) = items.last {
                    items[items.count - 1] = .text(run + text)
                } else {
                    items.append(.text(text))
                }
            } else if case let .chord(modifiers, key, count) = items.last, modifiers == event.modifiers, key == event.key {
                items[items.count - 1] = .chord(modifiers: modifiers, key: key, count: count + 1)
            } else {
                items.append(.chord(modifiers: event.modifiers, key: event.key, count: 1))
            }
        }
        return items
    }

    /// The press made last by `t`, for the small bump each new press gives the pill.
    func lastPress(before t: Double) -> Double? {
        presses.last { $0.t <= t + 1e-9 }?.t
    }

    /// The press made just before the one at `t`, if any.
    func press(before t: Double) -> Double? {
        presses.last { $0.t < t - 1e-9 }?.t
    }
}

/// Only the newest part of a long pill is shown: the last few shortcuts, and the end of a typing run.
nonisolated enum KeystrokeTrim {
    static let maxItems = 4
    static let maxTextLength = 22

    static func visible(_ items: [KeystrokeItem]) -> [KeystrokeItem] {
        items.suffix(maxItems).map { item in
            guard case let .text(run) = item else { return item }
            // A run that's only spaces so far would be an empty pill: show the key instead.
            if run.allSatisfy(\.isWhitespace) { return .chord(modifiers: [], key: "Space", count: run.count) }
            guard run.count > maxTextLength else { return item }
            return .text("…" + String(run.suffix(maxTextLength - 1)))
        }
    }
}

// MARK: - Time

nonisolated extension ClipTimeline {
    /// The output time showing `source`, or nil when that moment was cut out.
    func outputTimeIfKept(atSource s: Double) -> Double? {
        for (i, segment) in segments.enumerated() where s >= segment.start && s < segment.end {
            return outputStarts[i] + (s - segment.start) / segment.speed
        }
        return nil
    }
}

nonisolated enum KeystrokeTimeline {
    /// The pills for `events` (recording seconds) in the edited video: presses in cut-out parts are dropped,
    /// the rest follow the clips and their speed.
    static func groups(_ events: [KeystrokeEvent], timeline: ClipTimeline) -> [KeystrokeGroup] {
        let presses = events
            .compactMap { event in timeline.outputTimeIfKept(atSource: event.t).map { KeystrokeGroup.Press(t: $0, event: event) } }
            .sorted { $0.t < $1.t }
        return KeystrokeGroup.groups(presses)
    }

    /// The pill showing at output time `t`, if any. Groups never overlap (see `joinGap`), so it's the last
    /// one started.
    static func group(at t: Double, in groups: [KeystrokeGroup]) -> KeystrokeGroup? {
        var low = 0, high = groups.count
        while low < high {
            let mid = (low + high) / 2
            if groups[mid].start <= t { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let group = groups[low - 1]
        return t < group.end ? group : nil
    }
}

// MARK: - Motion

/// How the pill moves: it rises and settles in, gives a tiny bump on every new press, resizes smoothly to fit
/// it, and fades out. Restrained on purpose: the keys are the point, not the animation.
nonisolated struct KeystrokePresentation: Equatable, Sendable {
    var items: [KeystrokeItem]
    /// What the pill showed before the newest press, while it resizes to fit `items`; nil once it fits.
    var previous: [KeystrokeItem]?
    /// How far the pill has gone from `previous` to `items`, 0 to 1.
    var resize: Double
    var opacity: Double
    var scale: Double
    /// Upward offset as a fraction of the pill's height (0 once settled).
    var rise: Double

    static let fadeIn = 0.22
    static let fadeOut = 0.3
    static let bump = 0.16
    static let resizeDuration = 0.18

    static func at(_ t: Double, groups: [KeystrokeGroup]) -> KeystrokePresentation? {
        guard let group = KeystrokeTimeline.group(at: t, in: groups) else { return nil }
        let items = KeystrokeTrim.visible(group.items(at: t))
        guard !items.isEmpty else { return nil }

        let appear = easeOut(clamp((t - group.start) / fadeIn))
        let last = group.lastPress(before: t) ?? group.start
        // Full until it starts fading after the newest press. A press made during the fade brings it back
        // from where it was, rather than popping to full.
        var level = shown(age: t - last)
        var previous: [KeystrokeItem]?
        var resize = 1.0
        if let prior = group.press(before: last) {
            let dimmed = shown(age: last - prior)
            level *= dimmed + (1 - dimmed) * easeOut(clamp((t - last) / fadeIn))
            let before = KeystrokeTrim.visible(group.items(at: prior))
            if t - last < resizeDuration, before != items {
                previous = before
                resize = easeOut(clamp((t - last) / resizeDuration))
            }
        }

        var scale = 0.94 + 0.06 * appear
        scale *= 0.97 + 0.03 * level
        if last > group.start {
            let age = t - last
            if age < bump { scale *= 1 + 0.03 * sin(.pi * age / bump) }
        }
        return KeystrokePresentation(
            items: items, previous: previous, resize: resize,
            opacity: appear * level, scale: scale, rise: 0.25 * (1 - appear)
        )
    }

    /// How visible the pill is `age` seconds after a press, if no other comes: 1 until the fade-out, then 0.
    private static func shown(age: Double) -> Double {
        smooth(clamp((KeystrokeGroup.hold - age) / fadeOut))
    }

    private static func clamp(_ p: Double) -> Double { min(max(p, 0), 1) }
    private static func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    private static func smooth(_ p: Double) -> Double { p * p * (3 - 2 * p) }
}

// MARK: - Style

nonisolated enum KeystrokeTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Smoked glass with white keys: reads on any recording.
    case dark
    /// Frosted white with dark keys, for light, airy videos.
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

nonisolated enum KeystrokeSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    var name: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Height of the pill, as a fraction of the video's shorter side.
    var fraction: CGFloat {
        switch self {
        case .small: 0.052
        case .medium: 0.066
        case .large: 0.084
        }
    }
}

nonisolated enum KeystrokePosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom, top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        }
    }
}

/// How the pill looks. Part of the recording style, so it carries over to the next recording.
nonisolated struct KeystrokeStyle: Codable, Equatable, Sendable {
    var theme: KeystrokeTheme = .dark
    var size: KeystrokeSize = .medium
    var position: KeystrokePosition = .bottom

    init() {}

    // Field by field, so styles from before a new option still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeystrokeStyle()
        theme = (try? c.decode(KeystrokeTheme.self, forKey: .theme)) ?? d.theme
        size = (try? c.decode(KeystrokeSize.self, forKey: .size)) ?? d.size
        position = (try? c.decode(KeystrokePosition.self, forKey: .position)) ?? d.position
    }

    private enum CodingKeys: String, CodingKey {
        case theme, size, position
    }
}

/// Where the pill sits, in top-left-origin output pixels: under (or over) the video, in the padding when
/// there's room for it there, like a caption, and otherwise just inside the video's edge. Never across it.
nonisolated enum KeystrokeLayout {
    /// Space between the pill and the video's edge when it sits inside, as a fraction of the video's shorter side.
    static let margin: CGFloat = 0.065
    /// The room the pill needs above and below it to sit in the padding, in pill heights.
    static let bandGap: CGFloat = 0.25
    /// However tall the padding (9:16), the pill stays this close to the video, in pill heights.
    static let maxBandGap: CGFloat = 0.6

    static func height(_ style: KeystrokeStyle, canvas: CGSize) -> CGFloat {
        max(12, (style.size.fraction * min(canvas.width, canvas.height)).rounded())
    }

    /// The centre of a pill `size` big, for the video at `content` on a `canvas`.
    static func center(_ style: KeystrokeStyle, size: CGSize, canvas: CGSize, content: CGRect) -> CGPoint {
        let h = size.height
        let below = style.position == .bottom
        let band = below ? canvas.height - content.maxY : content.minY
        let y: CGFloat
        if band >= h * (1 + 2 * bandGap) {
            let gap = min((band - h) / 2, h * maxBandGap)
            y = below ? content.maxY + gap + h / 2 : content.minY - gap - h / 2
        } else {
            let margin = (self.margin * min(content.width, content.height)).rounded()
            y = below ? content.maxY - margin - h / 2 : content.minY + margin + h / 2
        }
        return CGPoint(x: content.midX, y: y)
    }
}

/// What the renderer needs to draw the pill: the recorded presses and how they look.
nonisolated struct KeystrokeOverlay: Equatable, Sendable {
    var events: [KeystrokeEvent]
    var style: KeystrokeStyle
}
