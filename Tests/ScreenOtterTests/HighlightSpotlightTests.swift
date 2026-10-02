import AppKit
import Foundation
import Testing
@testable import ScreenOtter

// MARK: - Highlighter

@Suite struct HighlighterGeometryTests {
    static let height: CGFloat = 36

    @Test func shiftKeepsTheStrokeOnItsLine() {
        let start = CGPoint(x: 40, y: 120)
        #expect(HighlighterGeometry.snapped(CGPoint(x: 400, y: 133), from: start) == CGPoint(x: 400, y: 120))
        #expect(HighlighterGeometry.snapped(CGPoint(x: -20, y: 80), from: start) == CGPoint(x: -20, y: 120))
    }

    @Test func aHorizontalStrokeIsExactlyAsTallAsItsWeight() {
        let box = HighlighterGeometry.outline([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)], height: Self.height).boundingBoxOfPath
        // Within a pixel: the nib's eased corners trim the very tips.
        #expect(abs(box.height - Self.height) < 1)
        #expect(abs(box.midY - 100) < 0.5)
        // The nib's lean pushes the ends a little past where the stroke started and finished, never far.
        #expect(box.minX < 100 && box.minX > 100 - Self.height * 0.4)
        #expect(box.maxX > 300 && box.maxX < 300 + Self.height * 0.4)
    }

    @Test func theEndsAreCutOnASlantLikeAChiselNib() {
        let outline = HighlighterGeometry.outline([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)], height: Self.height)
        let h = Self.height
        // The nib leans right at the top: ink reaches past the end above the line, not below it.
        #expect(outline.contains(CGPoint(x: 300 + h * 0.2, y: 100 - h * 0.4)))
        #expect(!outline.contains(CGPoint(x: 300 + h * 0.2, y: 100 + h * 0.4)))
        // And the other way round at the start.
        #expect(outline.contains(CGPoint(x: 100 - h * 0.2, y: 100 + h * 0.4)))
        #expect(!outline.contains(CGPoint(x: 100 - h * 0.2, y: 100 - h * 0.4)))
    }

    @Test func aVerticalStrokeIsNarrowerButNeverAHairline() {
        let box = HighlighterGeometry.outline([CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 300)], height: Self.height).boundingBoxOfPath
        #expect(box.width < Self.height * 0.8)
        #expect(box.width >= Self.height * HighlighterGeometry.nibThickness)
    }

    @Test func smoothingKeepsTheEndsAndDropsJitter() {
        let raw = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.2), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 5), CGPoint(x: 30, y: 0)]
        let smooth = HighlighterGeometry.smoothed(raw, spacing: 1)
        #expect(smooth.first == raw.first)
        #expect(smooth.last == raw.last)
        #expect(!smooth.contains(CGPoint(x: 0.3, y: 0.2)))
        // Corner cutting rounds the peak off.
        #expect(smooth.map(\.y).max()! < 5)
        #expect(HighlighterGeometry.smoothed([CGPoint(x: 1, y: 1)]) == [CGPoint(x: 1, y: 1)])
    }

    @Test func hullsWindTheSameWay() {
        // `outline` fills its pieces as a union only if every hull turns the same way.
        func signedArea(_ p: [CGPoint]) -> CGFloat {
            zip(p, p.dropFirst() + [p[0]]).reduce(0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) } / 2
        }
        let a = HighlighterGeometry.convexHull([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 3), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
        let b = HighlighterGeometry.convexHull([CGPoint(x: 0, y: 10), CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 0)])
        #expect(a.count == 4 && b.count == 4)
        #expect(signedArea(a) > 0 && signedArea(b) > 0)
    }
}

@Suite struct HighlightAnnotationTests {
    func stroke(_ points: [CGPoint], weight: StrokeWeight = .regular) -> Annotation {
        Annotation(kind: .highlight, start: points[0], end: points.last!, points: points, style: AnnotationStyle(markerWeight: weight), scale: 2)
    }

