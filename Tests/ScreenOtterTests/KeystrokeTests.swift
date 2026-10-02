import Carbon.HIToolbox
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ScreenOtter

@Suite struct KeystrokeGlyphTests {
    @Test func modifiersFollowTheMenuOrder() {
        let all: KeystrokeModifiers = [.command, .shift, .option, .control]
        #expect(all.glyphs == ["⌃", "⌥", "⇧", "⌘"])
        #expect(KeystrokeModifiers([.shift, .command]).glyphs == ["⇧", "⌘"])
    }

    @Test func modifiersComeFromEventFlagsAndCarbon() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskAlphaShift]
        #expect(KeystrokeModifiers(flags) == [.command, .shift])
        #expect(KeystrokeModifiers(carbon: UInt32(optionKey | shiftKey)) == [.option, .shift])
        #expect(KeystrokeModifiers(carbon: Shortcut.defaultRecord.carbonModifiers) == [.option, .shift])
    }

    @Test func specialKeysHaveTheirNames() {
        #expect(KeystrokeGlyphs.label(keyCode: kVK_Return, character: "\r") == "↩")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_Escape, character: nil) == "Esc")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_Tab, character: "\t") == "⇥")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_Delete, character: nil) == "⌫")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_Space, character: " ") == "Space")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_LeftArrow, character: nil) == "←")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_F5, character: nil) == "F5")
        // The shortcut recorder's names, but in words where its symbol is obscure.
        #expect(KeyNames.special[kVK_Escape] == "⎋")
        #expect(KeystrokeGlyphs.special[kVK_ForwardDelete] == KeyNames.special[kVK_ForwardDelete])
        #expect(KeystrokeFilter.specialKeyCodes.contains(kVK_F20))
    }

    @Test func characterKeysAreCapitalsLikeOnAKeycap() {
        #expect(KeystrokeGlyphs.label(keyCode: kVK_ANSI_K, character: "k") == "K")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_ANSI_Semicolon, character: "ç") == "Ç")
        #expect(KeystrokeGlyphs.label(keyCode: kVK_ANSI_1, character: "1") == "1")
        // Nothing printable from the layout: still a label, never an empty pill.
        #expect(KeystrokeGlyphs.label(keyCode: 127, character: nil) == "Key 127")
        #expect(KeystrokeGlyphs.label(keyCode: 127, character: "\u{10}") == "Key 127")
    }
}

@Suite struct KeystrokeFilterTests {
    @Test func shortcutsOnlyByDefault() {
        #expect(KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [.command], allKeys: false, secureInput: false))
        #expect(KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [.control], allKeys: false, secureInput: false))
        #expect(KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [.option], allKeys: false, secureInput: false))
        // Typing, capitals included, stays private.
        #expect(!KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [], allKeys: false, secureInput: false))
        #expect(!KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [.shift], allKeys: false, secureInput: false))
        #expect(!KeystrokeFilter.records(keyCode: kVK_Space, modifiers: [], allKeys: false, secureInput: false))
        #expect(!KeystrokeFilter.records(keyCode: kVK_Delete, modifiers: [], allKeys: false, secureInput: false))
    }

    @Test func specialKeysCountWithoutModifiers() {
        for code in [kVK_Return, kVK_Escape, kVK_Tab, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_F1] {
            #expect(KeystrokeFilter.records(keyCode: code, modifiers: [], allKeys: false, secureInput: false))
        }
        #expect(KeystrokeFilter.records(keyCode: kVK_Tab, modifiers: [.shift], allKeys: false, secureInput: false))
    }

    @Test func allKeysIsAnOptIn() {
        #expect(KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [], allKeys: true, secureInput: false))
        #expect(KeystrokeFilter.records(keyCode: kVK_Delete, modifiers: [], allKeys: true, secureInput: false))
    }

    @Test func nothingIsKeptWhileAPasswordFieldIsActive() {
        #expect(!KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [.command], allKeys: false, secureInput: true))
        #expect(!KeystrokeFilter.records(keyCode: kVK_Return, modifiers: [], allKeys: false, secureInput: true))
        #expect(!KeystrokeFilter.records(keyCode: kVK_ANSI_K, modifiers: [], allKeys: true, secureInput: true))
    }

