import AppKit
import CoreText
import Foundation
import Testing
@testable import ScreenOtter

@Suite struct RedactionGeometryTests {
    @Test func blocksNeverDropBelowTheMinimum() {
        let line = CGRect(x: 0, y: 0, width: 400, height: 20)
        #expect(RedactionGeometry.blockSize(for: line, scale: 1) == RedactionGeometry.minimumBlockPoints)
        #expect(RedactionGeometry.blockSize(for: line, scale: 2) == RedactionGeometry.minimumBlockPoints * 2)
    }

    @Test func blocksGrowWithTheRegionUpToTheMaximum() {
        let medium = CGRect(x: 0, y: 0, width: 400, height: 40)
        #expect(RedactionGeometry.blockSize(for: medium, scale: 1) == 20)
        let huge = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        #expect(RedactionGeometry.blockSize(for: huge, scale: 2) == RedactionGeometry.maximumBlockPoints * 2)
    }

    @Test func flippedRectsSizeLikeTheirStandardForm() {
        let rect = CGRect(x: 100, y: 100, width: -300, height: -60)
        #expect(RedactionGeometry.blockSize(for: rect, scale: 2) == RedactionGeometry.blockSize(for: rect.standardized, scale: 2))
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 400, height: 40),
        CGRect(x: 3, y: 7, width: 913, height: 61),
        CGRect(x: 0, y: 0, width: 50, height: 2400),
    ])
    func gridFillsTheRectWithBlocksAtLeastTheBlockSize(_ rect: CGRect) {
        for scale in [1.0, 2.0] {
            let block = RedactionGeometry.blockSize(for: rect, scale: scale)
            let (columns, rows) = RedactionGeometry.grid(for: rect, scale: scale)
            #expect(columns >= 1 && rows >= 1)
            #expect(rect.width / CGFloat(columns) >= block)
            #expect(rect.height / CGFloat(rows) >= block)
            // Rounding down never wastes a whole block.
            #expect(rect.width / CGFloat(columns) < block * 2)
            #expect(rect.height / CGFloat(rows) < block * 2)
        }
    }

    @Test func aRegionSmallerThanABlockIsOneBlock() {
        let tiny = CGRect(x: 0, y: 0, width: 9, height: 6)
        #expect(RedactionGeometry.grid(for: tiny, scale: 2) == (1, 1))
    }

    @Test func cornersStaySubtle() {
        let big = CGRect(x: 0, y: 0, width: 600, height: 300)
        #expect(RedactionGeometry.cornerRadius(for: big, scale: 2) == RedactionGeometry.cornerPoints * 2)
        let thin = CGRect(x: 0, y: 0, width: 600, height: 10)
        #expect(RedactionGeometry.cornerRadius(for: thin, scale: 2) <= 2)
        #expect(RedactionGeometry.cornerRadius(for: thin, scale: 2) <= ContinuousCorners.maxRadius(for: thin))
    }

    @Test func areaCoversWholePixelsInsideTheImage() {
        let image = CGRect(x: 0, y: 0, width: 100, height: 80)
        #expect(RedactionGeometry.area(of: CGRect(x: 10.4, y: 5.6, width: 20.2, height: 10), in: image) == CGRect(x: 10, y: 5, width: 21, height: 11))
        #expect(RedactionGeometry.area(of: CGRect(x: 90, y: -10, width: 40, height: 30), in: image) == CGRect(x: 90, y: 0, width: 10, height: 20))
        #expect(RedactionGeometry.area(of: CGRect(x: 200, y: 200, width: 10, height: 10), in: image).isEmpty)
    }

    @Test func sidesOnTheImageEdgeReachPastIt() {
        let image = CGRect(x: 0, y: 0, width: 400, height: 300)
        let inside = CGRect(x: 20, y: 30, width: 100, height: 50)
        #expect(RedactionGeometry.clipRect(for: inside, in: image, radius: 10) == inside)

        let corner = CGRect(x: 0, y: 0, width: 100, height: 50)
        let clip = RedactionGeometry.clipRect(for: corner, in: image, radius: 10)
        #expect(clip.minX < -10 && clip.minY < -10)
        #expect(abs(clip.maxX - 100) < 1e-9 && abs(clip.maxY - 50) < 1e-9)
        // The image's corner pixel is inside the rounded outline, not cut off by it.
        #expect(ContinuousCorners.path(in: clip, radius: 10).contains(CGPoint(x: 0.5, y: 0.5)))

        let overflowing = CGRect(x: 350, y: 280, width: 100, height: 60)
        let pushed = RedactionGeometry.clipRect(for: overflowing, in: image, radius: 10)
        #expect(pushed.maxX > 450 && pushed.maxY > 340)
        #expect(abs(pushed.minX - 350) < 1e-9 && abs(pushed.minY - 280) < 1e-9)
    }

    @Test func pressingBAgainSwitchesTheMode() {
        #expect(RedactionMode.blur.toggled == .pixelate)
        #expect(RedactionMode.pixelate.toggled == .blur)
    }
}