    @Test func heightFollowsTheMarkerWeightAndTheScale() {
        #expect(stroke([.zero, CGPoint(x: 100, y: 0)]).highlighterHeight == StrokeWeight.regular.highlighterPoints * 2)
        #expect(stroke([.zero, CGPoint(x: 100, y: 0)], weight: .bold).highlighterHeight == StrokeWeight.bold.highlighterPoints * 2)
        #expect(StrokeWeight.allCases.map(\.highlighterPoints) == StrokeWeight.allCases.map(\.highlighterPoints).sorted())
        // The shapes' weight doesn't size the marker.
        let heavyArrows = Annotation(kind: .highlight, start: .zero, end: CGPoint(x: 100, y: 0), points: [.zero, CGPoint(x: 100, y: 0)],
                                     style: AnnotationStyle(weight: .heavy), scale: 2)
        #expect(heavyArrows.highlighterHeight == StrokeWeight.regular.highlighterPoints * 2)
    }

    @Test func theWholeBandIsHittable() {
        let a = stroke([CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100)])
        let half = a.highlighterHeight / 2
        #expect(a.hitTest(CGPoint(x: 250, y: 100 + half - 1), tolerance: 0))
        #expect(!a.hitTest(CGPoint(x: 250, y: 100 + half + 8), tolerance: 4))
        #expect(a.bounds.contains(CGPoint(x: 250, y: 100 - half + 1)))
    }

    @Test func aClickIsDegenerate() {
        #expect(stroke([CGPoint(x: 10, y: 10)]).isDegenerate)
        #expect(stroke([CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 10)]).isDegenerate)
        #expect(!stroke([CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10)]).isDegenerate)
    }

    @Test func movingCarriesThePoints() {
        var a = stroke([CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 12)])
        a.translate(by: CGPoint(x: 5, y: -2))
        #expect(a.points == [CGPoint(x: 15, y: 8), CGPoint(x: 65, y: 10)])
    }
}

// MARK: - Tools and style

@Suite struct HighlightSpotlightToolTests {
    @Test func shortcutsAreHAndSAndNoTwoToolsShareAKey() {
        #expect(EditorTool.highlight.shortcutKey == "h")
        #expect(EditorTool.spotlight.shortcutKey == "s")
        let keys = EditorTool.allCases.map(\.shortcutKey)
        #expect(Set(keys).count == keys.count)
        // Number keys pick colors, so no tool may take one.
        #expect(keys.allSatisfy { $0.wholeNumberValue == nil })
    }

    @Test func eachToolKeepsItsOwnKindSelected() {
        #expect(EditorTool.highlight.keepsSelection(of: .highlight))
        #expect(EditorTool.spotlight.keepsSelection(of: .spotlight))
        #expect(!EditorTool.spotlight.keepsSelection(of: .redact))
        #expect(!EditorTool.redact.keepsSelection(of: .spotlight))
        #expect(!EditorTool.arrow.keepsSelection(of: .highlight))
        #expect(EditorTool.select.keepsSelection(of: .spotlight))
    }

    @Test func spotlightsAndRedactionsAreRegions() {
        #expect(Annotation.Kind.spotlight.isRegion && Annotation.Kind.redact.isRegion)
        #expect(!Annotation.Kind.highlight.isRegion && !Annotation.Kind.rectangle.isRegion)
    }

    @Test func theMarkerDefaultsToASoftYellowApartFromTheShapeColor() {
        let style = AnnotationStyle()
        #expect(style.marker == HighlighterPalette.swatches[0].color)
        #expect(style.marker != style.color)
        #expect(style.marker.isLight)
        #expect(style.spotlight == .dim)
        // Every marker tint is light, so text multiplied under it stays dark.
        #expect(HighlighterPalette.swatches.allSatisfy { $0.color.luminance > HighlighterPalette.minimumLuminance })
    }

