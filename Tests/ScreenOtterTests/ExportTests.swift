import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import ScreenOtter

// MARK: - Sizes

@Suite struct ExportResolutionTests {
    @Test func longSideScalesDownToFitAndKeepsEvenSides() {
        let size = ExportResolution.longSide(1920).pixelSize(canvas: CGSize(width: 3456, height: 2234))
        #expect(size == CGSize(width: 1920, height: 1242))
        // Vertical canvases are limited by their height.
        #expect(ExportResolution.longSide(1920).pixelSize(canvas: CGSize(width: 2160, height: 3840)) == CGSize(width: 1080, height: 1920))
    }

    @Test func longSideAndWidthNeverUpscale() {
        let small = CGSize(width: 1201, height: 801)
        #expect(ExportResolution.longSide(3840).pixelSize(canvas: small) == CGSize(width: 1202, height: 802))
        #expect(ExportResolution.width(1600).pixelSize(canvas: small) == CGSize(width: 1202, height: 802))
    }

    @Test func widthFollowsTheCanvasHeight() {
        #expect(ExportResolution.width(800).pixelSize(canvas: CGSize(width: 2400, height: 1350)) == CGSize(width: 800, height: 450))
    }

    @Test func exactIsExactWhateverTheCanvas() {
        let exact = ExportResolution.exact(width: 1270, height: 760)
        #expect(exact.pixelSize(canvas: CGSize(width: 640, height: 360)) == CGSize(width: 1270, height: 760))
        #expect(exact.pixelSize(canvas: CGSize(width: 5000, height: 5000)) == CGSize(width: 1270, height: 760))
    }

    @Test func degenerateCanvasStillGivesAFrame() {
        #expect(ExportResolution.longSide(1920).pixelSize(canvas: .zero) == CGSize(width: 2, height: 2))
    }
}

// MARK: - Templates

@Suite struct ExportTemplateTests {
    @Test func idsAreUniqueAndEveryTemplateHasAVariant() {
        let ids = ExportTemplate.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for template in ExportTemplate.all {
            #expect(!template.variants.isEmpty)
            #expect(Set(template.variants.map(\.id)).count == template.variants.count)
        }
    }

    private func settings(_ id: String, _ variant: String? = nil) throws -> (ExportTemplate.Variant, ExportSettings) {
        let template = try #require(ExportTemplate.template(id))
        let v = template.variant(variant)
        return (v, v.settings)
    }

    @Test func platformSpecs() throws {
        let (x, xs) = try settings("x")
        #expect(x.aspect == .wide && xs == ExportSettings(format: .mp4, resolution: .exact(width: 1920, height: 1080), fps: 60))

        let (square, ss) = try settings("linkedin", "square")
        #expect(square.aspect == .square && ss.resolution == .exact(width: 1080, height: 1080) && ss.format == .mp4)
        let (portrait, ps) = try settings("linkedin", "portrait")
        #expect(portrait.aspect == .portrait && ps.resolution == .exact(width: 1080, height: 1350))

        let (reels, rs) = try settings("vertical")
        #expect(reels.aspect == .vertical && rs == ExportSettings(format: .mp4, resolution: .exact(width: 1080, height: 1920), fps: 30))

        #expect(try settings("youtube", "1080p").1.resolution == .exact(width: 1920, height: 1080))
        #expect(try settings("youtube", "4k").1.resolution == .exact(width: 3840, height: 2160))

        let (_, ph) = try settings("producthunt")
        #expect(ph.format == .gif && ph.resolution == .exact(width: 1270, height: 760))

        let (dribbble, ds) = try settings("dribbble")
        #expect(dribbble.aspect == .standard && ds.resolution == .exact(width: 1600, height: 1200) && ds.format == .mp4)

        let (readme, rm) = try settings("readme")
        #expect(readme.aspect == nil, "A README GIF keeps the canvas chosen in the editor")
        #expect(rm == ExportSettings(format: .gif, resolution: .width(800), fps: 15))
    }

    /// Exact sizes match the canvas they set, so nothing is letterboxed. Product Hunt's 1270 × 760 is the one
    /// exception: no aspect ratio in the editor is that shape, and 16:9 is the closest.
    @Test func exactSizesMatchTheirCanvas() {
        for template in ExportTemplate.all where template.id != "producthunt" {
            for variant in template.variants {
                guard case let .exact(width, height) = variant.settings.resolution, let ratio = variant.aspect?.ratio else { continue }
                #expect(abs(CGFloat(width) / CGFloat(height) - ratio) < 0.001, "\(template.id) \(variant.id)")
            }
        }
    }

