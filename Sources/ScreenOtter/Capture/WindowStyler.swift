import CoreGraphics

/// Puts a captured window on its desktop wallpaper: rounded corners, soft shadow, padding.
enum WindowStyler {
    struct Style {
        var padding: CGFloat
        var cornerRadius: CGFloat
        var shadow: Bool
        var background: WindowBackground
    }

    /// - Parameters:
    ///   - frameInDisplay: window frame in points, display-local, top-left origin.
    ///   - wallpaper: the display's wallpaper at `scale`, or nil.
    static func compose(
        window: CGImage,
        frameInDisplay: CGRect,
        scale: CGFloat,
        wallpaper: CGImage?,
        displaySize: CGSize,
        style: Style
    ) -> CGImage? {
        let padding = (style.padding * scale).rounded()
        let windowSize = CGSize(width: window.width, height: window.height)
        let width = Int(windowSize.width + padding * 2)
        let height = Int(windowSize.height + padding * 2)
        let colorSpace = rgbColorSpace(of: window)

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        if style.background == .wallpaper, let wallpaper {
            drawWallpaper(wallpaper, in: ctx, canvas: canvas, frameInDisplay: frameInDisplay,
                          paddingPoints: style.padding, displaySize: displaySize)
        }

        let rounded = roundedImage(window, radius: style.cornerRadius * scale, colorSpace: colorSpace) ?? window
        let windowRect = CGRect(x: padding, y: padding, width: windowSize.width, height: windowSize.height)
        if style.shadow {
            // Very subtle: a soft, low drop plus a faint tight contact shadow for edge definition.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 22 * scale, color: CGColor(gray: 0, alpha: 0.22))
            ctx.draw(rounded, in: windowRect)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * scale), blur: 2 * scale, color: CGColor(gray: 0, alpha: 0.18))
            ctx.draw(rounded, in: windowRect)
            ctx.restoreGState()
        } else {
            ctx.draw(rounded, in: windowRect)
        }

        return ctx.makeImage()
    }

    /// Uses the patch of wallpaper that was actually behind the window, so it looks like the real desktop.
    private static func drawWallpaper(
        _ wallpaper: CGImage,
        in ctx: CGContext,
        canvas: CGRect,
        frameInDisplay: CGRect,
        paddingPoints: CGFloat,
        displaySize: CGSize
    ) {
        var region = frameInDisplay.insetBy(dx: -paddingPoints, dy: -paddingPoints)
        if region.width <= displaySize.width, region.height <= displaySize.height, displaySize.width > 0 {
            region.origin.x = min(max(region.minX, 0), displaySize.width - region.width)
            region.origin.y = min(max(region.minY, 0), displaySize.height - region.height)
            let k = CGFloat(wallpaper.width) / displaySize.width
            let pixelRect = CGRect(x: region.minX * k, y: region.minY * k, width: region.width * k, height: region.height * k).integral
            if let crop = wallpaper.cropping(to: pixelRect) {
                ctx.draw(crop, in: canvas)
                return
            }
        }
        // Window is (nearly) as big as the screen: aspect-fill the whole wallpaper.
        ctx.draw(wallpaper, in: aspectFillRect(for: CGSize(width: wallpaper.width, height: wallpaper.height), in: canvas))
    }

    private static func roundedImage(_ image: CGImage, radius: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        guard radius > 0,
              let ctx = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = min(radius, rect.width / 2, rect.height / 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    static func aspectFill(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: rgbColorSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        let canvas = CGRect(origin: .zero, size: size)
        ctx.draw(image, in: aspectFillRect(for: CGSize(width: image.width, height: image.height), in: canvas))
        return ctx.makeImage()
    }

    private static func aspectFillRect(for size: CGSize, in canvas: CGRect) -> CGRect {
        let k = max(canvas.width / size.width, canvas.height / size.height)
        let w = size.width * k
        let h = size.height * k
        return CGRect(x: canvas.midX - w / 2, y: canvas.midY - h / 2, width: w, height: h)
    }

    static func rgbColorSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