    @Test func darkCustomInkIsLiftedUntilTextStaysReadable() {
        for hex in ["#000000", "#0B1F4D", "#C0142B", "#1C1C21"] {
            let dark = StyleColor(hex: hex)!
            let ink = HighlighterPalette.ink(dark)
            #expect(ink.luminance > HighlighterPalette.minimumLuminance, "\(hex) → \(ink.hex)")
            // Only as much white as it takes: still clearly its own hue, not a near-white.
            #expect(ink.luminance < 0.6, "\(hex) → \(ink.hex)")
        }
        // A navy keeps its blue lead.
        let navy = HighlighterPalette.ink(StyleColor(hex: "#0B1F4D")!)
        #expect(navy.blue > navy.red && navy.blue > navy.green)
        // Light colors, and every tint, are kept as they are.
        for swatch in HighlighterPalette.swatches {
            #expect(HighlighterPalette.ink(swatch.color) == swatch.color)
        }
    }

    @Test func palettesFindSwatchesByColorAndNumberKey() {
        let marker = HighlighterPalette.swatches
        #expect(marker.swatch(for: marker[2].color)?.name == marker[2].name)
        #expect(marker.swatch(forKey: "1")?.name == marker[0].name)
        #expect(marker.swatch(forKey: "6") == nil)
        #expect(marker.swatch(for: AnnotationPalette.swatches[0].color) == nil)
    }

    @Test func oldSavedStylesGetTheDefaultMarkerAndSpotlight() throws {
        // A style saved before the highlighter and spotlight existed.
        let old = Data(##"{"color":"#3B7BFF","weight":"bold","font":"geist","label":"outlined","redaction":"pixelate"}"##.utf8)
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: old)
        #expect(style.marker == AnnotationStyle.default.marker)
        #expect(style.spotlight == AnnotationStyle.default.spotlight)
        #expect(style.markerWeight == AnnotationStyle.default.markerWeight)
        #expect(style.redaction == .pixelate && style.weight == .bold)

        let saved = AnnotationStyle(marker: HighlighterPalette.swatches[3].color, markerWeight: .fine, spotlight: .blur)
        let roundTrip = try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(saved))
        #expect(roundTrip == saved)
    }
}