    @Test func typingIsPlainKeysAndSpace() {
        #expect(KeystrokeFilter.isTyping(keyCode: kVK_ANSI_K, modifiers: []))
        #expect(KeystrokeFilter.isTyping(keyCode: kVK_ANSI_K, modifiers: [.shift]))
        #expect(KeystrokeFilter.isTyping(keyCode: kVK_Space, modifiers: []))
        #expect(!KeystrokeFilter.isTyping(keyCode: kVK_ANSI_K, modifiers: [.command]))
        #expect(!KeystrokeFilter.isTyping(keyCode: kVK_Return, modifiers: []))
        #expect(!KeystrokeFilter.isTyping(keyCode: kVK_Space, modifiers: [.command]))
    }
}

@Suite struct KeystrokeGroupingTests {
    private func press(_ t: Double, _ key: String, _ modifiers: KeystrokeModifiers = [.command], text: String? = nil) -> KeystrokeGroup.Press {
        KeystrokeGroup.Press(t: t, event: KeystrokeEvent(t: t, key: key, modifiers: modifiers, text: text))
    }

    @Test func pressesCloseTogetherShareAPill() {
        let groups = KeystrokeGroup.groups([press(1, "C"), press(1.8, "V"), press(5, "S")])
        #expect(groups.count == 2)
        #expect(groups[0].presses.count == 2)
        #expect(groups[0].start == 1 && groups[0].end == 1.8 + KeystrokeGroup.hold)
        #expect(groups[1].start == 5)
    }

    @Test func pillsNeverOverlap() {
        let times = [0.0, 1.0, 2.1, 3.4, 3.5, 6, 6.2, 7.75, 9.5]
        let groups = KeystrokeGroup.groups(times.map { press($0, "Z") })
        #expect(groups.count > 1)
        for (a, b) in zip(groups, groups.dropFirst()) {
            #expect(a.end <= b.start)
        }
    }

    @Test func aPressWhileThePillFadesJoinsIt() {
        // 1.3 s apart: the first pill is already fading when the second press comes.
        let groups = KeystrokeGroup.groups([press(0, "C"), press(1.3, "V")])
        #expect(groups.count == 1)
    }

    @Test func repeatsFoldIntoACount() {
        let group = KeystrokeGroup(presses: [press(0, "Z"), press(0.3, "Z"), press(0.6, "Z"), press(0.9, "S")])
        #expect(group.items(at: 1) == [
            .chord(modifiers: [.command], key: "Z", count: 3),
            .chord(modifiers: [.command], key: "S", count: 1),
        ])
        // ⇧⌘Z after ⌘Z is a different shortcut.
        let mixed = KeystrokeGroup(presses: [press(0, "Z"), press(0.2, "Z", [.command, .shift])])
        #expect(mixed.items(at: 1).count == 2)
    }

    @Test func thePillGrowsAsKeysComeIn() {
        let group = KeystrokeGroup(presses: [press(0, "C"), press(0.5, "V")])
        #expect(group.items(at: 0.2) == [.chord(modifiers: [.command], key: "C", count: 1)])
        #expect(group.items(at: 0.5).count == 2)
        #expect(group.lastPress(before: 0.4) == 0)
        #expect(group.lastPress(before: 0.7) == 0.5)
    }

    @Test func typingRunsTogether() {
        let presses = [
            press(0, "H", [], text: "H"), press(0.1, "I", [], text: "i"), press(0.2, "Space", [], text: " "),
            press(0.3, "1", [.shift], text: "!"), press(0.4, "↩", []),
        ]
        let group = KeystrokeGroup(presses: presses)
        #expect(group.items(at: 1) == [.text("Hi !"), .chord(modifiers: [], key: "↩", count: 1)])
    }

    @Test func longPillsShowTheirNewestPart() {
        let chords: [KeystrokeItem] = (0..<7).map { .chord(modifiers: [.command], key: "\($0)", count: 1) }
        let visible = KeystrokeTrim.visible(chords)
        #expect(visible.count == KeystrokeTrim.maxItems)
        #expect(visible.last == chords.last)

        let long = KeystrokeTrim.visible([.text(String(repeating: "a", count: 40) + "end")])
        guard case let .text(run) = long.first else { Issue.record("expected text"); return }
        #expect(run.count == KeystrokeTrim.maxTextLength)
        #expect(run.hasPrefix("…") && run.hasSuffix("end"))

        // A lone space would be an empty pill.
        #expect(KeystrokeTrim.visible([.text(" ")]) == [.chord(modifiers: [], key: "Space", count: 1)])
    }
}