@Suite struct RectResizeTests {
    let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func cornersGrabTwoEdgesAndEdgesGrabOne() {
        #expect(RectResize.edges(at: CGPoint(x: 101, y: 99), of: rect, tolerance: 6) == [.left, .top])
        #expect(RectResize.edges(at: CGPoint(x: 304, y: 203), of: rect, tolerance: 6) == [.right, .bottom])
        #expect(RectResize.edges(at: CGPoint(x: 200, y: 98), of: rect, tolerance: 6) == [.top])
        #expect(RectResize.edges(at: CGPoint(x: 296, y: 150), of: rect, tolerance: 6) == [.right])
    }

    @Test func insideAndFarAwayGrabNothing() {
        #expect(RectResize.edges(at: CGPoint(x: 200, y: 150), of: rect, tolerance: 6).isEmpty)
        #expect(RectResize.edges(at: CGPoint(x: 90, y: 150), of: rect, tolerance: 6).isEmpty)
    }

    @Test func aThinRectPrefersTheNearerOfOpposingEdges() {
        let thin = CGRect(x: 0, y: 0, width: 100, height: 8)
        // Within tolerance of both top and bottom: the top wins, never both.
        #expect(RectResize.edges(at: CGPoint(x: 50, y: 2), of: thin, tolerance: 6) == [.top])
    }

    @Test func aSmallRectKeepsAMiddleBandThatMoves() {
        // A snug box around one line of text, shown small: its middle must not grab an edge.
        let line = CGRect(x: 0, y: 0, width: 160, height: 12)
        #expect(RectResize.edges(at: CGPoint(x: 80, y: 6), of: line, tolerance: 8).isEmpty)
        #expect(RectResize.edges(at: CGPoint(x: 80, y: 4), of: line, tolerance: 8).isEmpty)
        // Its edges still grab, from inside (a quarter of the side) and from the full tolerance outside.
        #expect(RectResize.edges(at: CGPoint(x: 80, y: 2), of: line, tolerance: 8) == [.top])
        #expect(RectResize.edges(at: CGPoint(x: 80, y: 19), of: line, tolerance: 8) == [.bottom])
        #expect(RectResize.edges(at: CGPoint(x: 80, y: 21), of: line, tolerance: 8).isEmpty)
    }

