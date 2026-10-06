import CoreGraphics
import Testing
@testable import ScreenOtter

@Suite struct TextRecognizerTests {
    private func opaqueWhite(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// RGBA bytes of `image`, top row first.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @Test func smallSelectionsAreDoubledWithAMargin() throws {
        let prepared = TextRecognizer.prepare(try opaqueWhite(width: 100, height: 50))
        // 2x, plus 16pt of margin (32px at 2x) on each side.
        #expect(prepared.width == 264)
        #expect(prepared.height == 164)
    }

    @Test func largeSelectionsKeepTheirSizeWithASmallerMargin() throws {
        let prepared = TextRecognizer.prepare(try opaqueWhite(width: 1000, height: 300))
        #expect(prepared.width == 1032)
        #expect(prepared.height == 332)
    }

    /// The margin repeats the edge, so it must be as solid as the content, with no faded seam.
    @Test func theMarginIsOpaqueBackground() throws {
        let prepared = TextRecognizer.prepare(try opaqueWhite(width: 100, height: 40))
        let bytes = try pixels(prepared)
        let width = prepared.width
        for (x, y) in [(0, 0), (width - 1, prepared.height - 1), (10, 60), (32, 40), (33, 41), (120, 1)] {
            let offset = (y * width + x) * 4
            #expect(bytes[offset + 3] == 255, "alpha at \(x),\(y)")
            #expect(bytes[offset] >= 250, "red at \(x),\(y)")
        }
    }
}