@Suite struct KeystrokeTimeTests {
    private func event(_ t: Double, _ key: String = "K") -> KeystrokeEvent {
        KeystrokeEvent(t: t, key: key, modifiers: [.command])
    }

    @Test func keysFollowCutsAndSpeed() {
        // Keeps 0-4 at normal speed and 6-10 at double speed; 4-6 is cut out.
        let timeline = ClipTimeline([ClipSegment(start: 0, end: 4), ClipSegment(start: 6, end: 10, speed: 2)])
        #expect(timeline.outputTimeIfKept(atSource: 2) == 2)
        #expect(timeline.outputTimeIfKept(atSource: 5) == nil)
        #expect(timeline.outputTimeIfKept(atSource: 8) == 5)
        #expect(timeline.outputTimeIfKept(atSource: 10) == nil)

        let groups = KeystrokeTimeline.groups([event(2, "A"), event(5, "B"), event(8, "C")], timeline: timeline)
        let times = groups.flatMap(\.presses).map(\.t)
        #expect(times == [2, 5])
        #expect(groups.flatMap(\.presses).map(\.event.key) == ["A", "C"])
    }

    @Test func reorderedClipsReorderTheKeys() {
        let timeline = ClipTimeline([ClipSegment(start: 5, end: 10), ClipSegment(start: 0, end: 5)])
        let groups = KeystrokeTimeline.groups([event(1, "A"), event(7, "B")], timeline: timeline)
        #expect(groups.flatMap(\.presses).map(\.event.key) == ["B", "A"])
        #expect(groups.flatMap(\.presses).map(\.t) == [2, 6])
    }

    @Test func findsThePillShowingAtATime() {
        let timeline = ClipTimeline([ClipSegment(start: 0, end: 30)])
        let groups = KeystrokeTimeline.groups([event(1), event(10), event(20)], timeline: timeline)
        #expect(KeystrokeTimeline.group(at: 0.5, in: groups) == nil)
        #expect(KeystrokeTimeline.group(at: 1.2, in: groups)?.start == 1)
        #expect(KeystrokeTimeline.group(at: 1 + KeystrokeGroup.hold + 0.01, in: groups) == nil)
        #expect(KeystrokeTimeline.group(at: 20.5, in: groups)?.start == 20)
        #expect(KeystrokeTimeline.group(at: 5, in: []) == nil)
    }

    @Test func thePillEasesInAndOut() {
        let groups = KeystrokeGroup.groups([KeystrokeGroup.Press(t: 1, event: event(1))])
        let start = KeystrokePresentation.at(1, groups: groups)
        #expect(start != nil && start!.opacity < 0.01 && start!.scale < 0.95 && start!.rise > 0.2)
        let settled = KeystrokePresentation.at(1.8, groups: groups)
        #expect(settled?.opacity == 1 && settled?.scale == 1 && settled?.rise == 0)
        let fading = KeystrokePresentation.at(groups[0].end - 0.05, groups: groups)
        #expect(fading != nil && fading!.opacity < 0.15)
        #expect(KeystrokePresentation.at(groups[0].end + 0.01, groups: groups) == nil)
    }

    /// The largest change in opacity and scale between frames 1/240 s apart.
    private func largestStep(_ groups: [KeystrokeGroup], from: Double, to: Double) -> (opacity: Double, scale: Double) {
        var previous: KeystrokePresentation?
        var opacity = 0.0, scale = 0.0
        for i in 0...Int((to - from) * 240) {
            let p = KeystrokePresentation.at(from + Double(i) / 240, groups: groups)
            let a = previous?.opacity ?? 0, b = p?.opacity ?? 0
            opacity = max(opacity, abs(b - a))
            if let previous, let p { scale = max(scale, abs(p.scale - previous.scale)) }
            previous = p
        }
        return (opacity, scale)
    }

