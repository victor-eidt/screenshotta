import Foundation

// Captions: what was said into the microphone, transcribed on the Mac, shown under the video a phrase at a time
// with each word lighting up as it's spoken, editable, and exported as .srt.

/// One spoken word, in recording seconds (from the first video frame). `text` carries its punctuation.
nonisolated struct CaptionWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// One caption: a short phrase shown on its own. Times are recording seconds.
nonisolated struct CaptionCue: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var words: [CaptionWord]

    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }

    /// The cue with its words rewritten, keeping when it's shown. The new words share its time in proportion
    /// to their length, so the words still light up roughly as they're said. Nil when nothing is left.
    func withText(_ text: String) -> CaptionCue? {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts == words.map(\.text) { return self }
        let start = self.start, span = max(end - start, 0.1)
        let weights = parts.map { Double($0.count) + 1 }
        let total = weights.reduce(0, +)
        var t = start
        var words: [CaptionWord] = []
        for (part, weight) in zip(parts, weights) {
            let length = span * weight / total
            words.append(CaptionWord(text: part, start: t, end: t + length))
            t += length
        }
        return CaptionCue(id: id, words: words)
    }
}

/// The captions of a recording, in its edits: the cues and the language they were heard in.
nonisolated struct CaptionTrack: Codable, Equatable, Sendable {
    /// A locale identifier, "en_US", "pt_BR".
    var language: String
    var cues: [CaptionCue]
}

// MARK: - Phrasing