@Suite final class EditorDocumentHighlightSpotlightTests {
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
        let annotation = Annotation(kind: kind, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 50),
                                    points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10)], style: doc.style, scale: doc.scale)
        doc.add(annotation)
        return annotation.id
    }

    @Test func colorsPickedForTheHighlighterGoToItsInk() {
        let doc = makeDocument()
        let shapeColor = doc.style.color
        doc.tool = .highlight
        #expect(doc.isStylingHighlight)
        #expect(doc.displayedColor == doc.style.marker)
        doc.pickColor(HighlighterPalette.swatches[2].color)
        #expect(doc.style.marker == HighlighterPalette.swatches[2].color)
        #expect(doc.style.color == shapeColor)

        doc.tool = .arrow
        #expect(!doc.isStylingHighlight)
        doc.pickColor(AnnotationPalette.swatches[4].color)
        #expect(doc.style.color == AnnotationPalette.swatches[4].color)
        #expect(doc.style.marker == HighlighterPalette.swatches[2].color)
    }

    @Test func theHighlighterKeepsItsOwnWeight() {
        let doc = makeDocument()
        doc.tool = .arrow
        doc.pickWeight(.heavy)
        doc.tool = .highlight
        #expect(doc.displayedWeight == .regular)
        doc.pickWeight(.fine)
        #expect(doc.style.markerWeight == .fine)
        #expect(doc.style.weight == .heavy)
        doc.tool = .arrow
        #expect(doc.displayedWeight == .heavy)
        #expect(doc.palette.map(\.name) == AnnotationPalette.swatches.map(\.name))
    }

    @Test func aDarkColorPickedForTheMarkerIsLifted() {
        let doc = makeDocument()
        doc.tool = .highlight
        #expect(doc.palette.map(\.name) == HighlighterPalette.swatches.map(\.name))
        doc.pickColor(StyleColor(hex: "#000000")!)
        #expect(doc.style.marker.luminance > HighlighterPalette.minimumLuminance)
    }

    @Test func recoloringASelectedStrokeIsOneUndoStep() {
        let doc = makeDocument()
        let id = add(.highlight, to: doc)
        doc.tool = .select
        doc.selectedID = id
        #expect(doc.isStylingHighlight)
        doc.pickColor(HighlighterPalette.swatches[1].color)
        #expect(doc.annotations.first { $0.id == id }?.style.marker == HighlighterPalette.swatches[1].color)
        doc.undo()
        #expect(doc.annotations.first { $0.id == id }?.style.marker == HighlighterPalette.default)
    }

    @Test func pickingASpotlightModeSwitchesEverySpotlightInOneUndoStep() {
        let doc = makeDocument()
        doc.tool = .spotlight
        #expect(doc.isStylingSpotlight && !doc.isStylingRedaction)
        let first = add(.spotlight, to: doc)
        let second = add(.spotlight, to: doc)

        doc.pickSpotlight(.blur)
        #expect(doc.style.spotlight == .blur)
        #expect(doc.annotations.filter { $0.kind == .spotlight }.allSatisfy { $0.style.spotlight == .blur })
        // Picking the mode they already have changes nothing, and adds no undo step.
        doc.pickSpotlight(.blur)

        doc.undo()
        #expect(doc.annotations.first { $0.id == first }?.style.spotlight == .dim)
        #expect(doc.annotations.first { $0.id == second }?.style.spotlight == .dim)
        #expect(doc.annotations.count == 2)
    }

    @Test func afterUndoNewSpotlightsJoinTheOverlayAsItLooks() {
        let doc = makeDocument()
        doc.tool = .spotlight
        let first = add(.spotlight, to: doc)
        doc.pickSpotlight(.blur)
        // Redo brings blur back, for new ones too.
        doc.undo()
        doc.redo()
        #expect(doc.annotations.allSatisfy { $0.style.spotlight == .blur })
        #expect(doc.style.spotlight == .blur)
        doc.undo()
        // The spotlight is back to dim, and so is the mode new ones get.
        #expect(doc.annotations.first { $0.id == first }?.style.spotlight == .dim)
        #expect(doc.style.spotlight == .dim)
        #expect(doc.displayedStyle.spotlight == .dim)
        _ = add(.spotlight, to: doc)
        #expect(doc.annotations.count == 2)
        #expect(doc.annotations.allSatisfy { $0.style.spotlight == .dim })
    }

    @Test func theChipStylesASpotlightWithTheToolOrASelectedOne() {
        let doc = makeDocument()
        let id = add(.spotlight, to: doc)
        doc.tool = .select
        #expect(!doc.isStylingSpotlight)
        doc.selectedID = id
        #expect(doc.isStylingSpotlight)
        doc.tool = .spotlight
        #expect(doc.selectedID == id)
        doc.tool = .redact
        #expect(doc.selectedID == nil)
    }
}

// MARK: - Spotlight

@Suite struct SpotlightGeometryTests {
    @Test func cornersAreContinuousAndFitTheArea() {
        let big = CGRect(x: 0, y: 0, width: 600, height: 300)
        #expect(SpotlightGeometry.cornerRadius(for: big, scale: 2) == SpotlightGeometry.cornerPoints * 2)
        let thin = CGRect(x: 0, y: 0, width: 600, height: 20)
        #expect(SpotlightGeometry.cornerRadius(for: thin, scale: 2) <= ContinuousCorners.maxRadius(for: thin))
    }

    @Test func theHoleCoversTheAreaWithRoundedCorners() {
        let visible = CGRect(x: 0, y: 0, width: 640, height: 240)
        let rect = CGRect(x: 100, y: 60, width: 200, height: 100)
        let hole = SpotlightGeometry.hole(for: rect, in: visible, scale: 2)
        #expect(hole.contains(CGPoint(x: 101, y: 110)) && hole.contains(CGPoint(x: 200, y: 61)))
        #expect(!hole.contains(CGPoint(x: 90, y: 110)))
        // The very corner is outside the rounded outline.
        #expect(!hole.contains(CGPoint(x: 101, y: 61)))
        // Flush with the visible edge, it reaches past it: no dimmed wedges in the corners.
        let flush = SpotlightGeometry.hole(for: CGRect(x: 0, y: 0, width: 200, height: 100), in: visible, scale: 2)
        #expect(flush.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(flush.boundingBoxOfPath.minX < 0 && flush.boundingBoxOfPath.minY < 0)
    }