    @Test func pressesDuringTheFadeNeverPop() {
        for gap in [1.25, 1.3, 1.45, 1.49] {
            let presses = [KeystrokeGroup.Press(t: 1, event: event(1, "C")), KeystrokeGroup.Press(t: 1 + gap, event: event(1 + gap, "V"))]
            let groups = KeystrokeGroup.groups(presses)
            let step = largestStep(groups, from: 0.5, to: 1 + gap + KeystrokeGroup.hold + 0.5)
            // The steepest a fade ever gets is the fade-in's ease-out: about 0.06 in a 240 Hz frame.
            #expect(step.opacity < 0.07, "gap \(gap)")
            #expect(step.scale < 0.01, "gap \(gap)")
        }
    }

    @Test func thePillResizesToFitANewKey() {
        let presses = [KeystrokeGroup.Press(t: 0, event: event(0, "K")), KeystrokeGroup.Press(t: 1, event: event(1, "P"))]
        let groups = KeystrokeGroup.groups(presses)
        let before = KeystrokePresentation.at(0.99, groups: groups)!
        #expect(before.previous == nil && before.items.count == 1)
        let at = KeystrokePresentation.at(1, groups: groups)!
        #expect(at.items.count == 2 && at.previous == before.items && at.resize == 0)
        let halfway = KeystrokePresentation.at(1 + KeystrokePresentation.resizeDuration / 2, groups: groups)!
        #expect(halfway.resize > 0.5 && halfway.resize < 1)
        let settled = KeystrokePresentation.at(1 + KeystrokePresentation.resizeDuration + 0.01, groups: groups)!
        #expect(settled.previous == nil && settled.resize == 1)
    }

    @Test func aNewPressBumpsThePillSlightly() {
        let presses = [KeystrokeGroup.Press(t: 0, event: event(0, "C")), KeystrokeGroup.Press(t: 1, event: event(1, "V"))]
        let groups = KeystrokeGroup.groups(presses)
        let bump = KeystrokePresentation.at(1 + KeystrokePresentation.bump / 2, groups: groups)!
        #expect(bump.scale > 1 && bump.scale < 1.05)
        #expect(KeystrokePresentation.at(1 + KeystrokePresentation.bump + 0.01, groups: groups)!.scale == 1)
    }
}

@Suite struct KeystrokeTrackerTests {
    private func press(_ host: Double, code: Int, _ modifiers: KeystrokeModifiers) -> KeystrokeTracker.Press {
        KeystrokeTracker.Press(hostTime: host, keyCode: code, event: KeystrokeEvent(t: 0, key: "X", modifiers: modifiers))
    }

    @Test func timesAreRelativeToTheFirstFrameAndCutToTheVideo() {
        let presses = [press(99, code: kVK_ANSI_K, [.command]), press(101.5, code: kVK_ANSI_K, [.command]), press(120, code: kVK_ANSI_K, [.command])]
        let recording = KeystrokeTracker.recording(presses, start: 100, duration: 10, ignoring: nil, allKeys: false)
        #expect(recording.events.map(\.t) == [1.5])
        #expect(recording.allKeys == false)
    }

    @Test func theStopShortcutIsLeftOut() {
        let stop = Shortcut.defaultRecord
        let presses = [
            press(101, code: Int(stop.keyCode), [.option, .shift]),
            press(102, code: Int(stop.keyCode), [.command]),
        ]
        let recording = KeystrokeTracker.recording(presses, start: 100, duration: 10, ignoring: stop, allKeys: true)
        #expect(recording.events.map(\.t) == [2])
        #expect(recording.allKeys)
    }
}

@Suite struct KeystrokeLayoutTests {
    private let canvas = CGSize(width: 1920, height: 1080)

