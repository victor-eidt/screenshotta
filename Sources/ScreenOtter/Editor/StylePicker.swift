import AppKit
import SwiftUI

/// The toolbar's style control: a compact chip showing the current color and weight, which opens a
/// popover with the palette, a custom color well and the stroke weights. One chip instead of a row of
/// swatches keeps the toolbar calm as tools are added.
struct StylePicker: View {
    @ObservedObject var doc: EditorDocument
    @State private var isOpen = false
    @State private var isHovered = false

    var body: some View {
        let style = doc.displayedStyle
        let colorName = AnnotationPalette.swatch(for: style.color)?.name ?? "Custom color"
        // Text reads the weight as a size, so it is described by its size, font and look instead.
        // A redaction has no color or weight: the chip shows its mode instead.
        let summary = doc.isStylingRedaction
            ? style.redaction.title
            : doc.isStylingText
            ? "\(colorName), \(Int((doc.selectedAnnotation?.fontPointSize ?? style.weight.textPoints).rounded())) pt, \(style.font.title), \(style.label.title)"
            : "\(colorName), \(style.weight.title)"
        Button { isOpen.toggle() } label: {
            HStack(spacing: 8) {
                if doc.isStylingRedaction {
                    // As wide as the dot and glyph it replaces, so the toolbar doesn't shift.
                    RedactionGlyph(mode: style.redaction)
                        .frame(width: 40, height: 18)
                } else {
                    SwatchDot(color: style.color, diameter: 18)
                    if doc.isStylingText {
                        Text("Aa")
                            .font(Font(style.font.ctFont(size: 12)))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .fixedSize()
                    } else {
                        WeightGlyph(weight: style.weight, length: 14, thickness: 0.8)
                            .frame(width: 14)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(isHovered || isOpen ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(doc.isStylingRedaction
            ? "Redaction: \(summary). Press B to switch"
            : "Style: \(summary). Keys 1–\(AnnotationPalette.swatches.count) pick a color")
        .accessibilityLabel("Style")
        .accessibilityValue(summary)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            StylePopover(doc: doc)
        }
    }
}

struct StylePopover: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        if doc.isStylingRedaction {
            redactionOptions
        } else {
            styleOptions
        }
    }

    /// Blur and pixelate, previewed. Their strength isn't a setting: it follows the region's size.
    private var redactionOptions: some View {
        HStack(spacing: 6) {
            ForEach(RedactionMode.allCases) { mode in
                RedactionModeButton(mode: mode, isSelected: doc.displayedStyle.redaction == mode) {
                    doc.pickRedaction(mode)
                }
            }
        }
        .padding(12)
    }

    private var styleOptions: some View {
        let style = doc.displayedStyle
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(AnnotationPalette.swatches.enumerated()), id: \.element.id) { index, swatch in
                    SwatchButton(color: swatch.color, isSelected: style.color == swatch.color, help: "\(swatch.name) (\(index + 1))") {
                        doc.updateStyle { $0.color = swatch.color }
                    }
                }
                CustomColorButton(color: style.color, isCustom: AnnotationPalette.swatch(for: style.color) == nil) {
                    StyleColorPanel.shared.show(for: doc)
                }
            }

            Divider().opacity(0.6)

            HStack(spacing: 6) {
                ForEach(StrokeWeight.allCases) { weight in
                    // A resized label has its own size, so no preset is highlighted.
                    WeightButton(weight: weight, font: doc.isStylingText ? style.font : nil,
                                 isSelected: style.weight == weight && doc.selectedAnnotation?.fontSize == nil) {
                        doc.pickWeight(weight)
                    }
                }
            }

            if doc.isStylingText {
                Divider().opacity(0.6)

                HStack(spacing: 6) {
                    ForEach(TextFont.allCases) { font in
                        FontButton(font: font, isSelected: style.font == font) {
                            doc.updateStyle { $0.font = font }
                        }
                    }
                }

                HStack(spacing: 6) {
                    ForEach(TextLabelStyle.allCases) { label in
                        LabelStyleButton(label: label, style: style, isSelected: style.label == label) {
                            doc.updateStyle { $0.label = label }
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Pieces

/// A color dot with a hairline ring, so ink stays visible on a dark bar and white on a light one.
private struct SwatchDot: View {
    let color: StyleColor
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(Color(nsColor: color.nsColor))
            .overlay(Circle().strokeBorder(Color.white.opacity(color.isLight ? 0 : 0.2), lineWidth: 0.5))
            .overlay(Circle().strokeBorder(Color.black.opacity(color.isLight ? 0.15 : 0), lineWidth: 0.5))
            .frame(width: diameter, height: diameter)
    }
}

/// A short rounded bar as thick as the weight draws. `thickness` scales it down where space is tight
/// (the toolbar chip); the popover draws the real width so the four weights step visibly.
private struct WeightGlyph: View {
    let weight: StrokeWeight
    let length: CGFloat
    var thickness: CGFloat = 1

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.85))
            .frame(width: length, height: max(1.5, weight.points * thickness))
            .rotationEffect(.degrees(-35))
    }
}

/// Selection is a ring with a gap around the dot, which reads at a glance on every color.
private struct SelectionRing<Content: View>: View {
    let isSelected: Bool
    let isHovered: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .scaleEffect(isHovered && !isSelected ? 1.08 : 1)
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 1.75))
            .animation(.snappy(duration: 0.18), value: isHovered)
            .animation(.snappy(duration: 0.18), value: isSelected)
            .contentShape(Circle())
    }
}

