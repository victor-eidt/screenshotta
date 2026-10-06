import Foundation
import Testing
@testable import ScreenOtter

@Suite struct ClipTimeMappingTests {
    @Test func untouchedRecordingPlaysTheWholeFile() {
        let pieces = ClipTimeMapping.pieces(segments: [ClipSegment(start: 0, end: 10)], videoDuration: 10, fileDuration: 10)
        #expect(pieces == [.init(fileStart: 0, fileEnd: 10, outputStart: 0, speed: 1)])
    }

    @Test func cutsAndTrimsFollowTheClips() {
        // Trimmed start, a cut from 4 to 6, trimmed end.
        let segments = [ClipSegment(start: 1, end: 4), ClipSegment(start: 6, end: 9)]
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 10, fileDuration: 10)
        #expect(pieces == [
            .init(fileStart: 1, fileEnd: 4, outputStart: 0, speed: 1),
            .init(fileStart: 6, fileEnd: 9, outputStart: 3, speed: 1),
        ])
    }

    @Test func speedScalesWhereLaterPiecesStart() {
        let segments = [ClipSegment(start: 0, end: 4, speed: 2), ClipSegment(start: 4, end: 6, speed: 0.5)]
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 6, fileDuration: 6)
        #expect(pieces.map(\.outputStart) == [0, 2])
        #expect(pieces.map(\.outputDuration) == [2, 4])
    }

    @Test func piecesLineUpWithTheVideoTimeline() {
        let segments = [ClipSegment(start: 0.5, end: 3, speed: 1.5), ClipSegment(start: 5, end: 8, speed: 3), ClipSegment(start: 8, end: 9)]
        let timeline = ClipTimeline(segments)
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 9, fileDuration: 9)
        for (piece, start) in zip(pieces, timeline.outputStarts) {
            #expect(abs(piece.outputStart - start) < 1e-9)
            // The sound at an output time is the source moment the video shows there.
            let t = start + piece.outputDuration / 2
            let fileTime = piece.fileStart + (t - piece.outputStart) * piece.speed
            #expect(abs(fileTime - timeline.sourceTime(atOutput: t)) < 1e-9)
        }
    }

    /// The video is laid out from the same pieces: back to back, with no gaps.
    @Test func videoPiecesFollowEachOther() {
        let segments = [ClipSegment(start: 0.5, end: 3, speed: 1.5), ClipSegment(start: 2.9, end: 2.905), ClipSegment(start: 5, end: 12, speed: 2)]
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 10, fileDuration: 10)
        #expect(pieces.count == 2)
        #expect(abs(pieces[1].outputStart - (pieces[0].outputStart + pieces[0].outputDuration)) < 1e-9)
        #expect(pieces[1].fileEnd == 10)
    }

    @Test func shortAudioStopsEarlyAndLeavesLaterClipsSilent() {
        // The sound file ends at 5s (the source went quiet and nothing more was sent).
        let segments = [ClipSegment(start: 2, end: 7), ClipSegment(start: 8, end: 10)]
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 10, fileDuration: 5)
        #expect(pieces == [.init(fileStart: 2, fileEnd: 5, outputStart: 0, speed: 1)])
    }

    @Test func clipsPastTheVideoAreClampedAndSliversDropped() {
        let segments = [ClipSegment(start: 0, end: 0.005), ClipSegment(start: 1, end: 12)]
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 10, fileDuration: 11)
        // The sliver adds no time, as in the video composition.
        #expect(pieces == [.init(fileStart: 1, fileEnd: 10, outputStart: 0, speed: 1)])
    }
}

@Suite struct AudioFrameAlignmentTests {
    @Test func onTimeBuffersAreWrittenAsTheyAre() {
        #expect(AudioFrameAlignment.plan(written: 4800, incoming: 4800, count: 1024, tolerance: 1440) == .init())
        #expect(AudioFrameAlignment.plan(written: 4800, incoming: 5000, count: 1024, tolerance: 1440) == .init())
        #expect(AudioFrameAlignment.plan(written: 4800, incoming: 4600, count: 1024, tolerance: 1440) == .init())
    }

    @Test func aLateStartOrAPauseIsFilledWithSilence() {
        #expect(AudioFrameAlignment.plan(written: 0, incoming: 12_000, count: 1024, tolerance: 0) == .init(silence: 12_000))
        #expect(AudioFrameAlignment.plan(written: 48_000, incoming: 96_000, count: 1024, tolerance: 1440) == .init(silence: 48_000))
    }

    @Test func soundAheadOfTheVideoIsTrimmed() {
        // A buffer that began before the first video frame.
        #expect(AudioFrameAlignment.plan(written: 0, incoming: -300, count: 1024, tolerance: 0) == .init(skip: 300))
        // Entirely in the past: dropped.
        #expect(AudioFrameAlignment.plan(written: 96_000, incoming: 90_000, count: 1024, tolerance: 1440) == .init(skip: 1024))
    }
}

@Suite struct AudioWaveformTests {
    @Test func levelsTakeTheLoudestBucketAndUseDecibels() {
        let waveform = AudioWaveform(peaks: [0, 0, 1, 0, 0.5, 0.5, 0, 0, 0, 0])
        let levels = waveform.levels(from: 0, to: waveform.duration, count: 5)
        #expect(levels.count == 5)
        #expect(levels[0] == 0)
        #expect(levels[1] == 1)
        #expect(abs(levels[2] - AudioWaveform.displayLevel(0.5)) < 1e-6)
        #expect(levels[3] == 0 && levels[4] == 0)
    }

