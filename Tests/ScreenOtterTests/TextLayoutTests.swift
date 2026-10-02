import CoreGraphics
import Foundation
import Testing
@testable import ScreenOtter

/// Fixtures use the boxes Vision actually returned for rendered samples (Retina pixels, top-left origin),
/// so the thresholds are tested against real-world noise in box heights.
@Suite struct TextLayoutTests {
    private func fragment(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> TextLayout.Fragment {
        TextLayout.Fragment(text: text, box: CGRect(x: x, y: y, width: width, height: height))
    }

    @Test func convertsVisionBoxesToTopLeftPixels() {
        let fragment = TextLayout.Fragment(
            text: "Hi",
            normalizedBox: CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.25),
            imageSize: CGSize(width: 400, height: 200)
        )
        #expect(fragment.box == CGRect(x: 100, y: 0, width: 200, height: 50))
    }

    @Test func emptyInputIsEmptyText() {
        #expect(TextLayout.assemble([]) == "")
        #expect(TextLayout.assemble([fragment("  ", 0, 0, 10, 10)]) == "")
    }

    @Test func joinsWrappedLinesAndKeepsTheHeadingAndParagraphs() {
        let fragments = [
            fragment("Capture Text", 55, 69, 264, 43),
            fragment("ScreenOtter keeps the things you capture, the way a sea otter", 55, 143, 802, 31),
            fragment("keeps its favorite stone tucked under its arm. Drag over any text", 52, 176, 826, 37),
            fragment("on screen and it lands on your clipboard, ready to paste.", 52, 221, 733, 40),
            fragment("Recognition runs on device with Vision, so nothing leaves your", 58, 331, 804, 32),
            fragment("Mac. Line breaks are kept where they matter.", 52, 366, 587, 36),
        ]
        #expect(TextLayout.assemble(fragments) == """
        Capture Text
        ScreenOtter keeps the things you capture, the way a sea otter keeps its favorite stone tucked under its arm. Drag over any text on screen and it lands on your clipboard, ready to paste.

        Recognition runs on device with Vision, so nothing leaves your Mac. Line breaks are kept where they matter.
        """)
    }

    @Test func keepsListItemsOnTheirOwnLines() {
        let fragments = [
            fragment("Groceries", 113, 126, 294, 57),
            fragment("• Apples", 111, 241, 220, 53),
            fragment("• Oat milk", 111, 324, 256, 46),
            fragment("• Coffee beans", 111, 410, 384, 45),
            fragment("• Bread", 111, 495, 190, 44),
        ]
        #expect(TextLayout.assemble(fragments) == "Groceries\n\n• Apples\n• Oat milk\n• Coffee beans\n• Bread")
    }

    @Test func keepsShortLinesApart() {
        let fragments = [
            fragment("Victor Bragagnolo", 69, 80, 238, 29),
            fragment("Rua das Flores 123", 72, 119, 245, 27),
            fragment("Porto Alegre, RS", 71, 161, 214, 35),
            fragment("Brazil", 69, 203, 78, 32),
        ]
        #expect(TextLayout.assemble(fragments) == "Victor Bragagnolo\nRua das Flores 123\nPorto Alegre, RS\nBrazil")
    }

    @Test func readsTablesRowByRowWithTabs() {
        let fragments = [
            fragment("Plan", 56, 59, 56, 26), fragment("Starter", 55, 119, 84, 23),
            fragment("Team", 55, 171, 64, 21), fragment("Enterprise", 56, 221, 124, 26),
            fragment("Price", 410, 56, 72, 34), fragment("$9", 415, 115, 34, 25),
            fragment("$29", 413, 168, 52, 26), fragment("Custom", 414, 219, 98, 30),
            fragment("Seats", 675, 59, 74, 27), fragment("1", 673, 117, 16, 24),
            fragment("10", 673, 168, 32, 26), fragment("Unlimited", 675, 218, 116, 27),
        ]
        #expect(TextLayout.assemble(fragments) == "Plan\tPrice\tSeats\nStarter\t$9\t1\nTeam\t$29\t10\nEnterprise\tCustom\tUnlimited")
    }

    @Test func looselySpacedFormRowsStayTogether() {
        let fragments = [
            fragment("Launch at login", 56, 62, 184, 25), fragment("Play shutter sound", 55, 121, 224, 26),
            fragment("On", 775, 61, 36, 24), fragment("Off", 776, 119, 41, 26),
        ]
        #expect(TextLayout.assemble(fragments) == "Launch at login\tOn\nPlay shutter sound\tOff")
    }

    private var sidebarFixture: [TextLayout.Fragment] {
        [
            fragment("Inbox", 43, 69, 70, 24), fragment("Drafts", 47, 111, 74, 23),
            fragment("Sent", 48, 151, 58, 20), fragment("Archive", 47, 189, 90, 24),
            fragment("Trash", 47, 229, 66, 24),
            fragment("Weekly update", 328, 64, 268, 51),
            fragment("ScreenOtter keeps the things you capture, the way a sea", 335, 127, 684, 39),
            fragment("otter keeps its favorite stone tucked under its arm. Drag", 336, 171, 676, 28),
            fragment("over any text on screen and it lands on your clipboard,", 328, 203, 667, 46),
            fragment("ready to paste.", 334, 256, 186, 23),
        ]
    }

    private var twoColumnFixture: [TextLayout.Fragment] {
        [
            fragment("ScreenOtter keeps the things you", 56, 61, 406, 26),
            fragment("capture, the way a sea otter keeps its", 55, 101, 452, 30),
            fragment("favorite stone tucked under its arm.", 54, 141, 470, 26),
            fragment("Recognition runs on device with Vision,", 616, 62, 476, 29),
            fragment("so nothing leaves your Mac. Line breaks", 615, 95, 484, 36),
            fragment("are kept where they matter.", 610, 133, 340, 35),
        ]
    }

    @Test func readsASidebarBeforeTheContentNextToIt() {
        #expect(TextLayout.assemble(sidebarFixture) == """
        Inbox
        Drafts
        Sent
        Archive
        Trash

        Weekly update
        ScreenOtter keeps the things you capture, the way a sea otter keeps its favorite stone tucked under its arm. Drag over any text on screen and it lands on your clipboard, ready to paste.
        """)
    }

    @Test func readsTwoColumnsOfProseOneAfterTheOther() {
        #expect(TextLayout.assemble(twoColumnFixture) == """
        ScreenOtter keeps the things you capture, the way a sea otter keeps its favorite stone tucked under its arm.

        Recognition runs on device with Vision, so nothing leaves your Mac. Line breaks are kept where they matter.
        """)
    }

    /// Vision promises no order, so columns must come out the same however the fragments arrive.
    @Test func columnsDoNotDependOnInputOrder() {
        for fixture in [sidebarFixture, twoColumnFixture] {
            let expected = TextLayout.assemble(fixture)
            let evens = stride(from: 0, to: fixture.count, by: 2).map { fixture[$0] }
            let odds = stride(from: 1, to: fixture.count, by: 2).map { fixture[$0] }
            let rotated = Array(fixture[3...] + fixture[..<3])
            for shuffled in [Array(fixture.reversed()), odds + evens, evens.reversed() + odds, rotated] {
                #expect(TextLayout.assemble(shuffled) == expected)
            }
        }
    }

    @Test func aFirstLineIndentStillWrapsIntoTheParagraph() {
        let fragments = [
            fragment("The first line of this paragraph is indented like a printed book and", 100, 100, 772, 32),
            fragment("it carries on flush left on the next line.", 52, 140, 480, 32),
        ]
        #expect(TextLayout.assemble(fragments) == "The first line of this paragraph is indented like a printed book and it carries on flush left on the next line.")
    }

    @Test func shortLinesCompareTheirHeight() {
        let body = fragment("This line is set in body text and runs across the column", 52, 100, 640, 32)
        // Too few characters to compare widths: a much taller word is a heading, not the wrap.
        #expect(TextLayout.assemble([body, fragment("Note", 52, 140, 110, 52)]) == "This line is set in body text and runs across the column\nNote")
        #expect(TextLayout.assemble([body, fragment("too.", 52, 140, 50, 32)]) == "This line is set in body text and runs across the column too.")
    }

    @Test func japaneseWrapsWithoutASpace() {
        let fragments = [
            fragment("スクリーンオッターはキャプチャしたものを大切に保管します。テキストを", 52, 100, 1088, 32),
            fragment("ドラッグするとクリップボードにコピーされます。", 52, 140, 736, 32),
        ]
        #expect(TextLayout.assemble(fragments) == "スクリーンオッターはキャプチャしたものを大切に保管します。テキストをドラッグするとクリップボードにコピーされます。")
    }

    @Test func movingUpOrIntoAnotherColumnStartsABlock() throws {
        let row = { (x: CGFloat, y: CGFloat) in try #require(TextLayout.rows([fragment("Some text set in a column", x, y, 300, 32)]).first) }
        let previous = try row(52, 200)
        let up = try row(52, 100)
        let beside = try row(600, 240)
        let below = try row(52, 240)
        #expect(TextLayout.breakBetween(previous, up, paragraphRight: previous.box.maxX, previousStartsParagraph: true) == .blankLine)
        #expect(TextLayout.breakBetween(previous, beside, paragraphRight: previous.box.maxX, previousStartsParagraph: true) == .blankLine)
        #expect(TextLayout.breakBetween(previous, below, paragraphRight: previous.box.maxX, previousStartsParagraph: true) != .blankLine)
    }

    @Test func aSentenceEndingOnTheWidestLineIsABreak() {
        let fragments = [
            fragment("Olá, mundo! Captura de texto em português.", 53, 59, 619, 41),
            fragment("Grüße aus Berlin, schön zu sehen", 56, 110, 470, 36),
        ]
        #expect(TextLayout.assemble(fragments) == "Olá, mundo! Captura de texto em português.\nGrüße aus Berlin, schön zu sehen")
    }

    @Test func joinsAcrossHyphensAndCJKWithoutSpaces() {
        #expect(TextLayout.joiner("well-", "known") == "")
        #expect(TextLayout.joiner("A-", "Team") == " ")
        #expect(TextLayout.joiner("テキストを", "コピー") == "")
        #expect(TextLayout.joiner("hello", "world") == " ")
    }

    @Test func recognizesListMarkers() {
        #expect(TextLayout.startsListItem("• Apples"))
        #expect(TextLayout.startsListItem("- item"))
        #expect(TextLayout.startsListItem("12. Twelfth"))
        #expect(TextLayout.startsListItem("b) second"))
        #expect(!TextLayout.startsListItem("Apples"))
        #expect(!TextLayout.startsListItem("-5 degrees"))
    }

    @Test func findsTheWidestGapBetweenIntervals() {
        let gap = TextLayout.widestGap([(0, 10), (12, 20), (5, 15), (40, 50), (60, 70)])
        #expect(gap?.position == 30)
        #expect(gap?.width == 20)
        #expect(TextLayout.widestGap([(0, 10), (5, 20)]) == nil)
    }

    @Test func summarizesCopiedText() {
        let english = Locale(identifier: "en_US")
        let single = TextCaptureSummary("hello@screenotter.app")
        #expect(single.firstLine == "hello@screenotter.app")
        #expect(single.detail(locale: english) == "21 characters")

        let many = TextCaptureSummary("\n  Plan\tPrice\n\nStarter\t$9\n" + String(repeating: "x", count: 1200))
        #expect(many.firstLine == "Plan  Price")
        #expect(many.lineCount == 3)
        #expect(many.detail(locale: english) == "3 lines · 1,226 characters")
        #expect(TextCaptureSummary("a").detail(locale: english) == "1 character")
    }
}
