import AppKit
import Foundation
import Testing
@testable import ScreenOtter

@Suite struct StyleColorTests {
    @Test func parsesHexWithAndWithoutAlpha() throws {
        let opaque = try #require(StyleColor(hex: "#FF4B3E"))
        #expect(opaque == StyleColor(red: 0xFF, green: 0x4B, blue: 0x3E))
        #expect(StyleColor(hex: "ff4b3e") == opaque)

        let translucent = try #require(StyleColor(hex: "#11223380"))
        #expect(translucent.alpha == 0x80)
        #expect(translucent.hex == "#11223380")
        #expect(opaque.hex == "#FF4B3E")
    }

    @Test(arguments: ["", "#FFF", "#GG0000", "#1234567", "red", "+FFFFF"])
    func rejectsMalformedHex(_ text: String) {
        #expect(StyleColor(hex: text) == nil)
    }

    @Test func convertsNSColorToSRGBBytes() throws {
        let color = try #require(StyleColor(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)))
        #expect(color == StyleColor(red: 255, green: 128, blue: 0))
        // A color from another space lands on the same sRGB bytes as its sRGB twin.
        let gray = try #require(StyleColor(NSColor(white: 1, alpha: 1)))
        #expect(gray == StyleColor(red: 255, green: 255, blue: 255))
    }

    @Test func withAlphaClampsAndRounds() {
        let base = StyleColor(red: 10, green: 20, blue: 30)
        #expect(base.withAlpha(0.5).alpha == 128)
        #expect(base.withAlpha(2).alpha == 255)
        #expect(base.withAlpha(-1).alpha == 0)
    }

    @Test func lightnessSplitsThePalette() {
        let light = AnnotationPalette.swatches.filter { $0.color.isLight }.map(\.name)
        #expect(light == ["Amber", "White"])
    }
}