    @Test func unknownVariantFallsBackToTheFirst() throws {
        let youtube = try #require(ExportTemplate.template("youtube"))
        #expect(youtube.variant("8k").id == "1080p")
        #expect(youtube.variant(nil).id == "1080p")
    }

    @Test func portraitAspectIsFourByFive() {
        #expect(RecordingAspect.portrait.ratio == 0.8)
        #expect(RecordingAspect.portrait.title == "4:5")
        let canvas = RecordingRenderer.canvasSize(style: { var s = RecordingStyle(); s.padding = 0; s.aspect = .portrait; return s }(), sourceSize: CGSize(width: 1000, height: 1000))
        #expect(canvas == CGSize(width: 1000, height: 1250))
    }
}

// MARK: - Remembered choice

@Suite struct ExportChoiceTests {
    @Test func defaultIsTheOldMP4Export() {
        let settings = ExportChoice().settings
        #expect(settings == ExportSettings(format: .mp4, resolution: .longSide(1920), fps: 60))
    }

    @Test func roundTrips() throws {
        var choice = ExportChoice()
        choice.templateID = "linkedin"
        choice.variants["linkedin"] = "portrait"
        choice.custom.format = .gif
        choice.custom.gifFPS = 24
        let decoded = try JSONDecoder().decode(ExportChoice.self, from: JSONEncoder().encode(choice))
        #expect(decoded == choice)
        #expect(decoded.settings.resolution == .exact(width: 1080, height: 1350))
    }