    @Test func movesStopAtTheBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(RectResize.translation(moving: rect, by: CGPoint(x: 30, y: -20), within: bounds) == CGPoint(x: 30, y: -20))
        #expect(RectResize.translation(moving: rect, by: CGPoint(x: 500, y: -500), within: bounds) == CGPoint(x: 100, y: -100))
        // Already sticking out: it can come back in, but not go further out.
        let out = CGRect(x: -20, y: 10, width: 50, height: 50)
        #expect(RectResize.translation(moving: out, by: CGPoint(x: -10, y: 0), within: bounds) == .zero)
        #expect(RectResize.translation(moving: out, by: CGPoint(x: 15, y: 0), within: bounds) == CGPoint(x: 15, y: 0))
    }

    @Test func draggingACornerMovesOnlyItsEdges() {
        let resized = RectResize.resized(rect, edges: [.right, .bottom], by: CGPoint(x: 30, y: -20), minimumSide: 8)
        #expect(resized == CGRect(x: 100, y: 100, width: 230, height: 80))
        let left = RectResize.resized(rect, edges: [.left], by: CGPoint(x: -50, y: 999), minimumSide: 8)
        #expect(left == CGRect(x: 50, y: 100, width: 250, height: 100))
    }

    @Test func edgesStopShortOfTheOppositeOne() {
        let crushed = RectResize.resized(rect, edges: [.left, .top], by: CGPoint(x: 500, y: 500), minimumSide: 8)
        #expect(crushed == CGRect(x: 292, y: 192, width: 8, height: 8))
        let pulled = RectResize.resized(rect, edges: [.right], by: CGPoint(x: -1000, y: 0), minimumSide: 8)
        #expect(pulled.width == 8 && pulled.minX == rect.minX)
    }
}

@Suite struct RedactionAnnotationTests {
    func redaction(_ rect: CGRect, mode: RedactionMode = .pixelate, scale: CGFloat = 2) -> Annotation {
        Annotation(kind: .redact, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY),
                   style: AnnotationStyle(redaction: mode), scale: scale)
    }

    @Test func boundsAreTheRegionAndTheWholeRegionIsHittable() {
        let a = redaction(CGRect(x: 10, y: 10, width: 100, height: 40))
        #expect(a.bounds == CGRect(x: 10, y: 10, width: 100, height: 40))
        #expect(a.hitTest(CGPoint(x: 60, y: 30), tolerance: 0))
        #expect(!a.hitTest(CGPoint(x: 200, y: 30), tolerance: 4))
    }

    @Test func aClickIsDegenerate() {
        #expect(redaction(CGRect(x: 10, y: 10, width: 200, height: 4)).isDegenerate)
        #expect(!redaction(CGRect(x: 10, y: 10, width: 200, height: 20)).isDegenerate)
    }

    @Test func theRedactionToolKeepsARedactionSelected() {
        #expect(EditorTool.redact.keepsSelection(of: .redact))
        #expect(!EditorTool.redact.keepsSelection(of: .text))
        #expect(!EditorTool.arrow.keepsSelection(of: .redact))
        #expect(EditorTool.select.keepsSelection(of: .redact))
        #expect(EditorTool.redact.shortcutKey == "b")
    }

    @Test func oldSavedStylesGetTheDefaultRedaction() throws {
        // A style saved before redactions existed.
        let old = Data(##"{"color":"#3B7BFF","weight":"bold","font":"geist","label":"outlined"}"##.utf8)
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: old)
        #expect(style.redaction == AnnotationStyle.default.redaction)
        #expect(style.label == .outlined)
        let roundTrip = try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(AnnotationStyle(redaction: .pixelate)))
        #expect(roundTrip.redaction == .pixelate)
    }
}

// MARK: - Rendering

/// Renders documents and reads their pixels back, to check what an export actually contains.
@Suite struct RedactionRenderingTests {
    static let size = CGSize(width: 640, height: 240)
    /// The region drawn over the secret text: snug around one line, as people draw them.
    static let region = CGRect(x: 40, y: 90, width: 520, height: 56)