    @Test func displayLevelIsFlatBelowTheFloorAndFullAtZeroDecibels() {
        #expect(AudioWaveform.displayLevel(0) == 0)
        #expect(AudioWaveform.displayLevel(0.001) == 0) // -60 dB
        #expect(AudioWaveform.displayLevel(1) == 1)
        let half = AudioWaveform.displayLevel(0.5) // about -6 dB
        #expect(half > 0.85 && half < 0.9)
    }

    @Test func levelsPastTheEndOfTheSoundAreSilent() {
        let waveform = AudioWaveform(peaks: [1, 1])
        #expect(waveform.levels(from: 5, to: 6, count: 3) == [0, 0, 0])
    }

    @Test func theMixFollowsVolumesAndSkipsMutedTracks() {
        let voice = AudioWaveform(peaks: [0.8, 0.2])
        let apps = AudioWaveform(peaks: [0.1, 0.6, 0.6])
        let mixed = AudioWaveform.mixed([(voice, 1), (apps, 0.5)])
        #expect(mixed.peaks == [0.8, 0.3, 0.3])
        #expect(AudioWaveform.mixed([(voice, 0), (apps, 1)]).peaks == apps.peaks)
    }
}

@Suite struct AudioDraftCompatibilityTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func metadataSavedBeforeAudioStillOpens() throws {
        let json = """
        {"source":"window","title":"Recording 1","createdAt":"2026-09-01T10:00:00Z",
         "pointSize":[800,600],"scale":2,"duration":12.5}
        """
        let metadata = try decode(RecordingMetadata.self, json)
        #expect(metadata.audio == nil)
        #expect(metadata.audioTracks.isEmpty)
        #expect(metadata.duration == 12.5)
        #expect(metadata.source == .window)
    }

    @Test func editsSavedBeforeAudioStillOpenWithInitialMixes() throws {
        let json = """
        {"segments":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":0,"end":5,"speed":1}],
         "zooms":[],"style":{}}
        """
        let edits = try decode(RecordingEdits.self, json)
        #expect(edits.audio == nil)
        #expect(edits.audioMix(for: .microphone, alongside: [.microphone, .system]) == AudioTrackMix(volume: 1))
        #expect(edits.audioMix(for: .system, alongside: [.microphone, .system]).volume == 0.5)
        #expect(edits.audioMix(for: .system, alongside: [.system]).volume == 1)
    }

    @Test func audioTracksAndMixesRoundTrip() throws {
        var metadata = RecordingMetadata(
            source: .area, title: "Demo", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            pointSize: CGSize(width: 1280, height: 800), scale: 2, duration: 30
        )
        metadata.audio = [
            RecordedAudioTrack(source: .microphone, file: AudioSource.microphone.fileName, deviceName: "Studio Display Microphone"),
            RecordedAudioTrack(source: .system, file: AudioSource.system.fileName),
        ]
        var edits = RecordingEdits(segments: [ClipSegment(start: 0, end: 30)], zooms: [], style: RecordingStyle())
        edits.audio = [.system: AudioTrackMix(volume: 0.3, isMuted: true)]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataJSON = String(decoding: try encoder.encode(metadata), as: UTF8.self)
        let editsData = try encoder.encode(edits)
        // Mixes are keyed by source name, so the file stays readable.
        #expect(String(decoding: editsData, as: UTF8.self).contains("\"system\":{"))

        #expect(try decode(RecordingMetadata.self, metadataJSON).audio == metadata.audio)
        let decoded = try JSONDecoder().decode(RecordingEdits.self, from: editsData)
        #expect(decoded == edits)
        #expect(decoded.audioMix(for: .system, alongside: [.microphone, .system]).effectiveVolume == 0)
    }

    @Test func effectiveVolumeIsClampedAndMutedIsSilent() {
        #expect(AudioTrackMix(volume: 1.4).effectiveVolume == 1)
        #expect(AudioTrackMix(volume: -1).effectiveVolume == 0)
        #expect(AudioTrackMix(volume: 0.7, isMuted: true).effectiveVolume == 0)
    }
}

@Suite struct MicrophoneChoiceTests {
    private let builtIn = Microphones.Device(id: "built-in", name: "MacBook Pro Microphone")
    private let usb = Microphones.Device(id: "usb", name: "USB Audio Interface")

    @Test func theSavedMicrophoneRecordsWhilePluggedIn() {
        #expect(Microphones.recording(saved: "built-in", systemDefault: "usb", in: [builtIn, usb]) == builtIn)
    }

    /// The bar and Settings must name the microphone capture falls back to, not just the first one listed.
    @Test func anUnpluggedMicrophoneFallsBackToTheSystemInput() {
        #expect(Microphones.recording(saved: "airpods", systemDefault: "usb", in: [builtIn, usb]) == usb)
        #expect(Microphones.recording(saved: nil, systemDefault: "usb", in: [builtIn, usb]) == usb)
        #expect(Microphones.recording(saved: nil, systemDefault: nil, in: [builtIn, usb]) == builtIn)
        #expect(Microphones.recording(saved: nil, systemDefault: nil, in: []) == nil)
    }
}
