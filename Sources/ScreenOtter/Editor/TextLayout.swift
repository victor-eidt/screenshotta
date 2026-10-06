import AppKit
import CoreText

/// Paddings, corners and borders of a text label, as fractions of the font size so a label looks the
/// same at every size (resizing scales everything together).
nonisolated struct TextLabelMetrics: Equatable, Sendable {
    var label: TextLabelStyle
    var fontSize: CGFloat

    /// Space between the text's ink box (cap top to last baseline) and the plate's sides.
    var horizontalPadding: CGFloat { fontSize * (label == .plain ? 0.14 : 0.62) }
    /// The ink box runs from the cap top to the baseline, so equal padding above and below centers the
    /// capitals optically; descenders fit inside the bottom padding.
    var verticalPadding: CGFloat { fontSize * (label == .plain ? 0.38 : 0.5) }
    var borderWidth: CGFloat { label == .outlined ? fontSize * 0.085 : 0 }

    /// Continuous (squircle) corners: soft like a pill on one line, without turning a multi-line label
    /// into a stadium.
    func cornerRadius(for plate: CGRect) -> CGFloat {
        min(fontSize * 0.55, ContinuousCorners.maxRadius(for: plate))
    }

    func plate(around inkBox: CGRect) -> CGRect {
        inkBox.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
    }

    /// Where the ink box's top-left goes so the plate's top-left stays at `plateOrigin`.
    func inkOrigin(forPlateAt plateOrigin: CGPoint) -> CGPoint {
        CGPoint(x: plateOrigin.x + horizontalPadding, y: plateOrigin.y + verticalPadding)
    }
}

/// Text colors that read on a label: dark text on light plates, white on the rest.
nonisolated enum TextContrast {
    static let ink = StyleColor(hex: "#1C1C21")!
    static let white = StyleColor(red: 255, green: 255, blue: 255)

    static func textColor(onPlate plate: StyleColor) -> StyleColor {
        plate.isLight ? ink : white
    }

    /// The fill behind an outlined label: white with a hint of the color under a dark or saturated one,
    /// ink under a light one, so the colored text always has something calm to sit on.
    static func outlineFill(for color: StyleColor) -> StyleColor {
        color.isLight ? ink.withAlpha(0.9) : white.mixed(with: color, amount: 0.07)
    }

    /// The soft shadow under plain text: stronger for light text (which needs it on light backgrounds),
    /// barely there for dark text, where a heavy shadow just looks smudged.
    static func plainShadowAlpha(for color: StyleColor) -> CGFloat {
        0.12 + 0.3 * CGFloat(color.luminance)
    }
}

extension StyleColor {
    /// This color moved `amount` (0 to 1) of the way towards `other`, keeping this color's alpha.
    nonisolated func mixed(with other: StyleColor, amount: CGFloat) -> StyleColor {
        let t = min(max(amount, 0), 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((CGFloat(a) + (CGFloat(b) - CGFloat(a)) * t).rounded()) }
        return StyleColor(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue), alpha: alpha)
    }
}

/// The geometry of one text annotation, in image pixels with a top-left origin.
/// The annotation's `start` is the top-left of the ink box: the first line's cap top.
struct TextLayout {
    let font: CTFont
    let fontSize: CGFloat
    let lines: [String]
    let lineWidths: [CGFloat]
    let ascent: CGFloat
    let capHeight: CGFloat
    let lineHeight: CGFloat
    let metrics: TextLabelMetrics
    let origin: CGPoint

