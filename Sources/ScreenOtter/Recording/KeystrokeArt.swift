import AppKit
import CoreImage
import CoreText

/// Draws the keystroke pill for the renderer: the keys set in SF Pro on a smoked (or frosted) glass pill
/// with continuous corners, a hairline edge and a soft shadow. The pill's body and its line of keys are drawn
/// apart, so the pill can resize smoothly when a key joins it; the glass itself (the blurred video behind the
/// pill) is added by `glass(behind:)` per frame.
nonisolated enum KeystrokeArt {
    /// The pill without its keys.
    struct Body: @unchecked Sendable {
        /// Shadow, tint and edge, larger than the pill by `padding` on every side.
        let image: CGImage
        /// White where the pill is, at the pill's size.
        let mask: CGImage
        let size: CGSize
        let padding: CGFloat
    }

    /// The pill's line of keys, pill-high, with `inset` of room on each side for glyphs that overhang.
    struct Label: @unchecked Sendable {
        let image: CGImage
        /// Typographic width of the text, which sets the pill's.
        let width: CGFloat
        let inset: CGFloat
        /// The text as a string, to tell when one label only extends another.
        let text: String
    }

    private struct Palette {
        let tint: CGColor
        let sheen: CGColor
        let edge: CGColor
        let key: CGColor
        /// Modifiers and repeat counts: present but quieter than the key itself.
        let secondary: CGColor
        let shadow: CGFloat
    }

    private static func palette(_ theme: KeystrokeTheme) -> Palette {
        switch theme {
        case .dark:
            Palette(
                tint: CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.84),
                sheen: CGColor(gray: 1, alpha: 0.07),
                edge: CGColor(gray: 1, alpha: 0.16),
                key: CGColor(gray: 1, alpha: 1),
                secondary: CGColor(gray: 1, alpha: 0.62),
                shadow: 0.34
            )
        case .light:
            Palette(
                tint: CGColor(gray: 1, alpha: 0.8),
                sheen: CGColor(gray: 1, alpha: 0.5),
                edge: CGColor(gray: 0, alpha: 0.08),
                key: CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1),
                secondary: CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.5),
                shadow: 0.18
            )
        }
    }

    // Proportions of the pill, from its height.
    static let fontScale: CGFloat = 0.42
    static let horizontalPadding: CGFloat = 0.42
    /// Space between two shortcuts on one pill, in font sizes.
    static let itemGap: CGFloat = 0.75
    /// Corners span this much of the height on each side: round, but still a soft rectangle, not a capsule.
    static let cornerFraction: CGFloat = 0.4

    private static let lock = NSLock()
    nonisolated(unsafe) private static var labels: [String: Label] = [:]
    nonisolated(unsafe) private static var bodies: [String: Body] = [:]

    /// The width of a pill `height` high around text `textWidth` wide.
    static func pillWidth(textWidth: CGFloat, height: CGFloat) -> CGFloat {
        max(height, (textWidth + height * horizontalPadding * 2).rounded())
    }

    static func label(items: [KeystrokeItem], theme: KeystrokeTheme, height: CGFloat) -> Label? {
        let h = height.rounded()
        guard h >= 8, !items.isEmpty else { return nil }
        let key = "\(theme.rawValue)-\(h)-\(items)"
        if let cached = lock.withLock({ labels[key] }) { return cached }

        let fontSize = h * fontScale
        let string = text(items, fontSize: fontSize, colors: palette(theme))
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetTypographicBounds(line, nil, nil, nil)
        let textWidth = CGFloat(bounds - CTLineGetTrailingWhitespaceWidth(line))
        let inset = (fontSize * 0.25).rounded(.up)
        guard let image = draw(width: Int((textWidth + inset * 2).rounded(.up)), height: Int(h), { ctx in
            // Optically centred on the cap height, where the glyphs sit.
            let capHeight = CTFontGetCapHeight(font(size: fontSize))
            ctx.textPosition = CGPoint(x: inset, y: (h / 2 - capHeight / 2).rounded())
            CTLineDraw(line, ctx)
        }) else { return nil }

        let label = Label(image: image, width: textWidth, inset: inset, text: string.string)
        lock.withLock {
            if labels.count > 64 { labels.removeAll() }
            labels[key] = label
        }
        return label
    }

    /// `corner`: the corner radius, for boxes taller than one line (the captions'); the pill's own by default.
    static func body(theme: KeystrokeTheme, size: CGSize, corner: CGFloat? = nil) -> Body? {
        let h = size.height.rounded(), width = size.width.rounded()
        guard h >= 8, width >= h else { return nil }
        let fraction = corner.map { $0 / h } ?? cornerFraction
        let key = "\(theme.rawValue)-\(width)x\(h)-\(fraction)"
        if let cached = lock.withLock({ bodies[key] }) { return cached }

        let colors = palette(theme)
        let pad = (h * 0.7).rounded(.up)
        let pillRect = CGRect(x: pad, y: pad, width: width, height: h)
        let path = shape(in: pillRect, cornerFraction: fraction)
        guard let image = draw(width: Int(width + pad * 2), height: Int(h + pad * 2), { ctx in
            // A wide ambient shadow for lift and a tight one that seats the edge; cut out under the pill so
            // the glass stays clear.
            for (blur, offset, alpha) in [(h * 0.42, h * 0.14, colors.shadow), (h * 0.06, h * 0.025, colors.shadow * 0.6)] {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur, color: CGColor(gray: 0, alpha: alpha))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.addPath(path)
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(colors.tint)
            ctx.fill(pillRect)
            // Light catching the top half of the glass.
            if let sheen = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [colors.sheen, colors.sheen.copy(alpha: 0)!] as CFArray, locations: [0, 1]
            ) {
                ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: pillRect.maxY), end: CGPoint(x: 0, y: pillRect.midY), options: [])
            }
            // A hairline just inside the edge.
            ctx.addPath(path)
            ctx.setLineWidth(max(1, h * 0.022) * 2)
            ctx.setStrokeColor(colors.edge)
            ctx.strokePath()
        }) else { return nil }

        guard let mask = draw(width: Int(width), height: Int(h), { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(shape(in: CGRect(x: 0, y: 0, width: width, height: h), cornerFraction: fraction))
            ctx.fillPath()
        }) else { return nil }

        let body = Body(image: image, mask: mask, size: CGSize(width: width, height: h), padding: pad)
        lock.withLock {
            // While the pill resizes, a body is drawn for each width it passes through.
            if bodies.count > 64 { bodies.removeAll() }
            bodies[key] = body
        }
        return body
    }

    /// The pill's outline: a rounded rectangle with continuous corners, like the webcam bubble's squircle.
    static func shape(in rect: CGRect, cornerFraction: CGFloat = cornerFraction) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: WebcamShape.continuousRoundedRect(in: rect, cornerFraction: cornerFraction, exponent: 3.6, pointsPerCorner: 48))
        path.closeSubpath()
        return path
    }

    static func font(size: CGFloat) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
    }

    /// The pill's line of text: modifiers quieter than the key, repeats as a small "×3", a wide gap between
    /// shortcuts.
    private static func text(_ items: [KeystrokeItem], fontSize: CGFloat, colors: Palette) -> NSAttributedString {
        let font = self.font(size: fontSize)
        let small = NSFont.systemFont(ofSize: fontSize * 0.8, weight: .semibold) as CTFont
        let result = NSMutableAttributedString()
        /// `kern` is the space after the string's last character only.
        func append(_ string: String, color: CGColor, font: CTFont = font, kern: CGFloat = 0) {
            guard let last = string.last else { return }
            func run(_ part: String, kern: CGFloat) -> NSAttributedString {
                NSAttributedString(string: part, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: color,
                    kCTKernAttributeName as NSAttributedString.Key: kern,
                ])
            }
            result.append(run(String(string.dropLast()), kern: 0))
            result.append(run(String(last), kern: kern))
        }
        for (index, item) in items.enumerated() {
            let gap = index < items.count - 1 ? fontSize * itemGap : 0
            switch item {
            case let .chord(modifiers, key, count):
                for glyph in modifiers.glyphs {
                    append(glyph, color: colors.secondary, kern: fontSize * 0.1)
                }
                let last = count > 1 ? 0 : gap
                // A word key (Space, Esc, F5) reads better a touch apart from its modifiers.
                if !modifiers.isEmpty, key.count > 1 { append("\u{2009}", color: colors.secondary) }
                append(key, color: colors.key, kern: last)
                if count > 1 {
                    append("\u{2009}×\(count)", color: colors.secondary, font: small, kern: gap)
                }
            case let .text(run):
                append(run, color: colors.key, kern: gap)
            }
        }
        return result
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        body(ctx)
        return ctx.makeImage()
    }

    // MARK: - Compositing

    /// The pill at output time `t` over `backdrop` (the finished frame, Core Image coordinates), or nil when
    /// no keys are showing. `content` is where the video sits, in top-left-origin output pixels.
    /// `lift` moves the pill away from its edge, to make room for a caption showing there.
    static func overlay(
        groups: [KeystrokeGroup], style: KeystrokeStyle, at t: Double, backdrop: CIImage, canvas: CGSize, content: CGRect, lift: CGFloat = 0
    ) -> CIImage? {
        guard let p = KeystrokePresentation.at(t, groups: groups), p.opacity > 0.01 else { return nil }
        let h = KeystrokeLayout.height(style, canvas: canvas)
        guard let label = label(items: p.items, theme: style.theme, height: h) else { return nil }
        let old = p.previous.flatMap { self.label(items: $0, theme: style.theme, height: h) }

        // While resizing, the pill and its text width go from the old label's to the new one's.
        let mix = { (from: CGFloat, to: CGFloat) in from + (to - from) * CGFloat(p.resize) }
        let textWidth = old.map { mix($0.width, label.width) } ?? label.width
        let width = old.map { mix(pillWidth(textWidth: $0.width, height: h), pillWidth(textWidth: label.width, height: h)) }
            ?? pillWidth(textWidth: label.width, height: h)
        guard let body = body(theme: style.theme, size: CGSize(width: width, height: h)) else { return nil }
        let size = body.size

        // The pill drawn at the origin, unscaled: the body, then the keys from its left padding.
        let textX = ((size.width - textWidth) / 2).rounded()
        func place(_ l: Label) -> CIImage {
            CIImage(cgImage: l.image).transformed(by: CGAffineTransform(translationX: textX - l.inset, y: 0))
        }
        var keys = place(label)
        if let old {
            if label.text.hasPrefix(old.text) {
                // Keys joined the end: the old ones stay put and only the new ones fade in after them, a beat
                // behind the pill opening up to make room.
                let tail = keys.cropped(to: CGRect(x: textX + old.width + 1, y: 0, width: label.width + label.inset * 2, height: size.height))
                keys = fade(tail, p.resize * p.resize).composited(over: place(old))
            } else {
                keys = fade(keys, p.resize).composited(over: fade(place(old), 1 - p.resize))
            }
            keys = keys.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: CIImage(cgImage: body.mask),
            ])
        }
        var pill = keys.composited(over: CIImage(cgImage: body.image).transformed(by: CGAffineTransform(translationX: -body.padding, y: -body.padding)))

        var center = KeystrokeLayout.center(style, size: size, canvas: canvas, content: content)
        // It rises in from the edge it sits on, and steps back from it by `lift`.
        center.y += (CGFloat(p.rise) * h - lift) * (style.position == .top ? -1 : 1)
        let k = CGFloat(p.scale)
        let scaled = CGSize(width: size.width * k, height: size.height * k)
        var origin = CGPoint(x: center.x - scaled.width / 2, y: canvas.height - center.y - scaled.height / 2)
        if abs(k - 1) < 0.001 {
            // Settled: whole pixels, so the text is as crisp as it was drawn.
            origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        }
        let transform = CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        pill = pill.transformed(by: transform)
        let rect = CGRect(origin: origin, size: scaled)
        if let glass = glass(behind: rect, mask: CIImage(cgImage: body.mask).transformed(by: transform), backdrop: backdrop, height: scaled.height) {
            pill = pill.composited(over: glass)
        }
        return fade(pill, p.opacity)
    }

    static func fade(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }

    /// The video behind the pill, blurred and a little more saturated, clipped to the pill: frosted glass.
    static func glass(behind rect: CGRect, mask: CIImage, backdrop: CIImage, height: CGFloat) -> CIImage? {
        let sigma = max(2, height * 0.3)
        let blurred = backdrop.clampedToExtent()
            .cropped(to: rect.insetBy(dx: -sigma * 3, dy: -sigma * 3))
            .applyingGaussianBlur(sigma: sigma)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
            .cropped(to: rect)
        return blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }
}
