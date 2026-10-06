import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Draws the webcam bubble for the renderer: the camera frame cut to its shape, with a soft shadow under
/// it and a fine ring around it. The mask, ring and shadow are drawn once per shape and size with Core
/// Graphics (anti-aliased vector edges) and reused for every frame; the zoom response only scales them.
nonisolated enum WebcamArt {
    struct Art: @unchecked Sendable {
        /// White where the camera shows, at the bubble's pixel size.
        let mask: CGImage
        let ring: CGImage?
        /// Larger than the bubble by `shadowPadding` on every side.
        let shadow: CGImage?
        let shadowPadding: CGFloat
    }

    // The look, shared with the live bubble shown while recording so the two never drift apart.

    /// The ring is white at this opacity.
    static let ringAlpha: CGFloat = 0.82

    /// How wide the ring shows inside the edge of a bubble `height` tall.
    static func ringWidth(forHeight height: CGFloat) -> CGFloat {
        max(1.5, height * 0.014)
    }

    /// A wide ambient shadow for lift plus a tight one that seats the edge, for a bubble `height` tall.
    static func shadows(forHeight height: CGFloat) -> [(blur: CGFloat, offset: CGFloat, alpha: CGFloat)] {
        [(height * 0.14, height * 0.05, 0.42), (height * 0.02, height * 0.008, 0.26)]
    }

    /// Room the shadow needs around a bubble `height` tall.
    static func shadowPadding(forHeight height: CGFloat) -> CGFloat {
        (height * 0.22).rounded(.up)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Art] = [:]

    /// The bubble over an output of `canvas` size (Core Image coordinates), or nil when it's hidden.
    static func bubble(camera: CIImage, style: WebcamStyle, canvas: CGSize, zoomScale: Double) -> CIImage? {
        let (frame, opacity) = WebcamLayout.presentation(style, canvas: canvas, zoomScale: zoomScale)
        guard opacity > 0.01, frame.width >= 4, frame.height >= 4 else { return nil }
        let rest = WebcamLayout.frame(style, canvas: canvas)
        let size = rest.size
        guard let art = art(shape: style.shape, size: size, border: style.border, shadow: style.shadow) else { return nil }

        var image = fitted(camera, into: size, mirror: style.mirror)
        image = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: CIImage(cgImage: art.mask),
        ])
        if let ring = art.ring {
            image = CIImage(cgImage: ring).composited(over: image)
        }
        if let shadow = art.shadow {
            let pad = art.shadowPadding
            image = image.composited(over: CIImage(cgImage: shadow).transformed(by: CGAffineTransform(translationX: -pad, y: -pad)))
        }

        // Into place: Core Image counts from the bottom.
        let k = frame.width / size.width
        image = image.transformed(by: CGAffineTransform(scaleX: k, y: k)
            .concatenating(CGAffineTransform(translationX: frame.minX, y: canvas.height - frame.maxY)))
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        }
        return image
    }

    /// The camera frame filling `size` (centered, cropped), mirrored if asked, with its origin at zero.
    /// Downscaled with Lanczos so a 720p camera stays crisp in a small bubble.
    static func fitted(_ camera: CIImage, into size: CGSize, mirror: Bool) -> CIImage {
        let extent = camera.extent
        var image = camera.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if mirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: extent.width, y: 0)))
        }
        let fill = WebcamLayout.fill(source: extent.size, into: size)
        if fill.scale < 0.8 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = image
            lanczos.scale = Float(fill.scale)
            lanczos.aspectRatio = 1
            image = lanczos.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: fill.scale, y: fill.scale))
        } else {
            image = image.transformed(by: CGAffineTransform(scaleX: fill.scale, y: fill.scale))
        }
        // Clamped first, so the edge pixels don't fade into the mask's anti-aliasing.
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -fill.crop.minX, y: -fill.crop.minY))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    static func art(shape: WebcamShape, size: CGSize, border: Bool, shadow: Bool) -> Art? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width >= 2, height >= 2 else { return nil }
        let key = "\(shape.rawValue)-\(width)x\(height)-\(border)-\(shadow)"
        if let cached = lock.withLock({ cache[key] }) { return cached }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Core Graphics counts from the bottom too, but the shapes are drawn top-left: flip the path once.
        var flip = CGAffineTransform(translationX: 0, y: CGFloat(height)).scaledBy(x: 1, y: -1)
        guard let path = shape.path(in: rect).copy(using: &flip) else { return nil }

        guard let mask = draw(width: width, height: height, { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()
        }) else { return nil }

        var ring: CGImage?
        if border {
            // A fine light ring just inside the edge: it reads as glass on dark content and as a crisp edge
            // on light content, without the heaviness of a thick frame.
            let line = ringWidth(forHeight: CGFloat(height))
            ring = draw(width: width, height: height) { ctx in
                ctx.addPath(path)
                ctx.clip()
                ctx.addPath(path)
                ctx.setLineWidth(line * 2)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: ringAlpha))
                ctx.strokePath()
            }
        }

        var shadowImage: CGImage?
        let h = CGFloat(height)
        let pad = shadowPadding(forHeight: h)
        if shadow {
            shadowImage = draw(width: width + Int(pad) * 2, height: height + Int(pad) * 2) { ctx in
                var move = CGAffineTransform(translationX: pad, y: pad)
                guard let shifted = path.copy(using: &move) else { return }
                for (blur, offset, alpha) in shadows(forHeight: h) {
                    ctx.saveGState()
                    ctx.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur, color: CGColor(gray: 0, alpha: alpha))
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                    ctx.addPath(shifted)
                    ctx.fillPath()
                    ctx.restoreGState()
                }
                // Only the shadow stays: the shape itself is cut out, so nothing darkens the bubble's
                // anti-aliased edge from below.
                ctx.setBlendMode(.clear)
                ctx.addPath(shifted)
                ctx.fillPath()
            }
        }

        let art = Art(mask: mask, ring: ring, shadow: shadowImage, shadowPadding: pad)
        lock.withLock {
            if cache.count > 24 { cache.removeAll() }
            cache[key] = art
        }
        return art
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        body(ctx)
        return ctx.makeImage()
    }
}
