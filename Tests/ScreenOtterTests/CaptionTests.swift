import AVFoundation
import CoreImage
import Foundation
import Speech
import Testing
@testable import ScreenOtter

private func words(_ spec: [(String, Double, Double)]) -> [CaptionWord] {
    spec.map { CaptionWord(text: $0.0, start: $0.1, end: $0.2) }
}

@Suite struct CaptionPhrasingTests {
    @Test func breaksAtPausesAndSentences() {
        let cues = CaptionPhrasing.cues(words([
            ("Here", 0, 0.2), ("is", 0.2, 0.4), ("the", 0.4, 0.5), ("new", 0.5, 0.7), ("export", 0.7, 1.0), ("sheet.", 1.0, 1.5),
            ("Pick", 1.6, 1.9), ("one.", 1.9, 2.2),
            ("Then", 3.5, 3.8), ("export.", 3.8, 4.2),
        ]))
        #expect(cues.map(\.text) == ["Here is the new export sheet.", "Pick one.", "Then export."])
    }

    @Test func keepsCaptionsShortEnoughToRead() {
        let many = (0..<30).map { CaptionWord(text: "word\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        let cues = CaptionPhrasing.cues(many)
        #expect(cues.count > 1)
        #expect(cues.allSatisfy { $0.text.count <= CaptionPhrasing.maxCharacters })
        #expect(cues.allSatisfy { $0.end - $0.start <= CaptionPhrasing.maxDuration })
        #expect(cues.flatMap(\.words) == many)
    }

    @Test func tidiesWhatRecognizersReturn() {
        let tidy = CaptionTranscriber.tidy(words([(" Hello", 0, 0.3), (",", 0.3, 0.32), (" world", 0.4, 0.8), ("  ", 0.8, 0.9), ("!", 0.8, 0.85)]))
        #expect(tidy.map(\.text) == ["Hello,", "world!"])
        #expect(tidy[0].end == 0.32)
    }
}

@Suite struct CaptionEditingTests {
    let cue = CaptionCue(words: words([("Pick", 1, 1.4), ("one", 1.4, 2)]))

    @Test func sameTextKeepsTheWords() {
        #expect(cue.withText("Pick  one") == cue)
    }

    @Test func newTextSharesTheCaptionsTime() throws {
        let edited = try #require(cue.withText("Choose a template"))
        #expect(edited.id == cue.id)
        #expect(edited.text == "Choose a template")
        #expect(edited.start == 1 && abs(edited.end - 2) < 1e-9)
        // Longer words get more of the time, and they follow on from each other.
        #expect(edited.words[0].end - edited.words[0].start > edited.words[1].end - edited.words[1].start)
        #expect(zip(edited.words, edited.words.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 })
    }

    @Test func emptyTextRemovesTheCaption() {
        #expect(cue.withText("   ") == nil)
    }
}

@Suite struct CaptionTimelineTests {
    @Test func followsTrimsCutsAndSpeed() {
        let first = CaptionCue(words: words([("one", 1, 2)]))
        let across = CaptionCue(words: words([("two", 4, 4.5), ("three", 6.5, 7)]))
        let gone = CaptionCue(words: words([("four", 9, 9.5)]))
        // 0–5 kept, 5–6 cut, 6–8 at 2×, the rest cut.
        let timeline = ClipTimeline([ClipSegment(start: 0, end: 5), ClipSegment(start: 6, end: 8, speed: 2)])
        let pieces = CaptionTimeline.pieces([gone, across, first], timeline: timeline)
        #expect(pieces.map(\.cue.id) == [first.id, across.id])
        // Lingers after its last word.
        #expect(pieces[0].start == 1 && abs(pieces[0].end - (2 + CaptionTimeline.linger)) < 1e-9)
        // Runs on across the cut as one caption: from 4 s, through to the 2× clip (7.6 s in source is 5.8 s out).
        #expect(pieces[1].start == 4)
        #expect(abs(pieces[1].end - (5 + (7 + CaptionTimeline.linger - 6) / 2)) < 1e-9)
        #expect(CaptionTimeline.piece(at: 4.5, in: pieces)?.cue.id == across.id)
        #expect(CaptionTimeline.piece(at: 3.5, in: pieces) == nil)
    }

    @Test func neverLingersIntoTheNextCaption() {
        let a = CaptionCue(words: words([("a", 0, 1)]))
        let b = CaptionCue(words: words([("b", 1.2, 2)]))
        let pieces = CaptionTimeline.pieces([a, b], timeline: ClipTimeline([ClipSegment(start: 0, end: 10)]))
        #expect(pieces[0].end == 1.2)
    }

    @Test func wordsLightUpAsTheyreSaid() throws {
        let cue = CaptionCue(words: words([("Pick", 1, 1.4), ("one", 1.6, 2)]))
        let pieces = CaptionTimeline.pieces([cue], timeline: ClipTimeline([ClipSegment(start: 0, end: 10)]))
        let early = try #require(CaptionPresentation.at(1.05, source: 1.05, pieces: pieces))
        #expect(early.spoken == 1)
        #expect(early.opacity < 1)
        let later = try #require(CaptionPresentation.at(1.8, source: 1.8, pieces: pieces))
        #expect(later.spoken == 2 && later.opacity == 1)
        #expect(CaptionPresentation.at(0.5, source: 0.5, pieces: pieces) == nil)
    }

    @Test func subRipIsTimedToTheEditedVideo() {
        let cue = CaptionCue(words: words([("Hello", 61.5, 62), ("there.", 62, 63.2)]))
        let pieces = CaptionTimeline.pieces([cue], timeline: ClipTimeline([ClipSegment(start: 60, end: 70)]))
        #expect(CaptionSRT.text(pieces) == "1\n00:00:01,500 --> 00:00:03,800\nHello there.\n")
        #expect(CaptionSRT.timestamp(3725.0042) == "01:02:05,004")
    }
}

@Suite struct CaptionStyleTests {
    @Test func olderStylesGetDefaultCaptions() throws {
        let style = try JSONDecoder().decode(RecordingStyle.self, from: Data(#"{"padding": 0.1}"#.utf8))
        #expect(style.captions == CaptionStyle())
        let partial = try JSONDecoder().decode(CaptionStyle.self, from: Data(#"{"size": "large", "theme": "nope"}"#.utf8))
        #expect(partial.size == .large && partial.theme == .dark && partial.highlightWords)
    }

    @Test func editsKeepTheCaptions() throws {
        var edits = RecordingEdits.initial(duration: 5, clicks: [], style: RecordingStyle())
        edits.captions = CaptionTrack(language: "pt_BR", cues: [CaptionCue(words: words([("Olá", 0, 0.5)]))])
        let decoded = try JSONDecoder().decode(RecordingEdits.self, from: JSONEncoder().encode(edits))
        #expect(decoded.captions == edits.captions)
    }
}

@Suite struct CaptionArtTests {
    @Test func sitsUnderTheVideoAndWrapsToFit() throws {
        let cue = CaptionCue(words: words([("This", 0, 0.2), ("caption", 0.2, 0.5), ("should", 0.5, 0.7), ("wrap", 0.7, 0.9), ("onto", 0.9, 1.1), ("two", 1.1, 1.3), ("lines", 1.3, 1.6)]))
        let canvas = CGSize(width: 640, height: 480)
        // The video near the top, with room for two lines in the padding under it.
        let content = CGRect(x: 120, y: 30, width: 400, height: 260)
        let backdrop = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.8)).cropped(to: CGRect(origin: .zero, size: canvas))
        var style = CaptionStyle()
        style.size = .large
        let shown = CaptionPresentation(cue: cue, spoken: 3, opacity: 1)
        let overlay = try #require(CaptionArt.overlay(shown, style: style, backdrop: backdrop, canvas: canvas, content: content))
        #expect(abs(overlay.frame.midX - content.midX) <= 1)
        #expect(overlay.frame.minY >= content.maxY)
        #expect(overlay.frame.width <= content.width)
        // Two lines: taller than one line of the font.
        #expect(overlay.frame.height > CaptionArt.fontSize(style, canvas: canvas) * 2.2)
    }
}

@Suite struct CaptionTranscriptionTests {
    /// Speaks a sentence with `say` and transcribes it, when this Mac has the English model already.
    @Test func transcribesSpeechWithWordTimes() async throws {
        guard #available(macOS 26, *) else { return }
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.icu) == "en_US" }) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("captions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "Pick where the video is going. Then press export."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { return }

        let words = try await CaptionTranscriber.transcribe(url, language: CaptionLanguage(id: "en_US")) { _ in }
        let text = words.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("video"))
        #expect(text.contains("export"))
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        let cues = CaptionPhrasing.cues(words)
        #expect(cues.count == 2)
    }
}