    @Test func onlySpotlightsThatLightSomethingInViewAreShown() {
        let visible = CGRect(x: 0, y: 0, width: 300, height: 200)
        func spot(_ rect: CGRect) -> Annotation {
            Annotation(kind: .spotlight, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY), style: AnnotationStyle(), scale: 2)
        }
        let inView = spot(CGRect(x: 20, y: 20, width: 100, height: 60))
        let cropped = spot(CGRect(x: 400, y: 20, width: 100, height: 60))
        let click = spot(CGRect(x: 50, y: 50, width: 2, height: 2))
        let redaction = Annotation(kind: .redact, start: .zero, end: CGPoint(x: 80, y: 80), style: AnnotationStyle(), scale: 2)
        #expect(SpotlightRenderer.shown([inView, cropped, click, redaction], in: visible).map(\.id) == [inView.id])
        #expect(SpotlightRenderer.shown([cropped, click], in: visible).isEmpty)
    }

    @Test func theNewestSpotlightSetsTheMode() {
        func spot(_ mode: SpotlightMode) -> Annotation {
            Annotation(kind: .spotlight, start: .zero, end: CGPoint(x: 50, y: 50), style: AnnotationStyle(spotlight: mode), scale: 2)
        }
        #expect(SpotlightGeometry.mode(of: []) == .dim)
        #expect(SpotlightGeometry.mode(of: [spot(.dim), spot(.blur)]) == .blur)
        #expect(SpotlightMode.dim.toggled == .blur && SpotlightMode.blur.toggled == .dim)
    }
}

/// Renders documents and reads their pixels back, to check what an export actually contains.
@Suite struct HighlightSpotlightRenderingTests {
    typealias Pixels = RedactionRenderingTests.Pixels
    static let size = RedactionRenderingTests.size
    static let area = CGRect(x: 200, y: 60, width: 240, height: 120)