/// Splits a transcript into captions the way subtitles read: short enough to take in at a glance, broken at
/// pauses and at the end of sentences rather than mid-thought.
nonisolated enum CaptionPhrasing {
    /// Characters a caption holds before it moves on (about two short lines).
    static let maxCharacters = 42
    /// Seconds a caption stays at most, however slowly it's said.
    static let maxDuration = 5.0
    /// A silence this long starts a new caption.
    static let pause = 0.7
    /// A finished sentence starts a new caption once this many characters are up.
    static let sentenceBreak = 16

    static func cues(_ words: [CaptionWord]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: [CaptionWord] = []
        func length(_ words: [CaptionWord]) -> Int {
            words.reduce(0) { $0 + $1.text.count } + max(words.count - 1, 0)
        }
        for word in words where !word.text.isEmpty {
            if let last = current.last {
                let longer = length(current) + 1 + word.text.count > maxCharacters
                let paused = word.start - last.end >= pause
                let tooLong = word.end - current[0].start > maxDuration
                let sentence = Self.endsSentence(last.text) && length(current) >= sentenceBreak
                if longer || paused || tooLong || sentence {
                    cues.append(CaptionCue(words: current))
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { cues.append(CaptionCue(words: current)) }
        return cues
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…".contains(last)
    }
}

// MARK: - Time

/// A caption as it shows in the edited video. A cue that a cut runs through shows in a piece on each side.
nonisolated struct CaptionPiece: Equatable, Sendable {
    var cue: CaptionCue
    /// Output seconds.
    var start: Double
    var end: Double
    /// The cue was already showing just before this piece (it runs on across a cut), so it doesn't fade in again.
    var continues = false
}

nonisolated enum CaptionTimeline {
    /// After its last word a caption stays this much longer, unless the next one comes first.
    static let linger = 0.6

    /// The captions laid out on the edited video: kept parts only, at their clips' speeds, in order.
    static func pieces(_ cues: [CaptionCue], timeline: ClipTimeline) -> [CaptionPiece] {
        let sorted = cues.sorted { $0.start < $1.start }
        var pieces: [CaptionPiece] = []
        for (index, cue) in sorted.enumerated() {
            // Lingers, but never into the next caption.
            let next = index + 1 < sorted.count ? sorted[index + 1].start : .infinity
            let end = min(cue.end + linger, max(next, cue.end))
            var first = true
            for (i, segment) in timeline.segments.enumerated() {
                let from = max(cue.start, segment.start), to = min(end, segment.end)
                guard to - from > 0.01 else { continue }
                let start = timeline.outputStarts[i] + (from - segment.start) / segment.speed
                let stop = timeline.outputStarts[i] + (to - segment.start) / segment.speed
                // Clips back to back in the output: the caption carries on across the cut.
                let runsOn = !first && pieces.last.map { $0.cue.id == cue.id && abs($0.end - start) < 0.001 } == true
                if runsOn {
                    pieces[pieces.count - 1].end = stop
                } else {
                    pieces.append(CaptionPiece(cue: cue, start: start, end: stop, continues: !first))
                }
                first = false
            }
        }
        return pieces.sorted { $0.start < $1.start }
    }

    /// The piece showing at output time `t`, if any.
    static func piece(at t: Double, in pieces: [CaptionPiece]) -> CaptionPiece? {
        var low = 0, high = pieces.count
        while low < high {
            let mid = (low + high) / 2
            if pieces[mid].start <= t { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let piece = pieces[low - 1]
        return t < piece.end ? piece : nil
    }
}

/// What the caption box shows at a moment: the cue, how many of its words have been said, and how visible it is.
nonisolated struct CaptionPresentation: Equatable, Sendable {
    var cue: CaptionCue
    /// Words said by now; the rest are drawn quieter when words are highlighted.
    var spoken: Int
    var opacity: Double

    static let fadeIn = 0.14
    static let fadeOut = 0.18

    /// `t` is output time, `source` the recording time showing then.
    static func at(_ t: Double, source: Double, pieces: [CaptionPiece]) -> CaptionPresentation? {
        guard let piece = CaptionTimeline.piece(at: t, in: pieces) else { return nil }
        let appear = piece.continues ? 1 : smooth(clamp((t - piece.start) / fadeIn))
        // Fades out at the end of the piece only when nothing follows straight on.
        let follows = pieces.contains { $0.start >= piece.end - 0.001 && $0.start - piece.end < 0.05 }
        let leave = follows ? 1 : smooth(clamp((piece.end - t) / fadeOut))
        let spoken = piece.cue.words.filter { $0.start <= source + 0.02 }.count
        return CaptionPresentation(cue: piece.cue, spoken: spoken, opacity: appear * leave)
    }

    private static func clamp(_ p: Double) -> Double { min(max(p, 0), 1) }
    private static func smooth(_ p: Double) -> Double { p * p * (3 - 2 * p) }
}

// MARK: - SubRip

/// .srt, the subtitle file every player and platform reads, timed to the edited video.
nonisolated enum CaptionSRT {
    static func text(_ pieces: [CaptionPiece]) -> String {
        pieces.enumerated().map { index, piece in
            "\(index + 1)\n\(timestamp(piece.start)) --> \(timestamp(piece.end))\n\(piece.cue.text)\n"
        }.joined(separator: "\n")
    }

    /// "00:01:02,345".
    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

// MARK: - Style

nonisolated enum CaptionSize: String, Codable, CaseIterable, Identifiable, Sendable {
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

    /// Font size, as a fraction of the video's shorter side.
    var fraction: CGFloat {
        switch self {
        case .small: 0.032
        case .medium: 0.04
        case .large: 0.05
        }
    }
}

/// How the captions look. Part of the recording style, so it carries over to the next recording.
/// The box shares the keystroke pill's glass, in the same dark or light.
nonisolated struct CaptionStyle: Codable, Equatable, Sendable {
    var theme: KeystrokeTheme = .dark
    var size: CaptionSize = .medium
    var position: KeystrokePosition = .bottom
    /// Words light up as they're said; the rest of the caption waits a shade quieter.
    var highlightWords = true

    init() {}

    // Field by field, so styles from before a new option still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionStyle()
        theme = (try? c.decode(KeystrokeTheme.self, forKey: .theme)) ?? d.theme
        size = (try? c.decode(CaptionSize.self, forKey: .size)) ?? d.size
        position = (try? c.decode(KeystrokePosition.self, forKey: .position)) ?? d.position
        highlightWords = (try? c.decode(Bool.self, forKey: .highlightWords)) ?? d.highlightWords
    }

    private enum CodingKeys: String, CodingKey {
        case theme, size, position, highlightWords
    }
}

/// What the renderer needs to draw captions.
nonisolated struct CaptionOverlay: Equatable, Sendable {
    var cues: [CaptionCue]
    var style: CaptionStyle
}
