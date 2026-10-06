import AVFoundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum GIFExportError: LocalizedError {
    case cannotCreate
    case cannotRead
    case malformed

    var errorDescription: String? {
        switch self {
        case .cannotCreate: "The GIF couldn't be created."
        case .cannotRead: "The video couldn't be read for the GIF."
        case .malformed: "The GIF couldn't be finished."
        }
    }
}

/// Writes an animated GIF that loops forever, frame by frame, with ImageIO.
///
/// Every frame is drawn with one palette (see `GIFPalette`) and dithered here, positionally, so a pixel
/// that didn't change maps to exactly the same color as before. Each frame then stores only the pixels whose
/// color changed: the rest is transparent and the frame before shows through. Still moments cost almost
/// nothing, frames where nothing changed are merged into the one before, and since ImageIO is given each
/// frame's colors it writes frames as they come, so memory stays flat however long the video.
nonisolated final class GIFWriter {
    let width: Int
    let height: Int

    private let url: URL
    private let destination: CGImageDestination
    private let quantizer: GIFQuantizer
    private let colorMap: Data
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The palette index each pixel shows now, nil before the first frame.
    private var shown: [UInt8]?
    /// The newest frame, held until the next changed one shows how long it stays up.
    private var pending: (image: CGImage, time: Double)?
    private(set) var frameCount = 0

    /// `frameCapacity` is a hint for ImageIO; more frames than that are fine.
    init(url: URL, width: Int, height: Int, palette: GIFPalette, frameCapacity: Int = 0) throws {
        self.url = url
        self.width = width
        self.height = height
        quantizer = GIFQuantizer(palette: palette)
        colorMap = palette.colorMap
        try? FileManager.default.removeItem(at: url)
        guard width > 0, height > 0,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, max(frameCapacity, 1), nil)
        else { throw GIFExportError.cannotCreate }
        self.destination = destination
        // Without a shared table to work out at the end, ImageIO writes each frame as it's added.
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
                kCGImagePropertyGIFHasGlobalColorMap: false,
            ],
        ] as CFDictionary)
    }

    /// Adds the frame shown from `time` (seconds): `pixels` is BGRA, premultiplied, opaque, `width` × `height`.
    func append(pixels: UnsafeRawPointer, bytesPerRow: Int, time: Double) {
        // Zeroed: every pixel left alone is transparent.
        var frame = Data(count: width * height * 4)
        let first = shown == nil
        // Taken out while it's updated, so it isn't copied.
        var indices = shown ?? [UInt8](repeating: 0, count: width * height)
        shown = nil
        var changed = 0
        let colors = quantizer.palette.colors
        frame.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            indices.withUnsafeMutableBufferPointer { indices in
                for y in 0..<height {
                    let row = pixels.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        let p = x * 4
                        let index = quantizer.index(r: row[p + 2], g: row[p + 1], b: row[p], x: x, y: y)
                        let i = y * width + x
                        guard first || indices[i] != index else { continue }
                        indices[i] = index
                        let color = colors[Int(index)]
                        let o = i * 4
                        out[o] = color.b; out[o + 1] = color.g; out[o + 2] = color.r; out[o + 3] = 255
                        changed += 1
                    }
                }
            }
        }
        shown = indices
        // Nothing moved: the frame up now just stays longer.
        guard changed > 0, let image = makeImage(frame) else { return }
        flush(until: time)
        pending = (image, time)
    }

    /// Writes the last frame, shown until `endTime`, and closes the file.
    func finish(endTime: Double) throws {
        flush(until: endTime)
        guard CGImageDestinationFinalize(destination) else { throw GIFExportError.cannotCreate }
        var data = try Data(contentsOf: url)
        try GIFFile.keepPreviousFrames(in: &data)
        try data.write(to: url, options: .atomic)
    }

    private func flush(until time: Double) {
        guard let pending else { return }
        let delay = Double(GIFTiming.delay(from: pending.time, to: time)) / 100
        CGImageDestinationAddImage(destination, pending.image, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
                // The colors are already the palette's: ImageIO only looks them up, without dithering again.
                kCGImagePropertyGIFImageColorMap: colorMap,
            ],
        ] as CFDictionary)
        frameCount += 1
        self.pending = nil
    }

    private func makeImage(_ frame: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: frame as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: Self.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Reads a GIF's blocks, as laid out by the GIF89a spec.
nonisolated enum GIFFile {
    /// Sets every frame to leave itself in place when the next one is drawn ("do not dispose"), so a frame's
    /// transparent pixels show the frames before it. ImageIO marks frames with transparency "restore to
    /// background" and has no option for this. Returns how many frames were changed.
    @discardableResult
    static func keepPreviousFrames(in data: inout Data) throws -> Int {
        try setDisposal(1, in: &data)
    }

    /// Each frame's disposal method, in order.
    static func disposals(in data: Data) throws -> [Int] {
        var copy = data
        var found: [Int] = []
        try walk(&copy) { packed in
            found.append(Int((packed >> 2) & 0x7))
            return packed
        }
        return found
    }

    private static func setDisposal(_ method: UInt8, in data: inout Data) throws -> Int {
        var count = 0
        try walk(&data) { packed in
            count += 1
            return (packed & ~0x1C) | (method << 2)
        }
        return count
    }

    /// Calls `change` with the packed field of every graphic control extension, and stores what it returns.
    private static func walk(_ data: inout Data, change: (UInt8) -> UInt8) throws {
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            func byte(_ i: Int) throws -> UInt8 {
                guard i < n else { throw GIFExportError.malformed }
                return bytes[i]
            }
            /// Skips data sub-blocks starting at `i`; returns the index after the terminator.
            func skipSubBlocks(_ i: Int) throws -> Int {
                var i = i
                while true {
                    let size = Int(try byte(i))
                    i += 1
                    if size == 0 { return i }
                    i += size
                }
            }
            guard n >= 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { throw GIFExportError.malformed } // "GIF"
            var i = 13
            let screen = bytes[10]
            if screen & 0x80 != 0 { i += 3 * (2 << Int(screen & 0x7)) }
            while true {
                switch try byte(i) {
                case 0x3B: // trailer
                    return
                case 0x21: // extension
                    let label = try byte(i + 1)
                    if label == 0xF9 {
                        guard try byte(i + 2) == 4 else { throw GIFExportError.malformed }
                        _ = try byte(i + 3)
                        bytes[i + 3] = change(bytes[i + 3])
                    }
                    i = try skipSubBlocks(i + 2)
                case 0x2C: // image
                    let flags = try byte(i + 9)
                    i += 10
                    if flags & 0x80 != 0 { i += 3 * (2 << Int(flags & 0x7)) }
                    i = try skipSubBlocks(i + 1) // after the LZW minimum code size
                default:
                    throw GIFExportError.malformed
                }
            }
        }
    }
}