private struct SwatchButton: View {
    let color: StyleColor
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SelectionRing(isSelected: isSelected, isHovered: isHovered) {
                SwatchDot(color: color, diameter: 22)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A hue ring that opens the system color panel. Holding a custom color, it shows it in the middle.
private struct CustomColorButton: View {
    let color: StyleColor
    let isCustom: Bool
    let action: () -> Void
    @State private var isHovered = false

    private static let hues = AngularGradient(
        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 0.78, brightness: 1) },
        center: .center
    )

    var body: some View {
        Button(action: action) {
            SelectionRing(isSelected: isCustom, isHovered: isHovered) {
                ZStack {
                    Circle().strokeBorder(Self.hues, lineWidth: 3)
                    if isCustom {
                        SwatchDot(color: color, diameter: 12)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Custom color")
        .accessibilityLabel("Custom color")
        .accessibilityAddTraits(isCustom ? .isSelected : [])
    }
}

/// The rounded tile behind the weight, font and label choices.
private struct OptionTile<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let isHovered: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .frame(width: width, height: height)
            .background(shape.fill(Color.primary.opacity(isSelected ? 0.13 : isHovered ? 0.06 : 0)))
            .overlay(shape.strokeBorder(Color.primary.opacity(isSelected ? 0.16 : 0), lineWidth: 0.5))
            .animation(.snappy(duration: 0.18), value: isSelected)
            .contentShape(shape)
    }
}

/// A stroke weight, or for text (`font` set) the size it gives, shown as a letter.
private struct WeightButton: View {
    let weight: StrokeWeight
    var font: TextFont?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OptionTile(width: 71, height: 30, isSelected: isSelected, isHovered: isHovered) {
                if let font {
                    Text("A")
                        .font(Font(font.ctFont(size: weight.textPoints * 0.55 + 3)))
                        .foregroundStyle(Color.primary.opacity(0.85))
                } else {
                    WeightGlyph(weight: weight, length: 30)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(font == nil ? weight.title : "\(weight.title) (\(Int(weight.textPoints)) pt)")
        .accessibilityLabel(font == nil ? "\(weight.title) stroke" : "\(weight.title) text")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A typeface, previewed in itself.
private struct FontButton: View {
    let font: TextFont
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OptionTile(width: 96.6, height: 44, isSelected: isSelected, isHovered: isHovered) {
                VStack(spacing: 1) {
                    Text("Aa")
                        .font(Font(font.ctFont(size: 16)))
                        .foregroundStyle(Color.primary.opacity(0.9))
                    Text(font.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(font.title)
        .accessibilityLabel("\(font.title) font")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A label style, previewed in the current color and font.
private struct LabelStyleButton: View {
    let label: TextLabelStyle
    let style: AnnotationStyle
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OptionTile(width: 96.6, height: 32, isSelected: isSelected, isHovered: isHovered) {
                preview
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label.title)
        .accessibilityLabel("\(label.title) style")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var preview: some View {
        let color = Color(nsColor: style.color.nsColor)
        let plate = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let text = Text(label.title).font(Font(style.font.ctFont(size: 11)))
        return Group {
            switch label {
            case .plain:
                text.foregroundStyle(color)
                    .shadow(color: .black.opacity(Double(TextContrast.plainShadowAlpha(for: style.color))), radius: 1, y: 0.5)
            case .filled:
                text.foregroundStyle(Color(nsColor: TextContrast.textColor(onPlate: style.color).nsColor))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(plate.fill(color))
            case .outlined:
                text.foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(plate.fill(Color(nsColor: TextContrast.outlineFill(for: style.color).nsColor)))
                    .overlay(plate.strokeBorder(color, lineWidth: 1.25))
            }
        }
    }
}

/// A tiny picture of a redaction: three lines of "text", blurred into a wash or broken into tiles. Both
/// share the same silhouette and weight, so neither reads louder than the other in the toolbar.
private struct RedactionGlyph: View {
    let mode: RedactionMode

    /// The length of each line, as a fraction of the width.
    private static let lines: [CGFloat] = [0.72, 0.5, 0.62]
    /// Tile shades along the lines, cycled: a soft mosaic of words, not a checkerboard.
    private static let shades: [Double] = [0.5, 0.32, 0.58, 0.4, 0.28, 0.52, 0.36]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let shape = RoundedRectangle(cornerRadius: size.height * 0.22, style: .continuous)
            ZStack {
                shape.fill(Color.primary.opacity(0.08))
                switch mode {
                case .blur:
                    VStack(alignment: .leading, spacing: size.height * 0.12) {
                        ForEach(0..<3, id: \.self) { line in
                            Capsule()
                                .fill(Color.primary.opacity(0.75))
                                .frame(width: size.width * Self.lines[line], height: size.height * 0.14)
                        }
                    }
                    .blur(radius: size.height * 0.08)
                case .pixelate:
                    let tile = size.height * 0.19
                    VStack(alignment: .leading, spacing: size.height * 0.05) {
                        ForEach(0..<3, id: \.self) { line in
                            HStack(spacing: 0) {
                                ForEach(0..<max(2, Int((size.width * Self.lines[line] / tile).rounded())), id: \.self) { i in
                                    Rectangle()
                                        .fill(Color.primary.opacity(Self.shades[(i + line * 3) % Self.shades.count]))
                                        .frame(width: tile, height: tile)
                                }
                            }
                        }
                    }
                }
            }
            .clipShape(shape)
        }
        .accessibilityHidden(true)
    }
}

private struct RedactionModeButton: View {
    let mode: RedactionMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OptionTile(width: 96, height: 66, isSelected: isSelected, isHovered: isHovered) {
                VStack(spacing: 6) {
                    RedactionGlyph(mode: mode)
                        .frame(width: 44, height: 30)
                    Text(mode.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(mode.title) (B switches)")
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Color panel

/// Connects the shared system color panel to one editor at a time, for the custom color well.
/// Each drag in the panel restyles the selection live, as a single undo step.
final class StyleColorPanel: NSObject {
    static let shared = StyleColorPanel()

    private weak var doc: EditorDocument?
    /// Whether the panel's target is us. Kept apart from `doc` (which goes nil when its editor closes)
    /// because the panel itself stays open and should keep working for the next editor.
    private var ownsPanel = false
    /// When the last pick arrived. A drag sends picks every few milliseconds, so a longer pause means
    /// a new gesture (releasing a drag sends nothing the panel would tell us about).
    private var lastPick: TimeInterval = 0
    private static let gestureGap: TimeInterval = 0.4

    func show(for doc: EditorDocument) {
        let panel = NSColorPanel.shared
        // Set the color before the target so seeding the panel isn't taken as a pick.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = doc.displayedStyle.color.nsColor
        attach(to: doc)
        panel.orderFront(nil)
    }

    /// Another editor became key: the open panel now edits that one, including a panel left open
    /// after the editor that opened it closed.
    func follow(_ doc: EditorDocument) {
        guard ownsPanel, self.doc !== doc, NSColorPanel.shared.isVisible else { return }
        attach(to: doc)
    }

    /// The editor closed. The panel stays ours (picks are ignored until another editor attaches).
    func detach(from doc: EditorDocument) {
        guard self.doc === doc else { return }
        self.doc = nil
    }

    private func attach(to doc: EditorDocument) {
        self.doc?.endStyleCoalescing()
        doc.endStyleCoalescing()
        self.doc = doc
        ownsPanel = true
        NSColorPanel.shared.setTarget(self)
        NSColorPanel.shared.setAction(#selector(colorChanged(_:)))
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let doc, let color = StyleColor(panel.color)?.withAlpha(1) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPick > Self.gestureGap { doc.endStyleCoalescing() }
        lastPick = now
        doc.updateStyle(coalescing: true) { $0.color = color }
        // With no button held this was a discrete pick (a crayon, a palette swatch, the hex field),
        // so the next change gets its own undo step.
        if NSEvent.pressedMouseButtons == 0 { doc.endStyleCoalescing() }
    }
}