    init(text: String, font textFont: TextFont, fontSize: CGFloat, label: TextLabelStyle, origin: CGPoint) {
        self.fontSize = fontSize
        self.origin = origin
        let font = textFont.ctFont(size: fontSize)
        let lines = text.components(separatedBy: "\n")
        self.font = font
        self.lines = lines
        lineWidths = lines.map { line in
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(Self.attributed(line, font: font, color: nil)), nil, nil, nil))
        }
        ascent = CTFontGetAscent(font)
        capHeight = CTFontGetCapHeight(font)
        lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        metrics = TextLabelMetrics(label: label, fontSize: fontSize)
    }

    init(_ a: Annotation) {
        self.init(text: a.text, font: a.style.font, fontSize: a.fontPixelSize, label: a.style.label, origin: a.start)
    }

    /// From the first line's cap top to the last line's baseline.
    var inkBox: CGRect {
        CGRect(x: origin.x, y: origin.y, width: lineWidths.max() ?? 0, height: capHeight + CGFloat(lines.count - 1) * lineHeight)
    }

    var plate: CGRect { metrics.plate(around: inkBox) }

    func baseline(ofLine index: Int) -> CGFloat {
        origin.y + capHeight + CGFloat(index) * lineHeight
    }

    /// Where an editor's text view goes so its glyphs land on the drawn ones: its first line box starts
    /// one ascent above the first baseline.
    var lineBoxesFrame: CGRect {
        CGRect(x: origin.x, y: baseline(ofLine: 0) - ascent, width: inkBox.width, height: CGFloat(lines.count) * lineHeight)
    }

    static func attributed(_ string: String, font: CTFont, color: CGColor?) -> CFAttributedString {
        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if let color { attributes[kCTForegroundColorAttributeName] = color }
        return CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
    }
}

/// Resizing a text label by its corner handle: the font scales with how far the handle travels along
/// the label's diagonal, so the label grows and shrinks in proportion.
nonisolated enum TextResize {
    static let pointRange: ClosedRange<CGFloat> = 9...240

    /// - Parameters:
    ///   - anchor: the corner that stays put (the plate's top-left).
    ///   - corner: where the dragged corner started.
    ///   - current: where the pointer is now.
    static func fontSize(original: CGFloat, anchor: CGPoint, corner: CGPoint, current: CGPoint, scale: CGFloat) -> CGFloat {
        let diagonal = CGPoint(x: corner.x - anchor.x, y: corner.y - anchor.y)
        let lengthSquared = diagonal.x * diagonal.x + diagonal.y * diagonal.y
        guard lengthSquared > 0 else { return original }
        let projected = ((current.x - anchor.x) * diagonal.x + (current.y - anchor.y) * diagonal.y) / lengthSquared
        let points = original * max(projected, 0) / scale
        return min(max(points, pointRange.lowerBound), pointRange.upperBound) * scale
    }
}