    static func spotlight(_ rect: CGRect = area, mode: SpotlightMode = .dim) -> Annotation {
        Annotation(kind: .spotlight, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY),
                   style: AnnotationStyle(spotlight: mode), scale: 2)
    }

    static func render(_ image: CGImage, _ annotations: [Annotation]) throws -> Pixels {
        Pixels(try #require(RedactionRenderingTests.document(image, annotations).render()))
    }

    static var white: CGImage { RedactionRenderingTests.solidImage(.white) }

    @Test func outsideIsDimmedAndInsideIsUntouched() throws {
        let px = try Self.render(Self.white, [Self.spotlight()])
        let dimmed = Int((1 - SpotlightGeometry.dimAlpha) * 255 + CGFloat(SpotlightGeometry.dimColor.red) * SpotlightGeometry.dimAlpha)
        for (x, y) in [(20, 20), (600, 220), (100, 120)] {
            #expect(abs(px.rgb(x, y)[0] - dimmed) <= 3, "outside (\(x), \(y)): \(px.rgb(x, y))")
        }
        // Lit to within a couple of points of the edge: the soft edge is tight and settles mostly outside.
        let a = Self.area
        #expect(px.rgb(Int(a.midX), Int(a.midY)).allSatisfy { $0 == 255 })
        for (x, y) in [(Int(a.minX) + 4, Int(a.midY)), (Int(a.maxX) - 5, Int(a.midY)), (Int(a.midX), Int(a.minY) + 4), (Int(a.midX), Int(a.maxY) - 5)] {
            #expect(px.rgb(x, y).allSatisfy { $0 >= 248 }, "inside (\(x), \(y)): \(px.rgb(x, y))")
        }
        // And it is soft: halfway through, the edge is neither lit nor fully dimmed.
        #expect((150...240).contains(px.rgb(Int(a.minX), Int(a.midY))[0]), "\(px.rgb(Int(a.minX), Int(a.midY)))")
    }

    @Test func overlappingAreasLightTheirUnion() throws {
        let a = CGRect(x: 100, y: 60, width: 200, height: 100)
        let b = CGRect(x: 250, y: 100, width: 200, height: 100)
        let px = try Self.render(Self.white, [Self.spotlight(a), Self.spotlight(b)])
        for (x, y) in [(275, 130), (150, 80), (420, 180)] {
            #expect(px.rgb(x, y).allSatisfy { $0 >= 250 }, "(\(x), \(y)): \(px.rgb(x, y))")
        }
        #expect(px.rgb(420, 80)[0] < 200)
    }

    @Test func anAreaFlushWithTheEdgeLightsTheCorner() throws {
        let px = try Self.render(Self.white, [Self.spotlight(CGRect(x: 0, y: 0, width: 200, height: 100))])
        #expect(px.rgb(0, 0).allSatisfy { $0 >= 250 }, "\(px.rgb(0, 0))")
    }

    @Test func annotationsStayBrightOverTheDim() throws {
        let arrow = Annotation(kind: .line, start: CGPoint(x: 20, y: 200), end: CGPoint(x: 180, y: 200),
                               style: AnnotationStyle(color: StyleColor(hex: "#FFFFFF")!, weight: .heavy), scale: 2)
        let px = try Self.render(RedactionRenderingTests.solidImage(.black), [Self.spotlight(), arrow])
        #expect(px.rgb(100, 200).allSatisfy { $0 >= 250 }, "\(px.rgb(100, 200))")
    }

    @Test func blurModeSoftensOnlyTheOutside() throws {
        let image = RedactionRenderingTests.stripedImage()
        let dim = try Self.render(image, [Self.spotlight(mode: .dim)])
        let blur = try Self.render(image, [Self.spotlight(mode: .blur)])
        let a = Self.area
        #expect(dim.rgb(Int(a.midX), Int(a.midY)) == blur.rgb(Int(a.midX), Int(a.midY)))
        // Outside, neighboring stripes run together.
        let outside = (0..<40).map { abs(blur.rgb(20 + $0, 20)[0] - blur.rgb(21 + $0, 20)[0]) }.max()!
        let sharp = (0..<40).map { abs(dim.rgb(20 + $0, 20)[0] - dim.rgb(21 + $0, 20)[0]) }.max()!
        #expect(outside < sharp / 2)
    }

    @Test func aRedactionOutsideABlurredSpotlightStillHides() throws {
        // The blur is taken from the original pixels; the redaction must be drawn after it, or the
        // secret would come back, softly blurred, over its own redaction.
        let image = RedactionRenderingTests.textImage()
        let redaction = RedactionRenderingTests.redaction(.pixelate)
        let farAway = CGRect(x: 20, y: 10, width: 100, height: 40)
        let dim = try Self.render(image, [redaction, Self.spotlight(farAway, mode: .dim)])
        let blur = try Self.render(image, [redaction, Self.spotlight(farAway, mode: .blur)])
        let (xs, ys) = RedactionRenderingTests.inner(RedactionRenderingTests.region)
        for y in stride(from: ys.lowerBound, to: ys.upperBound, by: 7) {
            for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 13) {
                #expect(dim.rgb(x, y) == blur.rgb(x, y))
            }
        }
    }

    @Test func blurModeDoesNotSpreadWhatARedactionHides() throws {
        // A secret with structure coarser than the blur, that the redaction averages to one tone: black on
        // the left, white on the right. Next to it, the same picture with the secret already redacted.
        let rect = CGRect(x: 300, y: 100, width: 40, height: 40)
        let ctx = CGContext(data: nil, width: Int(Self.size.width), height: Int(Self.size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: Self.size))
        ctx.setFillColor(.black)
        // Core Graphics is y-up: the rect's left half, upright.
        ctx.fill(CGRect(x: rect.minX, y: Self.size.height - rect.maxY, width: rect.width / 2, height: rect.height))
        let secret = ctx.makeImage()!
        let redaction = RedactionRenderingTests.redaction(.blur, rect)
        let alreadyRedacted = try #require(RedactionRenderingTests.document(secret, [redaction]).render())

        let spot = Self.spotlight(CGRect(x: 20, y: 10, width: 100, height: 40), mode: .blur)
        let leaked = try Self.render(secret, [redaction, spot])
        let clean = try Self.render(alreadyRedacted, [redaction, spot])
        // Just outside the redaction, where a blur of the original would pull in the black and the white.
        for x in [Int(rect.minX) - 2, Int(rect.minX) - 5, Int(rect.maxX) + 1, Int(rect.maxX) + 4] {
            let y = Int(rect.midY)
            #expect(zip(leaked.rgb(x, y), clean.rgb(x, y)).allSatisfy { abs($0 - $1) <= 3 }, "(\(x), \(y)): \(leaked.rgb(x, y)) vs \(clean.rgb(x, y))")
        }
    }

    @Test(arguments: SpotlightMode.allCases)
    func aTransparentMarginStaysTransparent(_ mode: SpotlightMode) throws {
        // A window capture on a transparent background: the window, and clear padding around it.
        let ctx = CGContext(data: nil, width: Int(Self.size.width), height: Int(Self.size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(origin: .zero, size: Self.size))
        ctx.setFillColor(.white)
        let window = CGRect(x: 40, y: 30, width: Self.size.width - 80, height: Self.size.height - 60)
        ctx.fill(window)
        let px = try Self.render(ctx.makeImage()!, [Self.spotlight(mode: mode)])
        for (x, y) in [(5, 5), (20, 120), (Int(Self.size.width) - 10, 200), (320, 236)] {
            #expect(px.alpha(x, y) == 0, "(\(x), \(y)) alpha \(px.alpha(x, y))")
        }
        // The window outside the lit area is dimmed, and still opaque.
        #expect(px.alpha(80, 60) == 255)
        #expect(px.rgb(80, 60)[0] < 160)
    }

    @Test func aSpotlightCroppedOutOfViewDimsNothing() throws {
        let doc = RedactionRenderingTests.document(Self.white, [Self.spotlight(CGRect(x: 20, y: 20, width: 100, height: 60))])
        doc.pendingCrop = CGRect(x: 300, y: 0, width: 300, height: 240)
        doc.applyCrop()
        let px = Pixels(try #require(doc.render()))
        #expect(px.rgb(100, 100).allSatisfy { $0 == 255 }, "\(px.rgb(100, 100))")
    }

    @Test func markerInkMultipliesSoTextStaysDark() throws {
        // Half black, half white, with a yellow stroke across both.
        let ctx = CGContext(data: nil, width: Int(Self.size.width), height: Int(Self.size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: Self.size))
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: 0, y: 0, width: Self.size.width / 2, height: Self.size.height))
        let stroke = Annotation(kind: .highlight, start: CGPoint(x: 40, y: 120), end: CGPoint(x: 600, y: 120),
                                points: [CGPoint(x: 40, y: 120), CGPoint(x: 600, y: 120)], style: AnnotationStyle(), scale: 2)
        let px = try Self.render(ctx.makeImage()!, [stroke])
        let onWhite = px.rgb(500, 120), onBlack = px.rgb(150, 120)
        // On white it takes the marker's tint: warm, with the blue pulled down.
        #expect(onWhite[0] >= 240 && onWhite[2] < 160, "\(onWhite)")
        // On black (text) it stays dark: still readable, just tinted.
        #expect(onBlack.allSatisfy { $0 < 70 }, "\(onBlack)")
        #expect(onBlack[0] > 10, "the glow should make it visible on dark interfaces: \(onBlack)")
    }

    @Test func aStrokeThatCrossesItselfInksEvenly() throws {
        let zigzag = [CGPoint(x: 60, y: 120), CGPoint(x: 400, y: 120), CGPoint(x: 120, y: 124), CGPoint(x: 560, y: 120)]
        let stroke = Annotation(kind: .highlight, start: zigzag[0], end: zigzag.last!, points: zigzag, style: AnnotationStyle(), scale: 2)
        let px = try Self.render(Self.white, [stroke])
        // Where the band runs over itself it's no darker than where it runs once.
        let once = px.rgb(500, 120), twice = px.rgb(250, 121)
        #expect(zip(once, twice).allSatisfy { abs($0 - $1) <= 2 }, "\(once) vs \(twice)")
    }
}
