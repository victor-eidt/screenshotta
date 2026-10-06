import AVFoundation
import CoreImage
import Testing
import VideoToolbox
@testable import ScreenOtter

/// The edited video drawn end to end on real files: a screen track and a camera track through the
/// composition and the compositor, read back frame by frame.
@Suite final class WebcamCompositionTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenOtterWebcamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A movie of `seconds` at 30 fps in one flat sRGB color. `transparentLeftHalf` writes HEVC with alpha,
    /// as transparent window recordings are, with the left half fully transparent.
    static func writeMovie(to url: URL, size: CGSize, seconds: Double, color: (UInt8, UInt8, UInt8), transparentLeftHalf: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: transparentLeftHalf ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        if transparentLeftHalf {
            settings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 30)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let p = base + y * row + x * 4
                    if transparentLeftHalf && x < Int(size.width) / 2 {
                        p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0
                    } else {
                        p[0] = color.2; p[1] = color.1; p[2] = color.0; p[3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// The color of one pixel (top-left origin) of a frame, in sRGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private struct Fixture {
        /// The camera's color as it decodes on its own (saturated colors shift a little through H.264).
        let cameraColor: (r: Int, g: Int, b: Int)
        let composition: EditedComposition
        let videoComposition: AVVideoComposition
        let renderSize: CGSize
        let bubble: CGRect
    }

    /// A gray screen and a green camera that starts `offset` seconds into the recording.
    private func fixture(segments: [ClipSegment], offset: Double, webcamSeconds: Double = 2) async throws -> Fixture {
        let screenURL = folder.appendingPathComponent("recording.mov")
        let webcamURL = folder.appendingPathComponent("camera.mov")
        let screenSize = CGSize(width: 640, height: 360)
        try await Self.writeMovie(to: screenURL, size: screenSize, seconds: 2, color: (128, 128, 128))
        try await Self.writeMovie(to: webcamURL, size: CGSize(width: 320, height: 180), seconds: webcamSeconds, color: (40, 200, 90))

        let screenAsset = AVURLAsset(url: screenURL)
        let screenTrack = try #require(try await screenAsset.loadTracks(withMediaType: .video).first)
        let webcamAsset = AVURLAsset(url: webcamURL)
        let webcamTrack = try #require(try await webcamAsset.loadTracks(withMediaType: .video).first)
        let webcam = SourceWebcam(track: webcamTrack, duration: try await webcamAsset.load(.duration).seconds, offset: offset)
        let composition = try RecordingComposition.make(track: screenTrack, trackDuration: 2, segments: segments, webcam: webcam)
        #expect(composition.webcamTrackID != nil)

        var style = RecordingStyle()
        style.padding = 0
        style.cornerRadius = 0
        style.shadow = 0
        style.showCursor = false
        style.webcam.shape = .circle
        style.webcam.size = .large
        style.webcam.border = false
        style.webcam.shadow = false
        let renderer = RecordingRenderer(scene: RenderScene(
            style: style, motion: .empty, pointSize: screenSize, sourceSize: screenSize,
            wallpaper: nil, customBackground: nil, webcam: style.webcam
        ))
        let renderSize = RecordingRenderer.canvasSize(style: style, sourceSize: screenSize)
        let videoComposition = try await RecordingComposition.videoComposition(
            for: composition.asset, composition: composition, timeline: ClipTimeline(segments), renderer: renderer, renderSize: renderSize
        )
        let cameraFrame = try await AVAssetImageGenerator(asset: webcamAsset).image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        // Keeps both assets alive until here: their tracks only weakly reference them.
        _ = screenAsset
        return Fixture(cameraColor: Self.pixel(cameraFrame, x: 10, y: 10), composition: composition, videoComposition: videoComposition, renderSize: renderSize, bubble: WebcamLayout.frame(style.webcam, canvas: renderSize))
    }

    private func frame(_ fixture: Fixture, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: fixture.composition.asset)
        generator.videoComposition = fixture.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    @Test func cameraIsDrawnInItsBubbleOverTheScreen() async throws {
        let fixture = try await fixture(segments: [ClipSegment(start: 0, end: 2)], offset: -0.2)
        let image = try await frame(fixture, at: 1)
        #expect(CGSize(width: image.width, height: image.height) == fixture.renderSize)

        let screen = Self.pixel(image, x: 40, y: 40)
        // The screen keeps its color through the compositor (within encoding noise).
        #expect(abs(screen.r - 128) <= 4 && abs(screen.g - 128) <= 4 && abs(screen.b - 128) <= 4)
        let bubble = Self.pixel(image, x: Int(fixture.bubble.midX), y: Int(fixture.bubble.midY))
        let camera = fixture.cameraColor
        #expect(abs(bubble.r - camera.r) <= 4 && abs(bubble.g - camera.g) <= 4 && abs(bubble.b - camera.b) <= 4)
        #expect(bubble.g > bubble.r + 100, "Green stays green: no channels swapped")
        // Outside the circle, in the corner of its frame, the screen shows.
        let corner = Self.pixel(image, x: Int(fixture.bubble.minX) + 2, y: Int(fixture.bubble.minY) + 2)
        #expect(abs(corner.g - 128) <= 4)
    }

    /// The screen alone through the compositor, which every draft without a camera now goes through too.
    private func screenOnlyFrame(transparentLeftHalf: Bool, style: RecordingStyle) async throws -> (image: CGImage, renderSize: CGSize) {
        let screenURL = folder.appendingPathComponent("recording.mov")
        let screenSize = CGSize(width: 640, height: 360)
        try await Self.writeMovie(to: screenURL, size: screenSize, seconds: 2, color: (128, 128, 128), transparentLeftHalf: transparentLeftHalf)
        let screenAsset = AVURLAsset(url: screenURL)
        let screenTrack = try #require(try await screenAsset.loadTracks(withMediaType: .video).first)
        let segments = [ClipSegment(start: 0, end: 2)]
        let composition = try RecordingComposition.make(track: screenTrack, trackDuration: 2, segments: segments, webcam: nil)
        #expect(composition.webcamTrackID == nil)

        let renderer = RecordingRenderer(scene: RenderScene(
            style: style, motion: .empty, pointSize: screenSize, sourceSize: screenSize,
            wallpaper: nil, customBackground: nil, webcam: nil
        ))
        let renderSize = RecordingRenderer.canvasSize(style: style, sourceSize: screenSize)
        let videoComposition = try await RecordingComposition.videoComposition(
            for: composition.asset, composition: composition, timeline: ClipTimeline(segments), renderer: renderer, renderSize: renderSize
        )
        let instruction = try #require(videoComposition.instructions.first as? RecordingCompositionInstruction)
        #expect(instruction.requiredSourceTrackIDs?.compactMap { ($0 as? NSNumber)?.int32Value } == [composition.videoTrackID])
        #expect(instruction.webcamTrackID == nil)

        let generator = AVAssetImageGenerator(asset: composition.asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        _ = screenAsset
        return (image, renderSize)
    }

    private static var flatStyle: RecordingStyle {
        var style = RecordingStyle()
        style.padding = 0
        style.cornerRadius = 0
        style.shadow = 0
        style.showCursor = false
        return style
    }

    @Test func aRecordingWithoutACameraDrawsTheScreenAlone() async throws {
        let (image, renderSize) = try await screenOnlyFrame(transparentLeftHalf: false, style: Self.flatStyle)
        #expect(CGSize(width: image.width, height: image.height) == renderSize)
        for (x, y) in [(40, 40), (image.width - 40, image.height - 40), (image.width / 2, image.height / 2)] {
            let screen = Self.pixel(image, x: x, y: y)
            #expect(abs(screen.r - 128) <= 4 && abs(screen.g - 128) <= 4 && abs(screen.b - 128) <= 4)
        }
    }

    /// Transparent window recordings keep their alpha through the compositor: the background shows through.
    @Test func transparentPartsOfTheRecordingShowTheBackground() async throws {
        var style = Self.flatStyle
        style.background = .color(3)
        let (image, _) = try await screenOnlyFrame(transparentLeftHalf: true, style: style)
        let background = BackgroundArt.color(3).components!.map { Int(($0 * 255).rounded()) }
        let clear = Self.pixel(image, x: image.width / 4, y: image.height / 2)
        #expect(abs(clear.r - background[0]) <= 6 && abs(clear.g - background[1]) <= 6 && abs(clear.b - background[2]) <= 6)
        let opaque = Self.pixel(image, x: image.width * 3 / 4, y: image.height / 2)
        #expect(abs(opaque.r - 128) <= 4 && abs(opaque.g - 128) <= 4 && abs(opaque.b - 128) <= 4)
    }

    @Test func cameraFollowsCutsOnTheRecordingsClock() async throws {
        // The camera started 0.5 s after the screen and stopped at 1.5 s. The first clip ends before it starts.
        let segments = [ClipSegment(start: 0, end: 0.4), ClipSegment(start: 1, end: 2)]
        let fixture = try await fixture(segments: segments, offset: 0.5, webcamSeconds: 1)
        let center = (x: Int(fixture.bubble.midX), y: Int(fixture.bubble.midY))

        let before = Self.pixel(try await frame(fixture, at: 0.2), x: center.x, y: center.y)
        #expect(abs(before.g - 128) <= 4, "No camera yet: the screen shows where the bubble goes")
        let during = Self.pixel(try await frame(fixture, at: 0.6), x: center.x, y: center.y)
        #expect(abs(during.g - fixture.cameraColor.g) <= 4, "Recording second 1.2, while the camera ran")
        let after = Self.pixel(try await frame(fixture, at: 1.2), x: center.x, y: center.y)
        #expect(abs(after.g - 128) <= 4, "Recording second 1.8, after the camera stopped")
    }

    private static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return try #require(buffer)
    }

    @Test func cameraFileStartsAtItsFirstFrame() async throws {
        let url = folder.appendingPathComponent("camera.mov")
        let writer = WebcamFileWriter(url: url)
        let frame = try Self.pixelBuffer(width: 320, height: 180)
        // Host-clock times, 30 fps for a second, with one late duplicate that must be dropped.
        for i in 0..<30 {
            writer.append(frame, at: CMTime(seconds: 500 + Double(i) / 30, preferredTimescale: 1_000_000_000))
            if i == 10 { writer.append(frame, at: CMTime(seconds: 500 + 5.0 / 30, preferredTimescale: 1_000_000_000)) }
            try await Task.sleep(for: .milliseconds(1))
        }
        let first = try #require(await writer.finish())
        #expect(abs(first - 500) < 1e-6)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.02)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
    }

    @Test func cameraFileWithNoFramesLeavesNothing() async throws {
        let url = folder.appendingPathComponent("camera.mov")
        let writer = WebcamFileWriter(url: url)
        #expect(await writer.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
