import AVFoundation
import Foundation
import Testing
@testable import ScreenOtter

@Suite struct RecordingCompositionTests {
    /// Screen recordings only have a frame where the screen changed. The edited video still needs one
    /// every 1/60 s, or the pointer (drawn on top) only moves when something else on screen does.
    @Test func drawsSixtyFramesASecondOverAStillRecording() async throws {
        try await withStillRecording { composition, videoComposition in
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: try await composition.loadTracks(withMediaType: .video),
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.videoComposition = videoComposition
            reader.add(output)
            #expect(reader.startReading())
            #expect(abs(Self.countFrames(output) - 90) <= 2)
        }
    }

    @Test func exportsSixtyFramesASecondOverAStillRecording() async throws {
        try await withStillRecording { composition, videoComposition in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            try await RecordingComposition.export(composition, videoComposition: videoComposition, to: url) { _ in }

            let exported = AVURLAsset(url: url)
            let tracks = try await exported.loadTracks(withMediaType: .video)
            #expect(tracks.count == 1)
            let reader = try AVAssetReader(asset: exported)
            let output = AVAssetReaderTrackOutput(track: try #require(tracks.first), outputSettings: nil)
            reader.add(output)
            #expect(reader.startReading())
            #expect(abs(Self.countFrames(output) - 90) <= 2)
        }
    }

    private static func countFrames(_ output: AVAssetReaderOutput) -> Int {
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        return frames
    }

    /// A 1.5 s recording with three frames, cut and drawn the way the editor does it.
    private func withStillRecording(_ body: (AVMutableComposition, AVVideoComposition) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TestVideo.write(to: url, frameTimes: [0, 0.5, 1.0], duration: 1.5)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let duration = try await asset.load(.duration).seconds
        let segments = [ClipSegment(start: 0, end: duration)]
        let composition = try RecordingComposition.make(track: track, trackDuration: duration, segments: segments)
        let size = CGSize(width: 64, height: 64)
        let renderer = RecordingRenderer(scene: RenderScene(
            style: RecordingStyle(), motion: .empty, pointSize: size, sourceSize: size, wallpaper: nil, customBackground: nil
        ))
        let videoComposition = try await RecordingComposition.videoComposition(
            for: composition, timeline: ClipTimeline(segments), renderer: renderer, renderSize: size
        )
        try await body(composition, videoComposition)
    }
}
