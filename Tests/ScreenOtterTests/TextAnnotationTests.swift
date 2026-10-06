import AppKit
import Foundation
import Testing
@testable import ScreenOtter

/// Registers the bundled fonts once, from the repository (tests don't run inside the app bundle).
private let bundledFontCount: Int = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return TextFont.registerFonts(in: root.appendingPathComponent("Resources/Fonts"))
}()

@Suite struct TextFontTests {
    @Test func everyFaceIsBundledAndResolvesByName() {
        #expect(bundledFontCount == TextFont.allCases.count)
        for font in TextFont.allCases {
            #expect(CTFontCopyPostScriptName(font.ctFont(size: 20)) as String == font.postScriptName)
        }
    }

    @Test func registeringTwiceIsHarmless() {
        _ = bundledFontCount
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(TextFont.registerFonts(in: root.appendingPathComponent("Resources/Fonts")) == TextFont.allCases.count)
    }

    @Test func missingDirectoryRegistersNothing() {
        #expect(TextFont.registerFonts(in: URL(fileURLWithPath: "/nonexistent/fonts")) == 0)
    }
}

@Suite struct TextLabelMetricsTests {
    @Test func paddingScalesWithTheFontSize() {
        let small = TextLabelMetrics(label: .filled, fontSize: 20)
        let large = TextLabelMetrics(label: .filled, fontSize: 40)
        #expect(large.horizontalPadding == small.horizontalPadding * 2)
        #expect(large.verticalPadding == small.verticalPadding * 2)
        #expect(TextLabelMetrics(label: .plain, fontSize: 20).horizontalPadding < small.horizontalPadding)
    }

    @Test func onlyOutlinesHaveABorder() {
        #expect(TextLabelMetrics(label: .outlined, fontSize: 20).borderWidth > 0)
        #expect(TextLabelMetrics(label: .filled, fontSize: 20).borderWidth == 0)
        #expect(TextLabelMetrics(label: .plain, fontSize: 20).borderWidth == 0)
    }

    @Test func inkOriginInvertsThePlate() {
        let metrics = TextLabelMetrics(label: .outlined, fontSize: 36)
        let ink = CGRect(x: 100, y: 50, width: 200, height: 26)
        let plate = metrics.plate(around: ink)
        #expect(plate.contains(ink))
        #expect(metrics.inkOrigin(forPlateAt: plate.origin) == ink.origin)
    }

    @Test func cornersStayContinuousOnShortPlates() {
        let metrics = TextLabelMetrics(label: .filled, fontSize: 40)
        let plate = CGRect(x: 0, y: 0, width: 300, height: 30)
        #expect(metrics.cornerRadius(for: plate) == ContinuousCorners.maxRadius(for: plate))
        let tall = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(metrics.cornerRadius(for: tall) == 40 * 0.55)
    }
}

@Suite struct TextContrastTests {
    @Test func labelTextContrastsWithThePlate() {
        for swatch in AnnotationPalette.swatches {
            let text = TextContrast.textColor(onPlate: swatch.color)
            #expect(text == (swatch.color.isLight ? TextContrast.ink : TextContrast.white), "\(swatch.name)")
            // Vivid plates keep white text on purpose (the look of a badge in a product shot), which WCAG
            // rates lower than it reads at a label's semibold sizes; nothing falls below 2.2:1.
            let (hi, lo) = (max(text.luminance, swatch.color.luminance), min(text.luminance, swatch.color.luminance))
            #expect((hi + 0.05) / (lo + 0.05) >= 2.2, "\(swatch.name)")
        }
    }

    @Test func outlinesSitOnACalmFill() {
        let blue = AnnotationPalette.swatches[4].color
        let fill = TextContrast.outlineFill(for: blue)
        #expect(fill.luminance > 0.85)
        #expect(TextContrast.outlineFill(for: TextContrast.white).luminance < 0.05)
    }

    @Test func plainShadowIsStrongerUnderLightText() {
        #expect(TextContrast.plainShadowAlpha(for: TextContrast.white) > TextContrast.plainShadowAlpha(for: TextContrast.ink))
    }

