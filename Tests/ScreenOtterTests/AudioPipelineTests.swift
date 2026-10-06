import AVFoundation
import Testing
@testable import ScreenOtter

/// The capture-to-edit path on real files: what the writer records, the reader and the composition see.
@Suite final class AudioPipelineTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenOtterAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let rate = 48_000.0

    private static func tone(seconds: Double, channels: AVAudioChannelCount = 1, amplitude: Float = 0.5, rate: Double = rate) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / Float(rate))
            }
        }
        return buffer
    }

    /// Seconds where the waveform is loud.
    private static func loudRanges(_ waveform: AudioWaveform) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var start: Int?
        for (index, peak) in (waveform.peaks + [0]).enumerated() {
            if peak > 0.1, start == nil { start = index }
            if peak <= 0.1, let s = start {
                ranges.append(Double(s) / AudioWaveform.bucketsPerSecond...Double(index) / AudioWaveform.bucketsPerSecond)
                start = nil
            }
        }
        return ranges
    }

    @Test func writerKeepsSoundOnTheVideoClock() async throws {
        let url = folder.appendingPathComponent("microphone.m4a")
        let writer = AudioTrackWriter(source: .microphone, url: url, deviceName: "Test Mic")
        // Starts 0.25 s after the first frame, goes quiet (nothing sent) for half a second, comes back.
        writer.append(Self.tone(seconds: 0.5), at: 0.25)
        writer.append(Self.tone(seconds: 0.5), at: 1.25)
        let track = try #require(writer.finish())
        // A straggler after the end changes nothing.
        writer.append(Self.tone(seconds: 0.5), at: 2)
        #expect(track == RecordedAudioTrack(source: .microphone, file: "microphone.m4a", deviceName: "Test Mic"))

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 1.75) < 0.03)
        let waveform = try #require(await AudioWaveform.load(url))
        let loud = Self.loudRanges(waveform)
        try #require(loud.count == 2)
        // Within two buckets (40 ms), AAC priming included.
        #expect(abs(loud[0].lowerBound - 0.25) <= 0.04)
        #expect(abs(loud[0].upperBound - 0.75) <= 0.04)
        #expect(abs(loud[1].lowerBound - 1.25) <= 0.04)
    }

    @Test func soundFromBeforeTheFirstFrameIsCutOff() async throws {
        let url = folder.appendingPathComponent("system-audio.m4a")
        let writer = AudioTrackWriter(source: .system, url: url)
        writer.append(Self.tone(seconds: 0.5, channels: 2), at: -0.2)
        _ = try #require(writer.finish())
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 0.3) < 0.03)
    }

    /// Headset microphones deliver 16 or 24 kHz and audio interfaces 88.2 or 96 kHz: the AAC encoder takes
    /// none of them at our bit rates, so every input is resampled to the file's rate.
    @Test(arguments: [(16_000.0, 1), (24_000.0, 1), (44_100.0, 2), (96_000.0, 2)] as [(Double, AVAudioChannelCount)])
    func anyDeviceRateRecords(rate: Double, channels: AVAudioChannelCount) async throws {
        let url = folder.appendingPathComponent("microphone-\(Int(rate)).m4a")
        let writer = AudioTrackWriter(source: .microphone, url: url)
        // In 10 ms buffers, as devices send them.
        let chunk = 0.01
        for index in 0..<100 {
            writer.append(Self.tone(seconds: chunk, channels: channels, rate: rate), at: 0.2 + Double(index) * chunk)
        }
        _ = try #require(writer.finish())
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(description.audioStreamBasicDescription?.mSampleRate == AudioTrackWriter.sampleRate)
        #expect(description.audioStreamBasicDescription?.mChannelsPerFrame == UInt32(channels))
        #expect(abs(try await asset.load(.duration).seconds - 1.2) < 0.03)
        let loud = Self.loudRanges(try #require(await AudioWaveform.load(url)))
        try #require(loud.count == 1)
        #expect(abs(loud[0].lowerBound - 0.2) <= 0.04)
    }

    @Test func aSourceThatSentNothingLeavesNoFile() {
        let url = folder.appendingPathComponent("system-audio.m4a")
        let writer = AudioTrackWriter(source: .system, url: url)
        #expect(writer.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func compositionCutsAndScalesTheSoundWithTheClips() async throws {
        let videoURL = folder.appendingPathComponent("recording.mov")
        try await Self.writeVideo(to: videoURL, seconds: 4)
        let audioURL = folder.appendingPathComponent("microphone.m4a")
        let writer = AudioTrackWriter(source: .microphone, url: audioURL)
        writer.append(Self.tone(seconds: 4), at: 0)
        _ = try #require(writer.finish())
        let systemURL = folder.appendingPathComponent("system-audio.m4a")
        let systemWriter = AudioTrackWriter(source: .system, url: systemURL)
        systemWriter.append(Self.tone(seconds: 4, channels: 2), at: 0)
        _ = try #require(systemWriter.finish())

        let video = AVURLAsset(url: videoURL)
        let videoTrack = try #require(try await video.loadTracks(withMediaType: .video).first)
        var sources: [SourceAudio] = []
        // A track only weakly references its asset: the assets are kept alive here, as the editor does.
        let assets = [AVURLAsset(url: audioURL), AVURLAsset(url: systemURL)]
        for (source, audio) in zip([AudioSource.microphone, .system], assets) {
            let track = try #require(try await audio.loadTracks(withMediaType: .audio).first)
            sources.append(SourceAudio(source: source, track: track, duration: try await audio.load(.duration).seconds))
        }

        // 0–2 s at 2× (1 s), then 3–4 s at normal speed (1 s): a 2 s video.
        let segments = [ClipSegment(start: 0, end: 2, speed: 2), ClipSegment(start: 3, end: 4)]
        let edited = try RecordingComposition.make(track: videoTrack, trackDuration: 4, segments: segments, audio: sources)
        let audioTracks = try await edited.asset.loadTracks(withMediaType: .audio)
        try #require(audioTracks.count == 2)
        let microphoneID = try #require(edited.audioTrackIDs[.microphone])
        let systemID = try #require(edited.audioTrackIDs[.system])
        #expect(Set(audioTracks.map(\.trackID)) == [microphoneID, systemID])
        let microphone = try #require(audioTracks.first { $0.trackID == microphoneID })
        let range = try await microphone.load(.timeRange)
        let videoRange = try await edited.asset.loadTracks(withMediaType: .video)[0].load(.timeRange)
        #expect(abs(range.end.seconds - 2) < 0.01)
        #expect(abs(videoRange.end.seconds - range.end.seconds) < 0.01)
        let pieces = try await microphone.load(.segments).filter { !$0.isEmpty }
        #expect(pieces.count == 2)
        #expect(abs(pieces[0].timeMapping.source.duration.seconds - 2) < 0.01)
        #expect(abs(pieces[0].timeMapping.target.duration.seconds - 1) < 0.01)

        // Each track gets its own source's volume.
        let mix = RecordingComposition.audioMix(edited) { $0 == .microphone ? 0.8 : 0.3 }
        var volumes: [CMPersistentTrackID: Float] = [:]
        for parameters in mix.inputParameters {
            var start: Float = -1, end: Float = -1
            var ramp = CMTimeRange.zero
            #expect(parameters.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &ramp))
            volumes[parameters.trackID] = start
        }
        #expect(volumes == [microphoneID: 0.8, systemID: 0.3])

        // A muted track is left out of the export, the rest stays.
        let silent = RecordingComposition.exportAsset(edited) { _ in 0 }
        #expect(try await silent.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await silent.loadTracks(withMediaType: .video).contains { $0.trackID == edited.videoTrackID })
        let voiceOnly = RecordingComposition.exportAsset(edited) { $0 == .system ? 0 : 1 }
        let kept = try await voiceOnly.loadTracks(withMediaType: .audio)
        #expect(kept.map(\.trackID) == [microphoneID])

        // The export mixes it down to AAC in the MP4, at the edited length.
        let output = folder.appendingPathComponent("export.mp4")
        // Through the app's own compositor, as the editor exports.
        let renderer = RecordingRenderer(scene: RenderScene(
            style: RecordingStyle(), motion: .empty, pointSize: CGSize(width: 64, height: 64), sourceSize: CGSize(width: 64, height: 64),
            wallpaper: nil, customBackground: nil
        ))
        let videoComposition = try await RecordingComposition.videoComposition(
            for: voiceOnly, composition: edited, timeline: ClipTimeline(segments), renderer: renderer, renderSize: CGSize(width: 64, height: 64)
        )
        try await RecordingComposition.export(voiceOnly, videoComposition: videoComposition, audioMix: mix, to: output) { _ in }
        let exported = AVURLAsset(url: output)
        let exportedAudio = try #require(try await exported.loadTracks(withMediaType: .audio).first)
        let formats = try await exportedAudio.load(.formatDescriptions)
        #expect(formats.first?.mediaSubType == .mpeg4AAC)
        #expect(abs(try await exported.load(.duration).seconds - 2) < 0.05)
        withExtendedLifetime(assets) {}
    }

    /// A small H.264 movie, 30 fps.
    private static func writeVideo(to url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