    @Test func emptyOrPartialDataFallsBackToDefaults() throws {
        let empty = try JSONDecoder().decode(ExportChoice.self, from: Data("{}".utf8))
        #expect(empty == ExportChoice())
        let partial = try JSONDecoder().decode(ExportChoice.self, from: Data(#"{"custom":{"format":"gif"}}"#.utf8))
        #expect(partial.custom.format == .gif)
        #expect(partial.custom.gifSize == 800 && partial.custom.gifFPS == 15)
    }

    @Test func removedTemplatesAndOptionsFallBack() throws {
        let json = #"{"templateID":"myspace","custom":{"format":"webm","videoSize":720,"videoFPS":25,"gifSize":333,"gifFPS":50}}"#
        let choice = try JSONDecoder().decode(ExportChoice.self, from: Data(json.utf8))
        #expect(choice.templateID == nil)
        #expect(choice.custom == CustomExport())
    }

    @Test func savedChoiceSurvivesDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "ScreenOtterExportTests-\(UUID().uuidString)"))
        #expect(ExportChoice.saved(in: defaults) == ExportChoice())
        var choice = ExportChoice()
        choice.templateID = "readme"
        choice.save(in: defaults)
        #expect(ExportChoice.saved(in: defaults).template?.id == "readme")
        defaults.set(Data("not json".utf8), forKey: "exportChoice")
        #expect(ExportChoice.saved(in: defaults) == ExportChoice())
    }

    @Test func customSettingsFollowTheFormat() {
        var custom = CustomExport()
        custom.videoSize = .ultraHD
        custom.videoFPS = 30
        #expect(custom.settings == ExportSettings(format: .mp4, resolution: .longSide(3840), fps: 30))
        #expect(custom.summary == "MP4 · 4K · 30 fps")
        custom.format = .gif
        custom.gifSize = 640
        custom.gifFPS = 10
        #expect(custom.settings == ExportSettings(format: .gif, resolution: .longSide(640), fps: 10))
        #expect(custom.summary == "GIF · 640 px · 10 fps")
    }

    @Test func templateExportsGetANameSuffix() {
        var choice = ExportChoice()
        #expect(choice.fileSuffix == nil)
        choice.templateID = "x"
        #expect(choice.fileSuffix == "X Twitter")
        choice.templateID = "producthunt"
        #expect(choice.fileSuffix == "Product Hunt")
    }

    /// Drafts saved before 4:5 existed decode as before; ones saved with it decode it, and an aspect this
    /// version doesn't know falls back to Auto rather than failing the whole style.
    @Test func styleAspectDecodingStaysCompatible() throws {
        let old = try JSONDecoder().decode(RecordingStyle.self, from: Data(#"{"aspect":"vertical","padding":0.1}"#.utf8))
        #expect(old.aspect == .vertical && old.padding == 0.1)
        let portrait = try JSONDecoder().decode(RecordingStyle.self, from: Data(#"{"aspect":"portrait"}"#.utf8))
        #expect(portrait.aspect == .portrait)
        let future = try JSONDecoder().decode(RecordingStyle.self, from: Data(#"{"aspect":"cinema"}"#.utf8))
        #expect(future.aspect == .auto)
    }
}

// MARK: - GIF timing and size

@Suite struct GIFMathTests {
    @Test func delaysAddUpExactly() {
        for fps in [10, 15, 24] {
            let times = (0...fps).map { Double($0) / Double(fps) }
            let delays = zip(times, times.dropFirst()).map { GIFTiming.delay(from: $0, to: $1) }
            #expect(delays.reduce(0, +) == 100, "\(fps) fps")
            #expect(delays.allSatisfy { $0 >= GIFTiming.minimumDelay })
        }
        // 15 fps alternates instead of drifting.
        #expect(Set((0..<15).map { GIFTiming.delay(from: Double($0) / 15, to: Double($0 + 1) / 15) }) == [6, 7])
    }

    @Test func delayNeverGoesUnderTheBrowserMinimum() {
        #expect(GIFTiming.delay(from: 0, to: 0.001) == 2)
        #expect(GIFTiming.delay(from: 1, to: 1) == 2)
    }

    @Test func estimateGrowsWithWhatItShouldGrowWith() {
        let size = CGSize(width: 800, height: 450)
        let base = GIFEstimate.bytes(size: size, duration: 10, fps: 15)
        #expect(GIFEstimate.bytes(size: size, duration: 20, fps: 15) > base)
        #expect(GIFEstimate.bytes(size: size, duration: 10, fps: 24) > base)
        #expect(GIFEstimate.bytes(size: CGSize(width: 1270, height: 760), duration: 10, fps: 15) > base)
        let moving = GIFEstimate.bytes(size: size, duration: 10, fps: 15, zoom: .init(moving: 2, held: 0))
        let held = GIFEstimate.bytes(size: size, duration: 10, fps: 15, zoom: .init(moving: 0, held: 2))
        #expect(moving > held && held > base)
        #expect(GIFEstimate.bytes(size: size, duration: 10, fps: 15, webcamShare: 0.05) > base)
        // A still README GIF stays well under a megabyte.
        #expect(base < 1_000_000)
        // Zoom time beyond the video's length doesn't run away.
        #expect(GIFEstimate.bytes(size: size, duration: 1, fps: 15, zoom: .init(moving: 50, held: 50)) < GIFEstimate.bytes(size: size, duration: 2, fps: 15, zoom: .init(moving: 2, held: 0)))
    }

    @Test func zoomTimeFollowsTheCut() {
        let zoom = ZoomSegment(start: 2, end: 5, scale: 2, isAuto: true)
        let all = [ClipSegment(start: 0, end: 10)]
        // In over 1 s, settled for 2 s, out over 1 s.
        #expect(GIFEstimate.zoomTime(zooms: [zoom], segments: all, zoomIn: 1, zoomOut: 1) == .init(moving: 2, held: 2))
        // At 2× everything takes half as long.
        #expect(GIFEstimate.zoomTime(zooms: [zoom], segments: [ClipSegment(start: 0, end: 10, speed: 2)], zoomIn: 1, zoomOut: 1) == .init(moving: 1, held: 1))
        // Cut out of the video, it doesn't count.
        #expect(GIFEstimate.zoomTime(zooms: [zoom], segments: [ClipSegment(start: 7, end: 10)], zoomIn: 1, zoomOut: 1) == .init())
        // Overlapping or nearly touching zooms are one zoom: the camera doesn't zoom out between them.
        let next = ZoomSegment(start: 5.5, end: 7, scale: 2, isAuto: false)
        #expect(GIFEstimate.zoomTime(zooms: [next, zoom], segments: all, zoomIn: 1, zoomOut: 1) == .init(moving: 2, held: 4))
        #expect(GIFEstimate.zoomTime(zooms: [zoom], segments: []) == .init())
    }

    @Test func labels() {
        #expect(GIFEstimate.label(40_000) == "under 0.1 MB")
        #expect(GIFEstimate.label(3_420_000) == "about 3.4 MB")
        #expect(GIFEstimate.label(12_600_000) == "about 13 MB")
    }
}

// MARK: - GIF file

@Suite final class GIFWriterTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenOtterGIFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A BGRA frame in one color, with an optional square of another.
    private func frame(width: Int, height: Int, color: (UInt8, UInt8, UInt8), square: (rect: CGRect, color: (UInt8, UInt8, UInt8))? = nil) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var c = color
                if let square, square.rect.contains(CGPoint(x: x, y: y)) { c = square.color }
                let i = (y * width + x) * 4
                pixels[i] = c.2; pixels[i + 1] = c.1; pixels[i + 2] = c.0
            }
        }
        return pixels
    }

    private func write(_ frames: [(pixels: [UInt8], time: Double)], width: Int, height: Int, end: Double) throws -> URL {
        let url = folder.appendingPathComponent("test.gif")
        let palette = GIFPalette.make(frames: frames.map(\.pixels), width: width, height: height, stride: 1)
        let writer = try GIFWriter(url: url, width: width, height: height, palette: palette)
        for frame in frames {
            frame.pixels.withUnsafeBytes { writer.append(pixels: $0.baseAddress!, bytesPerRow: width * 4, time: frame.time) }
        }
        try writer.finish(endTime: end)
        return url
    }

    @Test func loopsForeverMergesStillFramesAndKeepsEarlierFramesUnderneath() throws {
        let (w, h) = (64, 40)
        let red = frame(width: w, height: h, color: (220, 40, 40))
        let withSquare = frame(width: w, height: h, color: (220, 40, 40), square: (CGRect(x: 40, y: 10, width: 12, height: 12), (30, 60, 230)))
        let url = try write([(red, 0), (red, 0.1), (withSquare, 0.2), (withSquare, 0.3)], width: w, height: h, end: 0.4)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        // The repeated frames were merged into the one before.
        #expect(CGImageSourceGetCount(source) == 2)
        let fileGIF = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect((fileGIF?[kCGImagePropertyGIFLoopCount] as? Int) == 0)

        func delay(_ index: Int) -> Double? {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        }
        #expect(abs((delay(0) ?? 0) - 0.2) < 0.001)
        #expect(abs((delay(1) ?? 0) - 0.2) < 0.001)

        // Every frame leaves itself in place, so the second, which only holds the square, shows the red around it.
        let data = try Data(contentsOf: url)
        #expect(try GIFFile.disposals(in: data) == [1, 1])
        let second = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        let around = WebcamCompositionTests.pixel(second, x: 5, y: 5)
        #expect(around.r > 180 && around.g < 80 && around.b < 80)
        let inSquare = WebcamCompositionTests.pixel(second, x: 46, y: 16)
        #expect(inSquare.b > 180 && inSquare.r < 80)
    }

    @Test func tinyFlickerDoesNotCountAsChange() throws {
        let (w, h) = (32, 32)
        let gray = frame(width: w, height: h, color: (128, 128, 128))
        let flicker = frame(width: w, height: h, color: (130, 127, 129))
        let url = folder.appendingPathComponent("flicker.gif")
        let writer = try GIFWriter(url: url, width: w, height: h, palette: GIFPalette.make(frames: [gray], width: w, height: h))
        for (pixels, time) in [(gray, 0.0), (flicker, 0.1)] {
            pixels.withUnsafeBytes { writer.append(pixels: $0.baseAddress!, bytesPerRow: w * 4, time: time) }
        }
        try writer.finish(endTime: 0.2)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
    }

    /// Every pixel the file shows is exactly a palette color: ImageIO only looked the colors up.
    @Test func framesUseThePaletteExactly() throws {
        let (w, h) = (48, 24)
        let a = frame(width: w, height: h, color: (250, 250, 252))
        let b = frame(width: w, height: h, color: (250, 250, 252), square: (CGRect(x: 4, y: 4, width: 10, height: 10), (17, 24, 39)))
        let url = try write([(a, 0), (b, 0.1)], width: w, height: h, end: 0.2)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let second = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        let light = WebcamCompositionTests.pixel(second, x: 30, y: 20)
        #expect(light.r == 250 && light.g == 250 && light.b == 252)
        let dark = WebcamCompositionTests.pixel(second, x: 8, y: 8)
        #expect(dark.r == 17 && dark.g == 24 && dark.b == 39)
    }

    @Test func malformedFilesAreRejected() {
        var junk = Data("not a gif at all".utf8)
        #expect(throws: GIFExportError.self) { try GIFFile.keepPreviousFrames(in: &junk) }
        var truncated = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x21, 0xF9, 0x04])
        #expect(throws: GIFExportError.self) { try GIFFile.keepPreviousFrames(in: &truncated) }
    }

    /// A template's exact size and frame rate reach the MP4, whatever the recording's own shape.
    @Test func exportsAnMP4AtATemplateSizeAndFrameRate() async throws {
        let movie = folder.appendingPathComponent("recording.mov")
        let screen = CGSize(width: 320, height: 180)
        try await WebcamCompositionTests.writeMovie(to: movie, size: screen, seconds: 1, color: (90, 160, 220))
        let asset = AVURLAsset(url: movie)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let segments = [ClipSegment(start: 0, end: 1)]
        let composition = try RecordingComposition.make(track: track, trackDuration: 1, segments: segments)
        let settings = try #require(ExportTemplate.template("linkedin")).variant("portrait").settings
        var style = RecordingStyle()
        style.showCursor = false
        style.aspect = .portrait
        let renderer = RecordingRenderer(scene: RenderScene(
            style: style, motion: .empty, pointSize: screen, sourceSize: screen, wallpaper: nil, customBackground: nil
        ))
        let size = settings.resolution.pixelSize(canvas: RecordingRenderer.canvasSize(style: style, sourceSize: screen))
        let videoComposition = try await RecordingComposition.videoComposition(
            for: composition.asset, composition: composition, timeline: ClipTimeline(segments), renderer: renderer,
            renderSize: size, frameRate: settings.fps
        )
        let url = folder.appendingPathComponent("export.mp4")
        try await RecordingComposition.export(composition.asset, videoComposition: videoComposition, audioMix: nil, to: url) { _ in }
        _ = asset

        let output = AVURLAsset(url: url)
        let video = try #require(try await output.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1080, height: 1350))
        let rate = try await video.load(.nominalFrameRate)
        #expect(abs(rate - 30) < 1)
    }

    /// The whole path: a recording through the composition and compositor, read back at the GIF's frame rate.
    @Test func exportsARecordingAsAGIF() async throws {
        let movie = folder.appendingPathComponent("recording.mov")
        let screen = CGSize(width: 320, height: 180)
        try await WebcamCompositionTests.writeMovie(to: movie, size: screen, seconds: 1, color: (90, 160, 220))
        let asset = AVURLAsset(url: movie)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let segments = [ClipSegment(start: 0, end: 1)]
        let composition = try RecordingComposition.make(track: track, trackDuration: 1, segments: segments)
        var style = RecordingStyle()
        style.showCursor = false
        let renderer = RecordingRenderer(scene: RenderScene(
            style: style, motion: .empty, pointSize: screen, sourceSize: screen, wallpaper: nil, customBackground: nil
        ))
        let size = ExportResolution.width(200).pixelSize(canvas: RecordingRenderer.canvasSize(style: style, sourceSize: screen))
        let videoComposition = try await RecordingComposition.videoComposition(
            for: composition.asset, composition: composition, timeline: ClipTimeline(segments), renderer: renderer, renderSize: size, frameRate: 10
        )
        #expect(videoComposition.frameDuration == CMTime(value: 1, timescale: 10))
        let url = folder.appendingPathComponent("export.gif")
        try await GIFExport.export(composition.asset, videoComposition: videoComposition, to: url) { _ in }
        _ = asset

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) >= 1)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CGSize(width: first.width, height: first.height) == size)
        // The recording sits in the middle, its color intact through quantization.
        let middle = WebcamCompositionTests.pixel(first, x: first.width / 2, y: first.height / 2)
        #expect(abs(middle.r - 90) <= 12 && abs(middle.g - 160) <= 12 && abs(middle.b - 220) <= 12)
        // The delays add up to the video's length.
        var total = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            total += gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
        }
        #expect(abs(total - 1) < 0.02)
    }
}