    @Test func mixingMovesTowardsTheOtherColor() {
        let black = StyleColor(red: 0, green: 0, blue: 0)
        let white = TextContrast.white
        #expect(black.mixed(with: white, amount: 0.5) == StyleColor(red: 128, green: 128, blue: 128))
        #expect(black.mixed(with: white, amount: 0) == black)
        #expect(black.mixed(with: white, amount: 3) == white)
    }
}

@Suite struct TextResizeTests {
    let anchor = CGPoint(x: 100, y: 100)
    let corner = CGPoint(x: 300, y: 150)

    @Test func draggingTheCornerScalesTheFont() {
        let doubled = CGPoint(x: 500, y: 200)
        #expect(TextResize.fontSize(original: 36, anchor: anchor, corner: corner, current: doubled, scale: 2) == 72)
        #expect(TextResize.fontSize(original: 36, anchor: anchor, corner: corner, current: corner, scale: 2) == 36)
    }

    @Test func sizeIsClampedInPoints() {
        let behind = CGPoint(x: 0, y: 0)
        #expect(TextResize.fontSize(original: 36, anchor: anchor, corner: corner, current: behind, scale: 2) == TextResize.pointRange.lowerBound * 2)
        let far = CGPoint(x: 100_000, y: 100_000)
        #expect(TextResize.fontSize(original: 36, anchor: anchor, corner: corner, current: far, scale: 1) == TextResize.pointRange.upperBound)
    }

    @Test func degenerateDiagonalKeepsTheSize() {
        #expect(TextResize.fontSize(original: 30, anchor: anchor, corner: anchor, current: corner, scale: 1) == 30)
    }
}

@Suite struct ContinuousCornersTests {
    @Test func pathFillsTheRect() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 60)
        let box = ContinuousCorners.path(in: rect, radius: 12).boundingBoxOfPath
        #expect(abs(box.minX - rect.minX) < 0.01 && abs(box.maxX - rect.maxX) < 0.01)
        #expect(abs(box.minY - rect.minY) < 0.01 && abs(box.maxY - rect.maxY) < 0.01)
    }

    @Test func cornersAreCutAndTheMiddleIsSolid() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 60)
        let path = ContinuousCorners.path(in: rect, radius: 15)
        #expect(!path.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(!path.contains(CGPoint(x: 199.5, y: 59.5)))
        #expect(path.contains(CGPoint(x: 100, y: 30)))
        #expect(path.contains(CGPoint(x: 100, y: 0.5)))
    }

    @Test func theCurveCrossesTheDiagonalAtTheInset() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        let r: CGFloat = 40
        let path = ContinuousCorners.path(in: rect, radius: r)
        let d = r * ContinuousCorners.diagonalInset
        // Just inside the bottom-right curve along the diagonal, then just outside it.
        #expect(path.contains(CGPoint(x: rect.maxX - d - 0.3, y: rect.maxY - d - 0.3)))
        #expect(!path.contains(CGPoint(x: rect.maxX - d + 0.3, y: rect.maxY - d + 0.3)))
    }

    @Test func zeroRadiusIsAPlainRect() {
        let rect = CGRect(x: 0, y: 0, width: 50, height: 20)
        #expect(ContinuousCorners.path(in: rect, radius: 0).contains(CGPoint(x: 0.2, y: 0.2)))
    }
}

@Suite struct TextLayoutTests {
    init() { _ = bundledFontCount }

    @Test func widthFollowsTheText() {
        let short = TextLayout(text: "Hi", font: .geist, fontSize: 36, label: .filled, origin: .zero)
        let long = TextLayout(text: "Hi there, friend", font: .geist, fontSize: 36, label: .filled, origin: .zero)
        #expect(long.inkBox.width > short.inkBox.width)
        #expect(TextLayout(text: "", font: .geist, fontSize: 36, label: .filled, origin: .zero).inkBox.width == 0)
    }