/// Rounded rectangles with continuous ("squircle") corners, the way macOS and iOS draw them: the curve
/// eases into the straight edge instead of meeting it abruptly, which reads softer and more modern.
nonisolated enum ContinuousCorners {
    /// The curve extends this many radii along each edge.
    static let extent: CGFloat = 1.528_664_83
    /// The curve crosses the corner's diagonal this many radii in from the corner, on both axes.
    static let diagonalInset: CGFloat = 0.291_508

    /// The largest radius that still leaves room for the eased curve on the shorter side.
    static func maxRadius(for rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) / 2 / extent
    }

    static func path(in rect: CGRect, radius requested: CGFloat) -> CGPath {
        let r = min(max(requested, 0), maxRadius(for: rect))
        guard r > 0 else { return CGPath(rect: rect, transform: nil) }

        func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.minY + y * r) }
        func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.minY + y * r) }
        func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.maxY - y * r) }
        func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.maxY - y * r) }

        // One corner's curve, in units of the radius, starting on the horizontal edge. The same numbers
        // mirrored give every corner.
        let path = CGMutablePath()
        path.move(to: tl(extent, 0))
        path.addLine(to: tr(extent, 0))
        path.addCurve(to: tr(0.669_934_27, 0.065_496), control1: tr(1.088_493_23, 0), control2: tr(0.868_406_89, 0))
        path.addLine(to: tr(0.631_493_99, 0.074_911))
        path.addCurve(to: tr(0.074_911_76, 0.631_493_99), control1: tr(0.372_823_92, 0.169_058_99), control2: tr(0.169_060_13, 0.372_824_01))
        path.addCurve(to: tr(0, extent), control1: tr(0, 0.868_407_01), control2: tr(0, 1.088_492_99))
        path.addLine(to: br(0, extent))
        path.addCurve(to: br(0.065_495_69, 0.669_934_93), control1: br(0, 1.088_492_99), control2: br(0, 0.868_406_89))
        path.addLine(to: br(0.074_911_11, 0.631_493_99))
        path.addCurve(to: br(0.631_493_99, 0.074_911_11), control1: br(0.169_058_83, 0.372_823_92), control2: br(0.372_823_92, 0.169_058_83))
        path.addCurve(to: br(extent, 0), control1: br(0.868_406_89, 0), control2: br(1.088_493_23, 0))
        path.addLine(to: bl(extent, 0))
        path.addCurve(to: bl(0.669_933_97, 0.065_495_69), control1: bl(1.088_492_99, 0), control2: bl(0.868_407_01, 0))
        path.addLine(to: bl(0.631_493_99, 0.074_911_11))
        path.addCurve(to: bl(0.074_911, 0.631_493_99), control1: bl(0.372_824_01, 0.169_058_83), control2: bl(0.169_060_01, 0.372_823_92))
        path.addCurve(to: bl(0, extent), control1: bl(0, 0.868_406_89), control2: bl(0, 1.088_493_23))
        path.addLine(to: tl(0, extent))
        path.addCurve(to: tl(0.065_496, 0.669_933_97), control1: tl(0, 1.088_492_99), control2: tl(0, 0.868_407_01))
        path.addLine(to: tl(0.074_911, 0.631_493_99))
        path.addCurve(to: tl(0.631_493_99, 0.074_911), control1: tl(0.169_060_01, 0.372_824_01), control2: tl(0.372_824_01, 0.169_060_01))
        path.addCurve(to: tl(extent, 0), control1: tl(0.868_407_01, 0), control2: tl(1.088_492_99, 0))
        path.closeSubpath()
        return path
    }
}

extension AnnotationRenderer {
    /// Draws a text annotation as vectors, so it stays crisp at the image's full pixel density.
    static func drawText(_ a: Annotation, in ctx: CGContext, unit: CGFloat) {
        let layout = TextLayout(a)
        let size = layout.fontSize
        let color = a.style.color
        let textColor: StyleColor

        ctx.saveGState()
        switch a.style.label {
        case .plain:
            textColor = color
            ctx.setShadow(
                offset: CGSize(width: 0, height: -size * 0.03 * unit),
                blur: size * 0.1 * unit,
                color: CGColor(gray: 0, alpha: TextContrast.plainShadowAlpha(for: color))
            )
            // One transparency layer so overlapping glyph shadows don't stack.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        case .filled, .outlined:
            let plate = layout.plate
            let shape = ContinuousCorners.path(in: plate, radius: layout.metrics.cornerRadius(for: plate))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06 * unit), blur: size * 0.45 * unit, color: CGColor(gray: 0, alpha: 0.26))
            ctx.addPath(shape)
            ctx.setFillColor((a.style.label == .filled ? color : TextContrast.outlineFill(for: color)).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            if a.style.label == .outlined {
                let border = layout.metrics.borderWidth
                let inner = plate.insetBy(dx: border / 2, dy: border / 2)
                ctx.addPath(ContinuousCorners.path(in: inner, radius: layout.metrics.cornerRadius(for: plate) - border / 2))
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(border)
                ctx.strokePath()
                textColor = color
            } else {
                textColor = TextContrast.textColor(onPlate: color)
            }
        }

        ctx.textMatrix = .identity
        for (index, line) in layout.lines.enumerated() where !line.isEmpty {
            let ctLine = CTLineCreateWithAttributedString(TextLayout.attributed(line, font: layout.font, color: textColor.cgColor))
            ctx.saveGState()
            // The context is flipped (top-left origin); CoreText draws upright in a y-up space.
            ctx.translateBy(x: layout.origin.x, y: layout.baseline(ofLine: index))
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }

        if a.style.label == .plain { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }
}
