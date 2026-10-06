import AppKit
import CoreImage
import CoreText

/// Draws the caption box for the renderer: the phrase in SF Pro, centred, on the keystroke pill's glass with a
/// fixed corner radius however many lines it takes. Words already said are drawn full; the rest wait a shade
/// quieter until they're spoken.
nonisolated enum CaptionArt {
    /// The phrase as drawn, with `inset` of room on each side for glyphs that overhang.
    struct Text: @unchecked Sendable {
        let image: CGImage
        /// The lines' own size, which sets the box's.
        let size: CGSize
        let inset: CGFloat
    }

    // Proportions, in font sizes.
    static let horizontalPadding: CGFloat = 0.8
    static let verticalPadding: CGFloat = 0.5
    static let corner: CGFloat = 0.75
    static let lineSpacing: CGFloat = 0.12
    /// The phrase wraps to stay within this share of the video's width.
    static let maxWidthShare: CGFloat = 0.84

    private static let lock = NSLock()
    nonisolated(unsafe) private static var texts: [String: Text] = [:]

    static func fontSize(_ style: CaptionStyle, canvas: CGSize) -> CGFloat {
        max(10, (style.size.fraction * min(canvas.width, canvas.height)).rounded())
    }

    static func text(_ p: CaptionPresentation, style: CaptionStyle, fontSize: CGFloat, maxWidth: CGFloat) -> Text? {
        let spoken = style.highlightWords ? p.spoken : p.cue.words.count
        let key = "\(p.cue.id)-\(p.cue.text)-\(spoken)-\(style.theme.rawValue)-\(fontSize)-\(maxWidth.rounded())"
        if let cached = lock.withLock({ texts[key] }) { return cached }

        let font = KeystrokeArt.font(size: fontSize)
        let colors = palette(style.theme)
        var alignment = CTTextAlignment.center
        var spacing = fontSize * lineSpacing
        let paragraph = withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &spacing) { spacingBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: spacingBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let string = NSMutableAttributedString()
        for (index, word) in p.cue.words.enumerated() {
            let separator = index < p.cue.words.count - 1 ? " " : ""
            string.append(NSAttributedString(string: word.text + separator, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: index < spoken ? colors.said : colors.waiting,
                kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
            ]))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil
        )
        let size = CGSize(width: fitted.width.rounded(.up), height: fitted.height.rounded(.up))
        let inset = (fontSize * 0.25).rounded(.up)
        let width = Int(size.width + inset * 2), height = Int(size.height + inset * 2)
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setAllowsFontSmoothing(false)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: inset, y: inset, width: size.width, height: size.height), transform: nil), nil
        )
        CTFrameDraw(frame, ctx)
        guard let image = ctx.makeImage() else { return nil }

        let text = Text(image: image, size: size, inset: inset)
        lock.withLock {
            if texts.count > 96 { texts.removeAll() }
            texts[key] = text
        }
        return text
    }

    private static func palette(_ theme: KeystrokeTheme) -> (said: CGColor, waiting: CGColor) {
        switch theme {
        case .dark: (CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.5))
        case .light: (CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1), CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.42))
        }
    }

    /// The box at a moment over `backdrop` (the finished frame, Core Image coordinates), and where it sits in
    /// top-left-origin output pixels, or nil when no caption is showing. `content` is where the video sits.
    static func overlay(_ p: CaptionPresentation, style: CaptionStyle, backdrop: CIImage, canvas: CGSize, content: CGRect) -> (image: CIImage, frame: CGRect)? {
        guard p.opacity > 0.01 else { return nil }
        let fontSize = fontSize(style, canvas: canvas)
        let padding = CGSize(width: (fontSize * horizontalPadding).rounded(), height: (fontSize * verticalPadding).rounded())
        let maxWidth = max(fontSize * 4, content.width * maxWidthShare - padding.width * 2)
        guard let text = text(p, style: style, fontSize: fontSize, maxWidth: maxWidth) else { return nil }
        let size = CGSize(width: text.size.width + padding.width * 2, height: text.size.height + padding.height * 2)
        guard let body = KeystrokeArt.body(theme: style.theme, size: size, corner: (fontSize * corner).rounded()) else { return nil }

        let center = KeystrokeLayout.center(style.position, size: body.size, canvas: canvas, content: content)
        let origin = CGPoint(x: (center.x - body.size.width / 2).rounded(), y: (canvas.height - center.y - body.size.height / 2).rounded())
        let move = CGAffineTransform(translationX: origin.x, y: origin.y)
        let words = CIImage(cgImage: text.image).transformed(by: CGAffineTransform(
            translationX: origin.x + ((body.size.width - text.size.width) / 2).rounded() - text.inset,
            y: origin.y + ((body.size.height - text.size.height) / 2).rounded() - text.inset
        ))
        var box = words.composited(over: CIImage(cgImage: body.image).transformed(by: CGAffineTransform(translationX: origin.x - body.padding, y: origin.y - body.padding)))
        let rect = CGRect(origin: origin, size: body.size)
        if let glass = KeystrokeArt.glass(behind: rect, mask: CIImage(cgImage: body.mask).transformed(by: move), backdrop: backdrop, height: fontSize * 1.6) {
            box = box.composited(over: glass)
        }
        let frame = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
        return (KeystrokeArt.fade(box, p.opacity), frame)
    }
}
