import AppKit

/// An sRGB color stored as 8-bit components, so it compares exactly (a custom color can be matched
/// against the palette) and saves as a short hex string.
nonisolated struct StyleColor: Hashable, Sendable, Codable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` or `#RRGGBBAA`, with or without the `#`.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        red = UInt8(rgba >> 24 & 0xFF)
        green = UInt8(rgba >> 16 & 0xFF)
        blue = UInt8(rgba >> 8 & 0xFF)
        alpha = UInt8(rgba & 0xFF)
    }

    /// Any color, converted to sRGB. Colors that can't be converted (patterns) come back as nil.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent), alpha: byte(srgb.alphaComponent))
    }

    var hex: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 255 ? rgb : rgb + String(format: "%02X", alpha)
    }

    func withAlpha(_ alpha: CGFloat) -> StyleColor {
        var copy = self
        copy.alpha = UInt8((min(max(alpha, 0), 1) * 255).rounded())
        return copy
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Light colors want dark content on top of them (text on a label, a checkmark on a swatch).
    var isLight: Bool { luminance > 0.45 }

    init(from decoder: Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let color = StyleColor(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a hex color: \(hex)"))
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// How heavy an annotation is. Each tool maps it to its own size: a line width for shapes,
/// a font size for text, so one control drives them all. Redactions size themselves from their region.
nonisolated enum StrokeWeight: String, CaseIterable, Identifiable, Codable, Sendable {
    case fine, regular, bold, heavy

    var id: Self { self }

    /// Line width in points; multiplied by the image scale when drawing.
    var points: CGFloat {
        switch self {
        case .fine: 2.5
        case .regular: 4
        case .bold: 6
        case .heavy: 9
        }
    }

    /// Font size in points for text, which reads the weight as a size.
    var textPoints: CGFloat {
        switch self {
        case .fine: 14
        case .regular: 18
        case .bold: 24
        case .heavy: 34
        }
    }

    var title: String {
        switch self {
        case .fine: "Fine"
        case .regular: "Regular"
        case .bold: "Bold"
        case .heavy: "Heavy"
        }
    }
}

/// The look shared by every annotation tool. The last used style becomes the default for the next screenshot.
nonisolated struct AnnotationStyle: Codable, Equatable, Sendable {
    var color: StyleColor
    var weight: StrokeWeight
    /// Text only: the typeface and how the label sits on the image. Shapes carry and ignore them, so
    /// switching tools keeps the last text look.
    var font: TextFont
    var label: TextLabelStyle
    /// Redactions only: blur or pixelate. Kept with the rest so the last one used comes back.
    var redaction: RedactionMode
    /// Highlighter only: its own ink, so a soft yellow marker sits next to a coral arrow by default.
    var marker: StyleColor
    /// Highlighter only: its own height, so heavy demo arrows don't give the next marker a band taller
    /// than a line of text (and a thick marker doesn't make the next arrow heavy).
    var markerWeight: StrokeWeight
    /// Spotlights only: dim, or dim and blur.
    var spotlight: SpotlightMode

    static let `default` = AnnotationStyle()

    init(
        color: StyleColor = AnnotationPalette.swatches[0].color,
        weight: StrokeWeight = .regular,
        font: TextFont = .geist,
        label: TextLabelStyle = .filled,
        redaction: RedactionMode = .blur,
        marker: StyleColor = HighlighterPalette.default,
        markerWeight: StrokeWeight = .regular,
        spotlight: SpotlightMode = .dim
    ) {
        self.color = color
        self.weight = weight
        self.font = font
        self.label = label
        self.redaction = redaction
        self.marker = marker
        self.markerWeight = markerWeight
        self.spotlight = spotlight
    }

    // Decoding field by field keeps a saved style readable when fields are added, renamed or removed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnnotationStyle()
        color = (try? c.decode(StyleColor.self, forKey: .color)) ?? d.color
        weight = (try? c.decode(StrokeWeight.self, forKey: .weight)) ?? d.weight
        font = (try? c.decode(TextFont.self, forKey: .font)) ?? d.font
        label = (try? c.decode(TextLabelStyle.self, forKey: .label)) ?? d.label
        redaction = (try? c.decode(RedactionMode.self, forKey: .redaction)) ?? d.redaction
        marker = (try? c.decode(StyleColor.self, forKey: .marker)) ?? d.marker
        markerWeight = (try? c.decode(StrokeWeight.self, forKey: .markerWeight)) ?? d.markerWeight
        spotlight = (try? c.decode(SpotlightMode.self, forKey: .spotlight)) ?? d.spotlight
    }

    private enum CodingKeys: String, CodingKey {
        case color, weight, font, label, redaction, marker, markerWeight, spotlight
    }

    private static let defaultsKey = "annotationStyle"

    static func lastUsed(in defaults: UserDefaults = .standard) -> AnnotationStyle {
        guard let data = defaults.data(forKey: defaultsKey),
              let style = try? JSONDecoder().decode(AnnotationStyle.self, from: data)
        else { return .default }
        return style
    }

    func rememberAsDefault(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A short, curated set that reads well on light and dark UIs and in a launch post: vivid but not neon,
/// plus ink and white for a quieter look. Anything else comes from the custom color well.
nonisolated enum AnnotationPalette {
    struct Swatch: Identifiable, Sendable {
        let name: String
        let color: StyleColor
        var id: String { name }
    }

    static let swatches: [Swatch] = [
        Swatch(name: "Coral", color: StyleColor(hex: "#FF4B3E")!),
        Swatch(name: "Orange", color: StyleColor(hex: "#FF8A1F")!),
        Swatch(name: "Amber", color: StyleColor(hex: "#FFC328")!),
        Swatch(name: "Green", color: StyleColor(hex: "#2BC46D")!),
        Swatch(name: "Blue", color: StyleColor(hex: "#3B7BFF")!),
        Swatch(name: "Violet", color: StyleColor(hex: "#8E5CFF")!),
        Swatch(name: "Ink", color: StyleColor(hex: "#1C1C21")!),
        Swatch(name: "White", color: StyleColor(hex: "#FFFFFF")!),
    ]

    /// The palette entry for a color, or nil for a custom color.
    static func swatch(for color: StyleColor) -> Swatch? {
        swatches.swatch(for: color)
    }

    /// Number keys pick swatches: 1 is the first.
    static func swatch(forKey character: Character) -> Swatch? {
        swatches.swatch(forKey: character)
    }
}

extension [AnnotationPalette.Swatch] {
    /// The entry for a color, or nil for a custom color.
    nonisolated func swatch(for color: StyleColor) -> AnnotationPalette.Swatch? {
        first { $0.color == color }
    }

    /// Number keys pick swatches: 1 is the first.
    nonisolated func swatch(forKey character: Character) -> AnnotationPalette.Swatch? {
        guard let n = character.wholeNumberValue, (1...count).contains(n) else { return nil }
        return self[n - 1]
    }
}