// MARK: - Palette

@Suite struct GIFPaletteTests {
    /// A BGRA frame: the left half a horizontal gradient from `from` to `to`, the right half one flat color.
    private func frame(width: Int, height: Int, from: (Double, Double, Double), to: (Double, Double, Double), flat: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if x < width / 2 {
                    let t = Double(x) / Double(width / 2 - 1)
                    pixels[i + 2] = UInt8((from.0 + (to.0 - from.0) * t).rounded())
                    pixels[i + 1] = UInt8((from.1 + (to.1 - from.1) * t).rounded())
                    pixels[i] = UInt8((from.2 + (to.2 - from.2) * t).rounded())
                } else {
                    pixels[i + 2] = flat.0; pixels[i + 1] = flat.1; pixels[i] = flat.2
                }
            }
        }
        return pixels
    }

    @Test func flatColorsAreKeptExactly() {
        let pixels = frame(width: 256, height: 32, from: (30, 27, 75), to: (168, 85, 247), flat: (255, 255, 255))
        let palette = GIFPalette.make(frames: [pixels], width: 256, height: 32)
        #expect(palette.colors.contains(GIFColor(r: 255, g: 255, b: 255)))
        #expect(palette.colors.count <= GIFPalette.maximumColors)
        let quantizer = GIFQuantizer(palette: palette)
        let white = Int(quantizer.index(r: 255, g: 255, b: 255, x: 7, y: 3))
        #expect(palette.colors[white] == GIFColor(r: 255, g: 255, b: 255))
    }

    @Test func aSmallPaletteStillAveragesGradientsOut() {
        // Few colors for a long gradient: dithering has to carry it.
        let (w, h) = (512, 16)
        let pixels = frame(width: w, height: h, from: (30, 27, 75), to: (168, 85, 247), flat: (255, 255, 255))
        let palette = GIFPalette.make(frames: [pixels], width: w, height: h, stride: 1, maximumColors: 24)
        let quantizer = GIFQuantizer(palette: palette)
        // Over 16 × 16 blocks, the dithered colors average out close to the source.
        for blockX in Swift.stride(from: 0, to: w / 2 - 16, by: 16) {
            var sum = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            for y in 0..<16 {
                for x in blockX..<(blockX + 16) {
                    let i = (y * w + x) * 4
                    let c = palette.colors[Int(quantizer.index(r: pixels[i + 2], g: pixels[i + 1], b: pixels[i], x: x, y: y))]
                    sum.0 += Double(c.r); sum.1 += Double(c.g); sum.2 += Double(c.b)
                    sum.3 += Double(pixels[i + 2]); sum.4 += Double(pixels[i + 1]); sum.5 += Double(pixels[i])
                }
            }
            #expect(abs(sum.0 - sum.3) / 256 < 4 && abs(sum.1 - sum.4) / 256 < 4 && abs(sum.2 - sum.5) / 256 < 4, "block at \(blockX)")
        }
    }

    @Test func ditherIsStableForTheSamePixel() {
        let pixels = frame(width: 128, height: 8, from: (0, 0, 0), to: (255, 128, 64), flat: (20, 20, 20))
        let palette = GIFPalette.make(frames: [pixels], width: 128, height: 8, maximumColors: 16)
        let a = GIFQuantizer(palette: palette), b = GIFQuantizer(palette: palette)
        for x in 0..<64 {
            #expect(a.index(r: UInt8(x * 4), g: UInt8(x * 2), b: UInt8(x), x: x, y: 5) == b.index(r: UInt8(x * 4), g: UInt8(x * 2), b: UInt8(x), x: x, y: 5))
        }
    }

    @Test func emptySamplesStillGiveAPalette() {
        let palette = GIFPalette.make(frames: [], width: 10, height: 10)
        #expect(!palette.colors.isEmpty)
        #expect(palette.colorMap.count == palette.colors.count * 3)
    }

    @Test func thresholdsAreSpreadEvenly() {
        var buckets = [Int](repeating: 0, count: 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let t = GIFQuantizer.threshold(x: x, y: y)
                #expect(t >= 0 && t < 1)
                buckets[min(Int(t * 4), 3)] += 1
            }
        }
        #expect(buckets.allSatisfy { abs($0 - 1024) < 160 })
    }
}