@Suite struct AnnotationStyleCodingTests {
    @Test func roundTripsAsReadableJSON() throws {
        let style = AnnotationStyle(color: StyleColor(hex: "#3B7BFF")!, weight: .heavy)
        let data = try JSONEncoder().encode(style)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"#3B7BFF\""))
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: data) == style)
    }

    @Test func missingFieldsFallBackToDefaults() throws {
        let empty = try JSONDecoder().decode(AnnotationStyle.self, from: Data("{}".utf8))
        #expect(empty == .default)

        let colorOnly = try JSONDecoder().decode(AnnotationStyle.self, from: Data(##"{"color":"#2BC46D"}"##.utf8))
        #expect(colorOnly.color == StyleColor(hex: "#2BC46D"))
        #expect(colorOnly.weight == AnnotationStyle.default.weight)
    }

    @Test func unknownValuesFallBackToDefaults() throws {
        let data = Data(#"{"color":"not a color","weight":"ultra","future":true}"#.utf8)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: data) == .default)
    }

    @Test func remembersTheLastUsedStyle() throws {
        let suite = "ScreenOtterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AnnotationStyle.lastUsed(in: defaults) == .default)
        let style = AnnotationStyle(color: AnnotationPalette.swatches[4].color, weight: .fine)
        style.rememberAsDefault(in: defaults)
        #expect(AnnotationStyle.lastUsed(in: defaults) == style)

        defaults.set(Data("garbage".utf8), forKey: "annotationStyle")
        #expect(AnnotationStyle.lastUsed(in: defaults) == .default)
    }
}

@Suite struct AnnotationPaletteTests {
    @Test func swatchesAreDistinctAndOpaque() {
        let colors = AnnotationPalette.swatches.map(\.color)
        #expect(Set(colors).count == colors.count)
        #expect(colors.allSatisfy { $0.alpha == 255 })
        #expect((6...8).contains(colors.count))
    }

    @Test func findsSwatchesByColorAndNumberKey() {
        let blue = AnnotationPalette.swatches[4]
        #expect(AnnotationPalette.swatch(for: blue.color)?.name == blue.name)
        #expect(AnnotationPalette.swatch(for: StyleColor(red: 1, green: 2, blue: 3)) == nil)

        #expect(AnnotationPalette.swatch(forKey: "1")?.name == AnnotationPalette.swatches[0].name)
        #expect(AnnotationPalette.swatch(forKey: "8")?.name == AnnotationPalette.swatches[7].name)
        #expect(AnnotationPalette.swatch(forKey: "0") == nil)
        #expect(AnnotationPalette.swatch(forKey: "9") == nil)
        #expect(AnnotationPalette.swatch(forKey: "a") == nil)
    }

    @Test func weightsGetHeavierInOrder() {
        let points = StrokeWeight.allCases.map(\.points)
        #expect(points == points.sorted())
        #expect(Set(points).count == points.count)
    }
}

/// A class so each test gets its own defaults suite, removed when the test ends.
@Suite final class EditorDocumentStyleTests {
    private let suiteName = "ScreenOtterTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeDocument(style: AnnotationStyle = .default) -> EditorDocument {
        let ctx = CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        style.rememberAsDefault(in: defaults)
        return EditorDocument(capture: CapturedImage(image: ctx.makeImage()!, scale: 2), fileURL: nil, defaults: defaults)
    }

    private func addLine(to doc: EditorDocument) -> UUID {
        let annotation = Annotation(kind: .line, start: .zero, end: CGPoint(x: 20, y: 20), style: doc.style, scale: doc.scale)
        doc.add(annotation)
        return annotation.id
    }

    private let blue = AnnotationPalette.swatches[4].color

    @Test func widthFollowsWeightAndScale() {
        let annotation = Annotation(kind: .line, start: .zero, end: .zero, style: AnnotationStyle(weight: .bold), scale: 2)
        #expect(annotation.width == StrokeWeight.bold.points * 2)
    }

    @Test func withoutSelectionOnlyTheDefaultChanges() {
        let doc = makeDocument()
        let id = addLine(to: doc)
        doc.updateStyle { $0.color = blue }

        #expect(doc.style.color == blue)
        #expect(doc.annotations.first { $0.id == id }?.style == .default)
        #expect(doc.displayedStyle.color == blue)
    }

    @Test func restylesTheSelectionUndoably() {
        let doc = makeDocument()
        let id = addLine(to: doc)
        doc.tool = .select
        doc.selectedID = id

        doc.updateStyle { $0.weight = .heavy }
        #expect(doc.annotations[0].style.weight == .heavy)
        #expect(doc.annotations[0].style.color == AnnotationStyle.default.color)
        #expect(doc.style.weight == .heavy)

        doc.undo()
        #expect(doc.annotations[0].style == .default)
        doc.redo()
        #expect(doc.annotations[0].style.weight == .heavy)
    }

    @Test func pickingOneComponentKeepsTheSelectionsOther() {
        let doc = makeDocument(style: AnnotationStyle(weight: .fine))
        let id = addLine(to: doc)
        doc.updateStyle { $0.weight = .heavy }
        doc.tool = .select
        doc.selectedID = id

        #expect(doc.displayedStyle.weight == .fine)
        doc.updateStyle { $0.color = blue }
        #expect(doc.annotations[0].style == AnnotationStyle(color: blue, weight: .fine))
    }

    @Test func liveEditsShareOneUndoStep() {
        let doc = makeDocument()
        let id = addLine(to: doc)
        doc.tool = .select
        doc.selectedID = id

        for green in stride(from: 0, through: 200, by: 50) {
            doc.updateStyle(coalescing: true) { $0.color = StyleColor(red: 0, green: UInt8(green), blue: 0) }
        }
        #expect(doc.annotations[0].style.color == StyleColor(red: 0, green: 200, blue: 0))
        doc.undo()
        #expect(doc.annotations[0].style == .default)
        doc.undo()
        #expect(doc.annotations.isEmpty)
    }

    @Test func discreteEditsEndALiveRun() {
        let doc = makeDocument()
        let id = addLine(to: doc)
        doc.tool = .select
        doc.selectedID = id

        doc.updateStyle(coalescing: true) { $0.color = blue }
        doc.updateStyle { $0.weight = .bold }
        doc.updateStyle(coalescing: true) { $0.color = StyleColor(red: 1, green: 1, blue: 1) }

        doc.undo()
        #expect(doc.annotations[0].style == AnnotationStyle(color: blue, weight: .bold))
        doc.undo()
        #expect(doc.annotations[0].style == AnnotationStyle(color: blue, weight: .regular))
        doc.undo()
        #expect(doc.annotations[0].style == .default)
    }

    @Test func endingCoalescingStartsANewUndoStep() {
        let doc = makeDocument()
        let id = addLine(to: doc)
        doc.tool = .select
        doc.selectedID = id
        let gray = StyleColor(red: 90, green: 90, blue: 90)

        doc.updateStyle(coalescing: true) { $0.color = StyleColor(red: 10, green: 10, blue: 10) }
        doc.updateStyle(coalescing: true) { $0.color = blue }
        doc.endStyleCoalescing()
        doc.updateStyle(coalescing: true) { $0.color = gray }

        #expect(doc.annotations[0].style.color == gray)
        doc.undo()
        #expect(doc.annotations[0].style.color == blue)
        doc.undo()
        #expect(doc.annotations[0].style == .default)
        doc.undo()
        #expect(doc.annotations.isEmpty)
    }

    @Test func reselectingEndsALiveRun() {
        let doc = makeDocument()
        let id = addLine(to: doc)
        doc.tool = .select
        doc.selectedID = id

        doc.updateStyle(coalescing: true) { $0.color = blue }
        doc.selectedID = nil
        doc.selectedID = id
        doc.updateStyle(coalescing: true) { $0.weight = .heavy }

        doc.undo()
        #expect(doc.annotations[0].style == AnnotationStyle(color: blue))
        doc.undo()
        #expect(doc.annotations[0].style == .default)
        doc.undo()
        #expect(doc.annotations.isEmpty)
    }

    @Test func startsFromAndSavesTheLastUsedStyle() {
        let saved = AnnotationStyle(color: AnnotationPalette.swatches[5].color, weight: .bold)
        let doc = makeDocument(style: saved)
        #expect(doc.style == saved)

        doc.updateStyle { $0.weight = .fine }
        #expect(AnnotationStyle.lastUsed(in: defaults) == AnnotationStyle(color: saved.color, weight: .fine))
    }

    @Test func reselectingTheSameStyleAddsNoUndoStep() {
        let doc = makeDocument()
        let id = addLine(to: doc)
        doc.tool = .select
        doc.selectedID = id
        doc.updateStyle { $0.weight = AnnotationStyle.default.weight }

        doc.undo()
        #expect(doc.annotations.isEmpty)
    }
}