    /// The canvas and where the video sits on it (top-left origin), as the renderer lays them out.
    private func scene(_ style: RecordingStyle, source: CGSize = CGSize(width: 1920, height: 1080)) -> (canvas: CGSize, content: CGRect) {
        let canvas = RecordingRenderer.canvasSize(style: style, sourceSize: source)
        let rect = RecordingRenderer.contentRect(style: style, sourceSize: source, outputSize: canvas)
        return (canvas, CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height))
    }

    private func pill(_ keys: KeystrokeStyle, _ scene: (canvas: CGSize, content: CGRect)) -> CGRect {
        let size = CGSize(width: 300, height: KeystrokeLayout.height(keys, canvas: scene.canvas))
        let center = KeystrokeLayout.center(keys, size: size, canvas: scene.canvas, content: scene.content)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    @Test func sitsUnderTheVideoInTheDefaultPadding() {
        let scene = scene(RecordingStyle())
        var keys = KeystrokeStyle()
        let bottom = pill(keys, scene)
        // In the padding, like a caption: clear of the video and of the canvas edge, never across either.
        #expect(bottom.minY >= scene.content.maxY + bottom.height * KeystrokeLayout.bandGap - 0.5)
        #expect(bottom.maxY <= scene.canvas.height - bottom.height * KeystrokeLayout.bandGap + 0.5)
        #expect(abs(bottom.midX - scene.content.midX) < 0.5)
        keys.position = .top
        let top = pill(keys, scene)
        #expect(top.maxY <= scene.content.minY - top.height * KeystrokeLayout.bandGap + 0.5)
        #expect(top.minY >= 0)
    }

    @Test func sitsInsideTheVideoWithoutPadding() {
        var style = RecordingStyle()
        style.padding = 0
        let scene = scene(style)
        var keys = KeystrokeStyle()
        let margin = (KeystrokeLayout.margin * min(scene.content.width, scene.content.height)).rounded()
        let bottom = pill(keys, scene)
        #expect(abs(bottom.maxY - (scene.content.maxY - margin)) < 0.5)
        keys.position = .top
        #expect(abs(pill(keys, scene).minY - (scene.content.minY + margin)) < 0.5)
    }

    @Test func staysCloseToTheVideoInTallCanvases() {
        var style = RecordingStyle()
        style.aspect = .vertical
        let scene = scene(style)
        let bottom = pill(KeystrokeStyle(), scene)
        #expect(bottom.minY > scene.content.maxY)
        #expect(bottom.minY - scene.content.maxY <= bottom.height * KeystrokeLayout.maxBandGap + 0.5)
    }

    @Test func sizeFollowsTheShorterSide() {
        var style = KeystrokeStyle()
        var heights: [CGFloat] = []
        for size in KeystrokeSize.allCases {
            style.size = size
            let h = KeystrokeLayout.height(style, canvas: canvas)
            #expect(h == KeystrokeLayout.height(style, canvas: CGSize(width: 1080, height: 1920)))
            heights.append(h)
        }
        #expect(heights == heights.sorted() && Set(heights).count == 3)
    }

    @Test func artFitsItsText() throws {
        let short = try #require(KeystrokeArt.label(items: [.chord(modifiers: [.command], key: "K", count: 1)], theme: .dark, height: 70))
        let long = try #require(KeystrokeArt.label(items: [.text("A longer line of typing")], theme: .light, height: 70))
        #expect(long.width > short.width)
        #expect(long.image.height == 70 && CGFloat(long.image.width) >= long.width + long.inset * 2)
        #expect(KeystrokeArt.pillWidth(textWidth: short.width, height: 70) >= 70)
        // A pill just wide enough for its text never gets narrower than round.
        #expect(KeystrokeArt.pillWidth(textWidth: 1, height: 70) == 70)

        let body = try #require(KeystrokeArt.body(theme: .dark, size: CGSize(width: 240, height: 70)))
        #expect(body.mask.width == 240 && body.mask.height == 70)
        #expect(CGFloat(body.image.width) == 240 + body.padding * 2)
    }

    private func overlay(_ groups: [KeystrokeGroup], at t: Double, padding: Bool = false) -> CIImage? {
        let canvas = CGSize(width: 640, height: 360)
        let backdrop = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: canvas))
        let content = padding ? CGRect(x: 80, y: 45, width: 480, height: 270) : CGRect(origin: .zero, size: canvas)
        return KeystrokeArt.overlay(groups: groups, style: KeystrokeStyle(), at: t, backdrop: backdrop, canvas: canvas, content: content)
    }

    @Test func overlayIsDrawnOnlyWhileKeysShow() {
        let groups = KeystrokeGroup.groups([KeystrokeGroup.Press(t: 1, event: KeystrokeEvent(t: 1, key: "K", modifiers: [.command]))])
        #expect(overlay(groups, at: 0.5) == nil)
        let pill = overlay(groups, at: 1.5)
        #expect(pill != nil)
        // Near the bottom centre, inside the frame.
        if let extent = pill?.extent {
            #expect(abs(extent.midX - 320) < 1)
            #expect(extent.midY < 360 / 3)
        }
    }

    @Test func thePillGrowsWithoutJumping() throws {
        let press = { (t: Double, key: String) in KeystrokeGroup.Press(t: t, event: KeystrokeEvent(t: t, key: key, modifiers: [.command])) }
        let groups = KeystrokeGroup.groups([press(0, "K"), press(1, "P")])
        let before = try #require(overlay(groups, at: 0.999)).extent.width
        let after = try #require(overlay(groups, at: 1.001)).extent.width
        let settled = try #require(overlay(groups, at: 1.5)).extent.width
        #expect(settled > before + 20)
        // Pixel rounding of the extent only, against a 20+ px change once settled.
        #expect(abs(after - before) <= 2)
    }
}