    @Test func linesStackByTheLineHeight() {
        let one = TextLayout(text: "One", font: .geist, fontSize: 40, label: .plain, origin: CGPoint(x: 10, y: 20))
        let three = TextLayout(text: "One\nTwo\nThree", font: .geist, fontSize: 40, label: .plain, origin: CGPoint(x: 10, y: 20))
        #expect(three.lines.count == 3)
        #expect(abs(three.inkBox.height - (one.inkBox.height + 2 * one.lineHeight)) < 0.001)
        #expect(three.baseline(ofLine: 0) == 20 + one.capHeight)
        #expect(three.inkBox.origin == CGPoint(x: 10, y: 20))
    }

    @Test func editorFrameStartsOneAscentAboveTheFirstBaseline() {
        let layout = TextLayout(text: "Edit", font: .jakarta, fontSize: 30, label: .filled, origin: CGPoint(x: 5, y: 50))
        #expect(abs(layout.lineBoxesFrame.minY - (layout.baseline(ofLine: 0) - layout.ascent)) < 0.001)
        #expect(layout.lineBoxesFrame.height == layout.lineHeight)
    }
}

@Suite struct TextAnnotationTests {
    init() { _ = bundledFontCount }

    func label(_ text: String, weight: StrokeWeight = .regular, label: TextLabelStyle = .filled) -> Annotation {
        var a = Annotation(kind: .text, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 100, y: 100),
                           style: AnnotationStyle(weight: weight, label: label), scale: 2)
        a.text = text
        return a
    }

    @Test func sizeComesFromTheWeightUnlessResized() {
        var a = label("Hello", weight: .bold)
        #expect(a.fontPointSize == StrokeWeight.bold.textPoints)
        #expect(a.fontPixelSize == StrokeWeight.bold.textPoints * 2)
        a.fontSize = 50
        #expect(a.fontPixelSize == 100)
    }

    @Test func weightsGrowTheText() {
        let sizes = StrokeWeight.allCases.map(\.textPoints)
        #expect(sizes == sizes.sorted())
        #expect(Set(sizes).count == sizes.count)
    }

    @Test func boundsAreThePlateAndHitTestingUsesThem() {
        let a = label("Ship it")
        #expect(a.bounds == TextLayout(a).plate)
        #expect(a.hitTest(CGPoint(x: a.bounds.midX, y: a.bounds.midY), tolerance: 0))
        #expect(!a.hitTest(CGPoint(x: a.bounds.maxX + 20, y: a.bounds.midY), tolerance: 4))
    }

    @Test func blankTextIsDegenerate() {
        #expect(label(" \n ").isDegenerate)
        #expect(!label("x").isDegenerate)
    }

    @Test func movingKeepsTheText() {
        var a = label("Move me")
        a.translate(by: CGPoint(x: 10, y: -5))
        #expect(a.start == CGPoint(x: 110, y: 95))
        #expect(a.text == "Move me")
    }
}

@Suite struct TextStyleCodingTests {
    @Test func oldSavedStylesGetTheDefaultTextLook() throws {
        // A style saved before the text tool existed.
        let old = Data(##"{"color":"#3B7BFF","weight":"bold"}"##.utf8)
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: old)
        #expect(style.color == StyleColor(hex: "#3B7BFF"))
        #expect(style.weight == .bold)
        #expect(style.font == AnnotationStyle.default.font)
        #expect(style.label == AnnotationStyle.default.label)
    }

    @Test func fontAndLabelRoundTrip() throws {
        let style = AnnotationStyle(color: TextContrast.white, weight: .fine, font: .geistMono, label: .outlined)
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: data) == style)
    }

    @Test func retiredFontsFallBackToTheDefault() throws {
        // Earlier builds offered Inter Display and Instrument Sans.
        for name in ["inter", "instrument"] {
            let data = Data(##"{"color":"#3B7BFF","weight":"bold","font":"\##(name)","label":"outlined"}"##.utf8)
            let style = try JSONDecoder().decode(AnnotationStyle.self, from: data)
            #expect(style.font == AnnotationStyle.default.font)
            #expect(style.weight == .bold)
            #expect(style.label == .outlined)
        }
    }

    @Test func unknownFontFallsBack() throws {
        let data = Data(##"{"color":"#3B7BFF","font":"comic-sans","label":"sparkly"}"##.utf8)
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: data)
        #expect(style.font == AnnotationStyle.default.font)
        #expect(style.label == AnnotationStyle.default.label)
        #expect(style.color == StyleColor(hex: "#3B7BFF"))
    }
}

