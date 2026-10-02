import CoreGraphics
import Foundation

/// Turns the pieces of text Vision finds into plain text in reading order.
///
/// Vision returns one observation per run of text on a line, in no promised order. This puts them back
/// together the way a person would read them: columns (a sidebar next to content, two-column prose) are
/// read one after the other, while a table or a form is read row by row with a tab between cells, so it
/// pastes into a spreadsheet. Lines that wrapped inside a paragraph are joined with a space; deliberate
/// breaks (short lines, list items, headings) stay, and a wide vertical gap becomes a blank line.
///
/// Everything here is geometry on boxes, so it is easy to test without Vision.
nonisolated enum TextLayout {
    struct Fragment: Equatable, Sendable {
        var text: String
        /// In pixels, top-left origin.
        var box: CGRect

        init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }

        /// From a Vision bounding box: normalized to the image, bottom-left origin.
        init(text: String, normalizedBox: CGRect, imageSize: CGSize) {
            self.text = text
            box = CGRect(
                x: normalizedBox.minX * imageSize.width,
                y: (1 - normalizedBox.maxY) * imageSize.height,
                width: normalizedBox.width * imageSize.width,
                height: normalizedBox.height * imageSize.height
            )
        }
    }

    static func assemble(_ fragments: [Fragment]) -> String {
        let fragments = fragments.compactMap { fragment -> Fragment? in
            let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, fragment.box.width > 0, fragment.box.height > 0 else { return nil }
            return Fragment(text: text, box: fragment.box)
        }
        return join(order(fragments))
    }

    // MARK: - Reading order

    /// One visual line: fragments side by side, left to right.
    struct Row {
        var box: CGRect
        /// Glyph height, the unit every threshold is measured in.
        var height: CGFloat
        var text: String
        var isSingleCell: Bool
    }

    /// Recursive XY-cut: split the region at its widest empty band, vertical or horizontal, and read the
    /// pieces in order (left before right, top before bottom). A vertical cut only counts as columns when
    /// the two sides don't line up row for row; otherwise it's a table and is read across.
    static func order(_ fragments: [Fragment]) -> [Row] {
        guard fragments.count > 1 else { return rows(fragments) }
        let height = median(fragments.map(\.box.height))
        let vertical = widestGap(fragments.map { ($0.box.minX, $0.box.maxX) })
        let horizontal = widestGap(fragments.map { ($0.box.minY, $0.box.maxY) })

        let tryColumns = { () -> [Row]? in
            guard let cut = vertical, cut.width >= height else { return nil }
            let left = fragments.filter { $0.box.midX < cut.position }
            let right = fragments.filter { $0.box.midX >= cut.position }
            guard readsAsColumns(left, right, height: height) else { return nil }
            return order(left) + order(right)
        }
        let tryBands = { () -> [Row]? in
            guard let cut = horizontal else { return nil }
            let top = fragments.filter { $0.box.midY < cut.position }
            let bottom = fragments.filter { $0.box.midY >= cut.position }
            guard !top.isEmpty, !bottom.isEmpty else { return nil }
            return order(top) + order(bottom)
        }

        // The wider gap is the stronger boundary: a gutter between columns beats the space between lines,
        // and the space under a heading beats the gaps inside a paragraph.
        if (vertical?.width ?? 0) > (horizontal?.width ?? 0) {
            return tryColumns() ?? tryBands() ?? rows(fragments)
        }
        return tryBands() ?? tryColumns() ?? rows(fragments)
    }

    /// Sides of a vertical gutter are separate columns unless they line up like a table. Two blocks of
    /// prose set side by side line up too, so wide sides full of long lines still count as columns.
    static func readsAsColumns(_ left: [Fragment], _ right: [Fragment], height: CGFloat) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return false }
        let (fewer, more) = left.count <= right.count ? (left, right) : (right, left)
        let aligned = fewer.filter { fragment in more.contains { sharesBaseline(fragment.box, $0.box) } }
        if Double(aligned.count) < Double(fewer.count) * 0.6 { return true }
        return looksLikeProse(left, height: height) && looksLikeProse(right, height: height)
    }

    private static func looksLikeProse(_ fragments: [Fragment], height: CGFloat) -> Bool {
        let lines = rows(fragments)
        guard lines.count >= 2 else { return false }
        let width = lines.map(\.box.maxX).max()! - lines.map(\.box.minX).min()!
        guard width >= height * 10 else { return false }
        return median(lines.map(\.box.width)) >= width * 0.6
    }

    /// Groups fragments that share a line, top to bottom.
    static func rows(_ fragments: [Fragment]) -> [Row] {
        var groups: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let index = groups.lastIndex(where: { group in group.contains { overlapsVertically($0.box, fragment.box) } }) {
                groups[index].append(fragment)
            } else {
                groups.append([fragment])
            }
        }
        return groups
            .map(makeRow)
            .sorted { $0.box.minY < $1.box.minY }
    }

    private static func makeRow(_ fragments: [Fragment]) -> Row {
        let sorted = fragments.sorted { $0.box.minX < $1.box.minX }
        let height = median(sorted.map(\.box.height))
        var text = sorted[0].text
        var isSingleCell = true
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            // A wide gap inside a line separates cells (a table, a form, a toolbar).
            if next.box.minX - previous.box.maxX >= height * 2.5 {
                text += "\t"
                isSingleCell = false
            } else {
                text += joiner(previous.text, next.text)
            }
            text += next.text
        }
        let box = sorted.dropFirst().reduce(sorted[0].box) { $0.union($1.box) }
        return Row(box: box, height: height, text: text, isSingleCell: isSingleCell)
    }

    // MARK: - Lines and paragraphs

    enum Break: Equatable {
        /// The line wrapped: same paragraph.
        case space
        case newline
        case blankLine
    }

    static func join(_ rows: [Row]) -> String {
        guard var paragraph = rows.first else { return "" }
        var output = paragraph.text
        var paragraphRight = paragraph.box.maxX
        var previous = paragraph
        for row in rows.dropFirst() {
            let kind = breakBetween(previous, row, paragraphRight: paragraphRight, previousStartsParagraph: previous.box == paragraph.box)
            switch kind {
            case .space:
                output += joiner(previous.text, row.text) + row.text
                paragraphRight = max(paragraphRight, row.box.maxX)
            case .newline, .blankLine:
                output += (kind == .newline ? "\n" : "\n\n") + row.text
                paragraph = row
                paragraphRight = row.box.maxX
            }
            previous = row
        }
        return output
    }

    static func breakBetween(_ previous: Row, _ next: Row, paragraphRight: CGFloat, previousStartsParagraph: Bool) -> Break {
        let height = max(previous.height, next.height)
        let gap = next.box.minY - previous.box.maxY
        // Moving up, or sideways into another column: a new block.
        let sharesColumn = next.box.minX < previous.box.maxX && previous.box.minX < next.box.maxX
        if gap < -0.5 * min(previous.height, next.height) || !sharesColumn { return .blankLine }
        // Table rows are spaced more loosely than lines of text, so they need a wider gap to split.
        let blankGap = previous.isSingleCell || next.isSingleCell ? 1.0 : 2.0
        if gap > height * blankGap { return .blankLine }
        return wrapped(previous, into: next, paragraphRight: paragraphRight, previousStartsParagraph: previousStartsParagraph) ? .space : .newline
    }

    /// Whether `next` is the same paragraph continuing after a soft wrap.
    private static func wrapped(_ previous: Row, into next: Row, paragraphRight: CGFloat, previousStartsParagraph: Bool) -> Bool {
        guard previous.isSingleCell, next.isSingleCell else { return false }
        let unit = (previous.height + next.height) / 2
        guard sameTextSize(previous, next) else { return false }
        guard next.box.minY - previous.box.maxY <= unit * 0.8 else { return false }

        // Same left edge, or a first-line indent.
        let indent = previous.box.minX - next.box.minX
        let alignedLeft = abs(indent) <= unit * 0.75 || (previousStartsParagraph && indent > 0 && indent <= unit * 4)
        guard alignedLeft else { return false }

        // Only text set in a real column wraps; a stack of short labels is a list.
        let right = max(paragraphRight, next.box.maxX)
        guard right - next.box.minX >= unit * 10 else { return false }
        guard !startsListItem(next.text) else { return false }

        // A sentence that ends on the widest line so far is more likely a deliberate break than a wrap.
        let characterWidth = next.box.width / CGFloat(max(next.text.count, 1))
        if endsSentence(previous.text), previous.box.maxX >= paragraphRight - characterWidth { return false }

        // The line wrapped if the next line's first word wouldn't have fit in the space left on it.
        let firstWord = next.text.prefix { !$0.isWhitespace }.count
        return right - previous.box.maxX < CGFloat(firstWord + 1) * characterWidth + unit * 0.5
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^([•·▪◦‣○●■□✓✔→\-–—*+]|\d{1,3}[.)]|[A-Za-z][.)]|\(\w{1,3}\))\s"#)

    /// Whether two lines are set in the same size, so a heading never runs into the paragraph below it.
    /// Vision's box heights vary by half for the same font, so lines long enough to average over compare
    /// their character width instead, which is steady.
    static func sameTextSize(_ a: Row, _ b: Row) -> Bool {
        let characters = (a.text.count, b.text.count)
        if characters.0 >= 6, characters.1 >= 6 {
            let widths = (a.box.width / CGFloat(characters.0), b.box.width / CGFloat(characters.1))
            return max(widths.0, widths.1) / min(widths.0, widths.1) <= 1.3
        }
        return max(a.height, b.height) / min(a.height, b.height) <= 1.5
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?:;。！？：；…".contains(last)
    }

    static func startsListItem(_ text: String) -> Bool {
        listMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// What goes between two pieces of the same paragraph: a space, except after a hyphenated break
    /// (kept as is: a hyphen we can't tell from a real one is safer kept) and between Chinese or
    /// Japanese characters, which aren't separated by spaces.
    static func joiner(_ previous: String, _ next: String) -> String {
        guard let last = previous.last, let first = next.first else { return " " }
        if last == "-", previous.dropLast().last?.isLetter == true, first.isLowercase { return "" }
        if isCJK(last) || isCJK(first) { return "" }
        return " "
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: true
            default: false
            }
        }
    }

    // MARK: - Geometry

    /// Two boxes are on the same line when they share at least half of the shorter one's height.
    static func overlapsVertically(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return shared >= min(a.height, b.height) * 0.5
    }

    /// Cells of one table row sit on the same baseline; lines of unrelated columns only pass each other.
    static func sharesBaseline(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) <= min(a.height, b.height) * 0.3
    }

    /// The widest empty stretch between intervals, as its middle and width.
    static func widestGap(_ intervals: [(CGFloat, CGFloat)]) -> (position: CGFloat, width: CGFloat)? {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var reach = sorted.first?.1 else { return nil }
        var best: (position: CGFloat, width: CGFloat)?
        for (start, end) in sorted.dropFirst() {
            if start > reach, start - reach > (best?.width ?? 0) {
                best = ((start + reach) / 2, start - reach)
            }
            reach = max(reach, end)
        }
        return best
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// What the confirmation shows about copied text.
nonisolated struct TextCaptureSummary: Equatable {
    var firstLine: String
    var characterCount: Int
    var lineCount: Int

    init(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        firstLine = lines.first.map { $0.replacingOccurrences(of: "\t", with: "  ") } ?? ""
        characterCount = text.count
        lineCount = lines.count
    }

    /// "21 characters", "12 lines · 1,204 characters".
    func detail(locale: Locale = .current) -> String {
        let count = characterCount.formatted(.number.locale(locale))
        let characters = "\(count) \(characterCount == 1 ? "character" : "characters")"
        guard lineCount > 1 else { return characters }
        return "\(lineCount) lines · \(characters)"
    }
}