    /// A white screenshot with one line of black text in `region`.
    static func textImage(_ text: String = "card 4111 1111 1111 1111  pin 0042") -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, 26, nil)
        let line = CTLineCreateWithAttributedString(TextLayout.attributed(text, font: font, color: .black))
        // y-up: the baseline sits inside the region (top-left y 90...146).
        ctx.textPosition = CGPoint(x: region.minX + 14, y: size.height - region.maxY + 20)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    static func solidImage(_ color: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    static func document(_ image: CGImage, _ annotations: [Annotation]) -> EditorDocument {
        let defaults = UserDefaults(suiteName: "RedactionTests-\(UUID())")!
        let doc = EditorDocument(capture: CapturedImage(image: image, scale: 2), fileURL: nil, defaults: defaults)
        doc.annotations = annotations
        return doc
    }

    static func redaction(_ mode: RedactionMode, _ rect: CGRect = region) -> Annotation {
        Annotation(kind: .redact, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY),
                   style: AnnotationStyle(redaction: mode), scale: 2)
    }

    /// RGBA bytes, top row first.
    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = data
        }

        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let i = (y * width + x) * 4
            return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
        }
    }

    /// The region's pixels, minus a margin that keeps clear of the rounded corners and their antialiasing.
    static func inner(_ rect: CGRect, margin: Int = 12) -> (xs: Range<Int>, ys: Range<Int>) {
        (Int(rect.minX) + margin..<Int(rect.maxX) - margin, Int(rect.minY) + margin..<Int(rect.maxY) - margin)
    }

    @Test(arguments: RedactionMode.allCases)
    func outsideTheRegionNothingChanges(_ mode: RedactionMode) throws {
        let image = Self.textImage()
        let original = Pixels(image)
        let redacted = Pixels(try #require(Self.document(image, [Self.redaction(mode)]).render()))
        for y in stride(from: 0, to: original.height, by: 3) {
            for x in stride(from: 0, to: original.width, by: 3) where !Self.region.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) {
                #expect(redacted.rgb(x, y) == original.rgb(x, y))
            }
        }
    }

    @Test func pixelateLeavesFlatTilesNoSmallerThanTheMinimum() throws {
        let image = Self.textImage()
        let pixels = Pixels(try #require(Self.document(image, [Self.redaction(.pixelate)]).render()))
        let (columns, rows) = RedactionGeometry.grid(for: Self.region, scale: 2)
        let tileWidth = Self.region.width / CGFloat(columns)
        let tileHeight = Self.region.height / CGFloat(rows)
        #expect(tileWidth >= RedactionGeometry.minimumBlockPoints * 2 && tileHeight >= RedactionGeometry.minimumBlockPoints * 2)
        var shades = Set<[Int]>()
        for row in 0..<rows {
            for column in 0..<columns {
                // Every pixel of a tile (clear of its edges and the rounded corners) is the same color.
                let x0 = Int(Self.region.minX + CGFloat(column) * tileWidth) + 2
                let y0 = Int(Self.region.minY + CGFloat(row) * tileHeight) + 2
                let tile = Set((y0..<y0 + Int(tileHeight) - 4).flatMap { y in (x0..<x0 + Int(tileWidth) - 4).map { pixels.rgb($0, y) } })
                if (row == 0 || row == rows - 1) && (column == 0 || column == columns - 1) { continue }
                #expect(tile.count == 1, "tile \(column),\(row)")
                shades.formUnion(tile)
            }
        }
        // The text's darkness survives as gray tiles; nothing in them is black like a glyph.
        #expect(shades.count > 1)
        #expect(shades.allSatisfy { $0[0] > 60 })
    }

    @Test func blurLeavesNoSharpEdges() throws {
        let image = Self.textImage()
        let original = Pixels(image)
        let pixels = Pixels(try #require(Self.document(image, [Self.redaction(.blur)]).render()))
        let (xs, ys) = Self.inner(Self.region)
        var originalJump = 0
        var redactedJump = 0
        var darkest = 255
        for y in ys {
            for x in xs.dropLast() {
                originalJump = max(originalJump, abs(original.rgb(x + 1, y)[0] - original.rgb(x, y)[0]))
                redactedJump = max(redactedJump, abs(pixels.rgb(x + 1, y)[0] - pixels.rgb(x, y)[0]))
                darkest = min(darkest, pixels.rgb(x, y)[0])
            }
        }
        // Glyph edges jump from white to black in a pixel; the wash moves a few levels at most.
        #expect(originalJump > 200)
        #expect(redactedJump <= 6)
        // Still visibly something there (a soft gray band), not a blank box.
        #expect(darkest < 235)
    }

    @Test(arguments: RedactionMode.allCases)
    func edgesKeepTheirColorInsteadOfDarkening(_ mode: RedactionMode) throws {
        let blue = CGColor(srgbRed: 0.231, green: 0.482, blue: 1, alpha: 1)
        let image = Self.solidImage(blue)
        let original = Pixels(image).rgb(0, 0)
        // A region flush with the image's corner, where clamping matters most.
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        let pixels = Pixels(try #require(Self.document(image, [Self.redaction(mode, rect)]).render()))
        for (x, y) in [(0, 0), (1, 1), (299, 60), (150, 119), (150, 1), (12, 60)] {
            let p = pixels.rgb(x, y)
            #expect(zip(p, original).allSatisfy { abs($0 - $1) <= 2 }, "\(x),\(y): \(p) vs \(original)")
        }
    }

    @Test(arguments: RedactionMode.allCases)
    func annotationsOnTopDontFeedTheRedaction(_ mode: RedactionMode) throws {
        let image = Self.textImage()
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 300, y: 20), end: CGPoint(x: 320, y: 140),
                               style: AnnotationStyle(color: AnnotationPalette.swatches[0].color, weight: .heavy), scale: 2)
        arrow.points = []
        let plain = Pixels(try #require(Self.document(image, [Self.redaction(mode)]).render()))
        // The arrow added before the redaction still draws on top, and the redaction samples the screenshot only.
        let covered = Pixels(try #require(Self.document(image, [arrow, Self.redaction(mode)]).render()))
        let arrowArea = arrow.bounds.insetBy(dx: -40, dy: -40)
        let (xs, ys) = Self.inner(Self.region, margin: 2)
        var compared = 0
        for y in ys {
            for x in xs where !arrowArea.contains(CGPoint(x: x, y: y)) {
                #expect(covered.rgb(x, y) == plain.rgb(x, y))
                compared += 1
            }
        }
        #expect(compared > 1000)
        // The arrow's own pixels are on top of the redaction.
        let tip = covered.rgb(318, 130)
        #expect(tip[0] > 200 && tip[1] < 120)
    }

    /// Vertical black and white stripes a pixel wide: anything redacted turns gray.
    static func stripedImage() -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(.black)
        for x in stride(from: 0, to: Int(size.width), by: 2) {
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: Int(size.height)))
        }
        return ctx.makeImage()!
    }

    @Test(arguments: RedactionMode.allCases)
    func aRegionFlushWithTheCropCoversTheExportsCorner(_ mode: RedactionMode) throws {
        let doc = Self.document(Self.stripedImage(), [])
        let crop = CGRect(x: 100, y: 60, width: 300, height: 120)
        doc.pendingCrop = crop
        doc.applyCrop()
        // Starts exactly at the crop's top-left corner, where a rounded corner would leave original pixels.
        doc.annotations = [Self.redaction(mode, CGRect(x: 100, y: 60, width: 120, height: 80))]
        let pixels = Pixels(try #require(doc.render()))
        #expect(pixels.width == 300 && pixels.height == 120)
        for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1), (2, 2)] {
            let p = pixels.rgb(x, y)[0]
            #expect(p > 40 && p < 215, "\(x),\(y): \(p)")
        }
    }

    @Test func eachRedactionKeepsOneResultWhileItChanges() throws {
        let doc = Self.document(Self.textImage(), [])
        var draft = Self.redaction(.blur, CGRect(x: 40, y: 90, width: 100, height: 40))
        let ctx = CGContext(data: nil, width: 640, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Dragging it out redraws it at a new size every frame.
        for width in stride(from: 100, through: 500, by: 20) {
            draft.end = CGPoint(x: 40 + CGFloat(width), y: 130)
            AnnotationRenderer.drawAll([draft], redactions: doc.redactions, visible: doc.imageBounds, in: ctx, unit: 1)
            #expect(doc.redactions.cachedCount == 1)
        }
        let other = Self.redaction(.pixelate, CGRect(x: 40, y: 10, width: 100, height: 40))
        AnnotationRenderer.drawAll([draft, other], redactions: doc.redactions, visible: doc.imageBounds, in: ctx, unit: 1)
        #expect(doc.redactions.cachedCount == 2)
        // A redaction that's gone (deleted, undone) lets go of its pixels.
        AnnotationRenderer.drawAll([other], redactions: doc.redactions, visible: doc.imageBounds, in: ctx, unit: 1)
        #expect(doc.redactions.cachedCount == 1)
    }

    @Test(arguments: RedactionMode.allCases)
    func differentSecretsOfTheSameShapeLookAlike(_ mode: RedactionMode) throws {
        // Two numbers with the same length and digit widths: once redacted they should be next to
        // indistinguishable, which is what "can't be read back" means in practice.
        let a = Pixels(try #require(Self.document(Self.textImage("card 4111 1111 1111 1111  pin 0042"), [Self.redaction(mode)]).render()))
        let b = Pixels(try #require(Self.document(Self.textImage("card 5306 2849 7713 9025  pin 8167"), [Self.redaction(mode)]).render()))
        let (xs, ys) = Self.inner(Self.region)
        var total = 0
        var count = 0
        for y in ys {
            for x in xs {
                total += abs(a.rgb(x, y)[0] - b.rgb(x, y)[0])
                count += 1
            }
        }
        #expect(Double(total) / Double(count) < 8)
    }
}

// MARK: - Document

/// A class so each test gets its own defaults suite, removed when the test ends.
@Suite final class EditorDocumentRedactionTests {
    private let suiteName = "ScreenOtterTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeDocument() -> EditorDocument {
        let ctx = CGContext(
            data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return EditorDocument(capture: CapturedImage(image: ctx.makeImage()!, scale: 2), fileURL: nil, defaults: defaults)
    }

    private func add(_ kind: Annotation.Kind, to doc: EditorDocument) -> UUID {
        var annotation = Annotation(kind: kind, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 50), style: doc.style, scale: doc.scale)
        if kind == .text { annotation.text = "Label" }
        doc.add(annotation)
        return annotation.id
    }

    @Test func theRedactionToolKeepsARedactionSelectedAndOtherToolsDont() {
        let doc = makeDocument()
        let id = add(.redact, to: doc)
        doc.tool = .select
        doc.selectedID = id
        doc.tool = .redact
        #expect(doc.selectedID == id)
        doc.tool = .text
        #expect(doc.selectedID == nil)

        doc.tool = .select
        doc.selectedID = id
        doc.tool = .arrow
        #expect(doc.selectedID == nil)
    }

    @Test func theTextToolStillKeepsALabelSelected() {
        let doc = makeDocument()
        let id = add(.text, to: doc)
        doc.tool = .select
        doc.selectedID = id
        doc.tool = .text
        #expect(doc.selectedID == id)
        doc.tool = .redact
        #expect(doc.selectedID == nil)
    }

    @Test func pickingAModeRestylesTheSelectionInOneUndoStep() {
        let doc = makeDocument()
        doc.pickRedaction(.blur)
        let id = add(.redact, to: doc)
        doc.tool = .redact
        doc.selectedID = id

        doc.pickRedaction(.pixelate)
        #expect(doc.annotations.first { $0.id == id }?.style.redaction == .pixelate)
        #expect(doc.style.redaction == .pixelate)

        doc.undo()
        #expect(doc.annotations.first { $0.id == id }?.style.redaction == .blur)
    }

    @Test func theChipStylesARedactionWithTheToolOrASelectedRegion() {
        let doc = makeDocument()
        doc.tool = .redact
        #expect(doc.isStylingRedaction)
        #expect(!doc.isStylingText)

        let id = add(.redact, to: doc)
        doc.tool = .select
        #expect(!doc.isStylingRedaction)
        doc.selectedID = id
        #expect(doc.isStylingRedaction)

        doc.selectedID = add(.line, to: doc)
        #expect(!doc.isStylingRedaction)
    }
}