/// A class so each test gets its own defaults suite, removed when the test ends.
@Suite final class TextEditingTests {
    private let suiteName = "ScreenOtterTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeDocument() -> EditorDocument {
        _ = bundledFontCount
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let doc = EditorDocument(capture: CapturedImage(image: ctx.makeImage()!, scale: 2), fileURL: nil, defaults: defaults)
        doc.tool = .text
        return doc
    }

    @Test func typingALabelIsOneUndoStep() {
        let doc = makeDocument()
        let id = doc.beginNewText(at: CGPoint(x: 20, y: 30))
        #expect(doc.editingTextID == id)
        #expect(doc.selectedID == id)
        #expect(!doc.canUndo)

        doc.setEditingText("H")
        doc.setEditingText("Hello  ")
        doc.endTextEditing()
        #expect(doc.editingTextID == nil)
        #expect(doc.annotations.map(\.text) == ["Hello"])
        #expect(doc.selectedID == id)
        #expect(doc.isDirty)

        doc.undo()
        #expect(doc.annotations.isEmpty)
        doc.redo()
        #expect(doc.annotations.map(\.text) == ["Hello"])
    }

    @Test func anEmptyLabelDisappearsWithoutAnUndoStep() {
        let doc = makeDocument()
        doc.beginNewText(at: .zero)
        doc.setEditingText("   ")
        doc.endTextEditing()
        #expect(doc.annotations.isEmpty)
        #expect(doc.selectedID == nil)
        #expect(!doc.canUndo)
    }

    @Test func reEditingWithoutChangesAddsNoUndoStep() {
        let doc = makeDocument()
        let id = doc.beginNewText(at: .zero)
        doc.setEditingText("Same")
        doc.endTextEditing()
        doc.undo()
        doc.redo()
        let before = doc.annotations
        doc.beginEditingText(id)
        doc.endTextEditing()
        #expect(doc.annotations == before)
        doc.undo()
        #expect(doc.annotations.isEmpty)
    }

    @Test func clearingAnExistingLabelDeletesItUndoably() {
        let doc = makeDocument()
        let id = doc.beginNewText(at: .zero)
        doc.setEditingText("Bye")
        doc.endTextEditing()
        doc.beginEditingText(id)
        doc.setEditingText("")
        doc.endTextEditing()
        #expect(doc.annotations.isEmpty)
        doc.undo()
        #expect(doc.annotations.map(\.text) == ["Bye"])
    }

    @Test func restylingWhileTypingFoldsIntoTheEdit() {
        let doc = makeDocument()
        doc.beginNewText(at: .zero)
        doc.setEditingText("Label")
        doc.updateStyle { $0.label = .outlined }
        doc.updateStyle { $0.color = AnnotationPalette.swatches[4].color }
        doc.endTextEditing()
        #expect(doc.annotations.first?.style.label == .outlined)
        doc.undo()
        #expect(doc.annotations.isEmpty)
        #expect(!doc.canUndo)
    }

    @Test func pickingAWeightResetsAResizedLabel() {
        let doc = makeDocument()
        let id = doc.beginNewText(at: .zero)
        doc.setEditingText("Big")
        doc.endTextEditing()
        doc.annotations[0].fontSize = 80
        #expect(doc.selectedID == id)
        doc.pickWeight(.heavy)
        #expect(doc.annotations[0].fontSize == nil)
        #expect(doc.annotations[0].fontPointSize == StrokeWeight.heavy.textPoints)

        // Undo brings back the resized size along with the old weight.
        doc.undo()
        #expect(doc.annotations[0].fontSize == 80)
        #expect(doc.annotations[0].style.weight == AnnotationStyle.default.weight)
    }

    @Test func pickingTheCurrentWeightResetsAResizedLabel() {
        let doc = makeDocument()
        doc.beginNewText(at: .zero)
        doc.setEditingText("Big")
        doc.endTextEditing()
        doc.annotations[0].fontSize = 80
        let resized = doc.annotations
        doc.pickWeight(doc.annotations[0].style.weight)
        #expect(doc.annotations[0].fontSize == nil)
        doc.undo()
        #expect(doc.annotations == resized)
    }

    @Test func otherStyleChangesKeepAResizedSize() {
        let doc = makeDocument()
        doc.beginNewText(at: .zero)
        doc.setEditingText("Big")
        doc.endTextEditing()
        doc.annotations[0].fontSize = 80
        doc.updateStyle { $0.font = .geistMono }
        #expect(doc.annotations[0].fontSize == 80)
    }

    @Test func committingKeepsLeadingSpaceSoTheTextStaysPut() {
        let doc = makeDocument()
        doc.beginNewText(at: CGPoint(x: 20, y: 30))
        doc.setEditingText("  Hello\n\nWorld \n\n")
        let typed = TextLayout(doc.annotations[0])
        doc.endTextEditing()
        #expect(doc.annotations[0].text == "  Hello\n\nWorld")
        let committed = TextLayout(doc.annotations[0])
        #expect(committed.lineWidths.first == typed.lineWidths.first)
        #expect(committed.inkBox.origin == typed.inkBox.origin)
    }

    @Test func trailingWhitespaceIsTrimmed() {
        #expect("a b \t\n ".trimmingTrailingWhitespace == "a b")
        #expect("  a".trimmingTrailingWhitespace == "  a")
        #expect(" \n".trimmingTrailingWhitespace == "")
    }

    @Test func lineEndingsAreNormalized() {
        let doc = makeDocument()
        doc.beginNewText(at: .zero)
        doc.setEditingText("a\r\nb\rc\u{2028}d")
        #expect(doc.annotations[0].text == "a\nb\nc\nd")
    }

    @Test func switchingToolsCommitsTheLabel() {
        let doc = makeDocument()
        doc.beginNewText(at: .zero)
        doc.setEditingText("Done")
        doc.tool = .select
        #expect(doc.editingTextID == nil)
        #expect(doc.annotations.map(\.text) == ["Done"])
        #expect(doc.canUndo)
    }

    @Test func theTextToolKeepsOnlyALabelSelected() {
        let doc = makeDocument()
        doc.tool = .arrow
        let arrow = Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 50, y: 50), style: .default, scale: 2)
        doc.add(arrow)
        doc.tool = .select
        doc.selectedID = arrow.id
        doc.tool = .text
        #expect(doc.selectedID == nil)
        #expect(doc.isStylingText)
    }

    @Test func deletingIsIgnoredWhileTyping() {
        let doc = makeDocument()
        doc.beginNewText(at: .zero)
        doc.setEditingText("Keep")
        doc.deleteSelected()
        #expect(doc.annotations.count == 1)
    }

    @Test func renderingIncludesLabels() throws {
        let doc = makeDocument()
        doc.beginNewText(at: CGPoint(x: 40, y: 40))
        doc.setEditingText("Pixels")
        doc.endTextEditing()
        let label = doc.annotations[0]
        #expect(label.style.label == .filled)
        let image = try #require(doc.render())
        #expect(image.width == 400 && image.height == 300)

        // A point inside the plate, left of the text, is the plate's color.
        let metrics = TextLabelMetrics(label: .filled, fontSize: label.fontPixelSize)
        let plate = label.bounds
        let pixel = try #require(Self.pixel(of: image, at: CGPoint(x: plate.minX + metrics.horizontalPadding / 2, y: plate.midY)))
        let color = label.style.color
        #expect(abs(Int(pixel.r) - Int(color.red)) <= 2)
        #expect(abs(Int(pixel.g) - Int(color.green)) <= 2)
        #expect(abs(Int(pixel.b) - Int(color.blue)) <= 2)
        #expect(pixel.a == 255)
    }

    /// The RGBA bytes at `point` (top-left origin) of an sRGB image.
    private static func pixel(of image: CGImage, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Shift the image so the wanted pixel lands on the 1x1 context (CG is bottom-left origin).
            let x = Int(point.x), y = image.height - 1 - Int(point.y)
            ctx.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
            return true
        }
        return drawn ? (bytes[0], bytes[1], bytes[2], bytes[3]) : nil
    }
}