@Suite struct KeystrokePersistenceTests {
    @Test func recordingRoundTrips() throws {
        let recording = KeystrokeRecording(events: [
            KeystrokeEvent(t: 1.25, key: "K", modifiers: [.command, .shift]),
            KeystrokeEvent(t: 2, key: "A", text: "a"),
        ], allKeys: true)
        let decoded = try JSONDecoder().decode(KeystrokeRecording.self, from: JSONEncoder().encode(recording))
        #expect(decoded == recording)
    }

    @Test func partialFilesStillDecode() throws {
        let empty = try JSONDecoder().decode(KeystrokeRecording.self, from: Data("{}".utf8))
        #expect(empty.events.isEmpty && !empty.allKeys && !empty.blocked)
        // Files from before `blocked` was saved.
        let old = try JSONDecoder().decode(KeystrokeRecording.self, from: Data(#"{"events":[{"t":1,"key":"K","modifiers":8}],"allKeys":true}"#.utf8))
        #expect(old.events.count == 1 && old.allKeys && !old.blocked)
        let blocked = KeystrokeRecording(blocked: true)
        #expect(try JSONDecoder().decode(KeystrokeRecording.self, from: JSONEncoder().encode(blocked)) == blocked)
        let style = try JSONDecoder().decode(KeystrokeStyle.self, from: Data(#"{"theme":"light","size":"huge"}"#.utf8))
        #expect(style.theme == .light && style.size == .medium && style.position == .bottom)
    }

    @Test func editsFromBeforeKeystrokesStillOpen() throws {
        let json = """
        {"segments":[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","start":0,"end":5,"speed":1}],
         "zooms":[],"style":{"padding":0.1,"webcam":{"shape":"circle"}},"webcamHidden":true}
        """
        let edits = try JSONDecoder().decode(RecordingEdits.self, from: Data(json.utf8))
        #expect(edits.keystrokesHidden == nil)
        #expect(edits.style.keystrokes == KeystrokeStyle())
        #expect(edits.style.padding == 0.1 && edits.style.webcam.shape == .circle)
        #expect(edits.webcamHidden == true)
    }

    @Test func styleRoundTripsWithKeystrokes() throws {
        var style = RecordingStyle()
        style.keystrokes.theme = .light
        style.keystrokes.position = .top
        let decoded = try JSONDecoder().decode(RecordingStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded == style)
    }

    @Test func draftsWithoutKeysHaveNoKeystrokes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = RecordingProject(folder: folder)
        #expect(project.loadKeystrokes() == nil)
        let recording = KeystrokeRecording(events: [KeystrokeEvent(t: 3, key: "↩")])
        try project.save(recording)
        #expect(project.loadKeystrokes() == recording)
    }
}