nonisolated enum GIFExport {
    /// Renders `asset` through `videoComposition` (whose frame duration sets the frame rate) and writes it as a GIF.
    /// `progress` is called from a background task.
    static func export(
        _ asset: AVAsset,
        videoComposition: AVVideoComposition,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw RecordingCompositionError.noVideo }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GIFExportError.cannotRead }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? GIFExportError.cannotRead }

        let size = videoComposition.renderSize
        let width = Int(size.width), height = Int(size.height)
        let fps = videoComposition.frameDuration.seconds > 0 ? 1 / videoComposition.frameDuration.seconds : 15
        let palette = try await palette(asset, videoComposition: videoComposition, duration: duration, width: width, height: height)
        let writer = try GIFWriter(url: url, width: width, height: height, palette: palette, frameCapacity: Int(duration * fps) + 1)
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                // Frames are let go of as soon as they're written: memory stays flat however long the video.
                autoreleasepool {
                    guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
                    CVPixelBufferLockBaseAddress(pixels, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
                    if let base = CVPixelBufferGetBaseAddress(pixels),
                       CVPixelBufferGetWidth(pixels) == writer.width, CVPixelBufferGetHeight(pixels) == writer.height {
                        writer.append(pixels: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), time: time)
                    }
                }
                if duration > 0 { progress(min(time / duration, 1)) }
            }
            if reader.status == .failed { throw reader.error ?? GIFExportError.cannotRead }
            try writer.finish(endTime: duration)
        } catch {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Frames sampled across the video, so the palette covers zooms and whatever appears later on.
    static let paletteSamples = 9

    private static func palette(_ asset: AVAsset, videoComposition: AVVideoComposition, duration: Double, width: Int, height: Int) async throws -> GIFPalette {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [[UInt8]] = []
        let last = max(duration - 0.05, 0)
        for i in 0..<paletteSamples {
            try Task.checkCancellation()
            let time = CMTime(seconds: last * Double(i) / Double(paletteSamples - 1), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            if drawn { frames.append(pixels) }
        }
        guard !frames.isEmpty else { throw GIFExportError.cannotRead }
        return GIFPalette.make(frames: frames, width: width, height: height)
    }
}
