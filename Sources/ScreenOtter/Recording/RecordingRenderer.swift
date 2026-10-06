import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Everything a frame depends on besides the video itself. Swapped as a whole when the editor changes something.
nonisolated struct RenderScene: @unchecked Sendable {
    var style: RecordingStyle
    var motion: MotionTrack
    /// The recording, in points and in video pixels.
    var pointSize: CGSize
    var sourceSize: CGSize
    var wallpaper: CGImage?
    var customBackground: CGImage?
    var frame: RecordingFrame?
    /// The webcam bubble's look, or nil when there's no bubble to draw.
    var webcam: WebcamStyle?
    /// The keystroke pill, or nil when there are no keys to show.
    var keystrokes: KeystrokeOverlay?
    /// The captions, or nil when there are none to show.
    var captions: CaptionOverlay?

    /// The recording as framed: cut at the sides, and with its title bar replaced.
    var contentSize: CGSize { frame?.size(of: sourceSize) ?? sourceSize }

    /// A point of the recording (normalized, top-left origin) in the framed recording (same units).
    func framed(_ p: CGPoint) -> CGPoint {
        guard let frame else { return p }
        let size = contentSize
        return CGPoint(
            x: (p.x * sourceSize.width - frame.left) / size.width,
            y: (p.y * sourceSize.height - frame.top + frame.bar) / size.height
        )
    }
}

/// What's cut from the recording's edges. For windows, also the minimal title bar: the app's own top bar
/// (a title bar, a toolbar, Chrome's tab strip) is cut off and a thin plain one with just the traffic lights
/// takes its place, so every window looks alike.
nonisolated struct RecordingFrame: @unchecked Sendable {
    /// Height of the drawn bar, in points.
    static let barHeight: CGFloat = 30

    /// Video pixels cut from each edge.
    var top: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0
    /// The new title bar, in video pixels (0 for none).
    var bar: CGFloat = 0
    /// Video pixels per point.
    var scale: CGFloat
    /// Matches what's right under the cut, so the bar blends into the window.
    var barColor: CGColor?
    /// Fills the window's own rounded corners, so all four follow the chosen corner radius.
    var fillColor: CGColor?

    func size(of source: CGSize) -> CGSize {
        CGSize(width: max(source.width - left - right, 2), height: max(source.height - top, 2) + bar)
    }
}

/// Draws one output frame: background, shadow, the rounded recording, pointer, clicks, then the camera on top,
/// and the webcam bubble over everything (it doesn't zoom with the picture).
/// Called by AVFoundation on its own threads, for playback and for export alike.
nonisolated final class RecordingRenderer: @unchecked Sendable {
    static let context = CIContext(options: [.cacheIntermediates: false])

    private let lock = NSLock()
    private var scene: RenderScene
    private var backdrop: (key: String, image: CIImage)?
    /// The keystroke pills for the cut last drawn.
    private var keystrokeGroups: (segments: [ClipSegment], events: [KeystrokeEvent], groups: [KeystrokeGroup])?
    /// The captions laid out on the cut last drawn.
    private var captionPieces: (segments: [ClipSegment], cues: [CaptionCue], pieces: [CaptionPiece])?

    init(scene: RenderScene) {
        self.scene = scene
    }

    func update(_ scene: RenderScene) {
        lock.withLock { self.scene = scene }
    }

    var currentScene: RenderScene {
        lock.withLock { scene }
    }

    // MARK: - Layout

    /// The output canvas at the recording's own resolution.
    static func canvasSize(style: RecordingStyle, sourceSize: CGSize) -> CGSize {
        let pad = (style.padding * max(sourceSize.width, sourceSize.height)).rounded()
        var width = sourceSize.width + pad * 2
        var height = sourceSize.height + pad * 2
        if let ratio = style.aspect.ratio {
            if width / height > ratio { height = width / ratio } else { width = height * ratio }
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// `canvas` scaled to fit `longSide`, in even pixels as video encoders want.
    static func outputSize(canvas: CGSize, longSide: CGFloat?) -> CGSize {
        let k = longSide.map { min(1, $0 / max(canvas.width, canvas.height)) } ?? 1
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * k / 2).rounded() * 2) }
        return CGSize(width: even(canvas.width), height: even(canvas.height))
    }

    /// Where the recording sits in an output of `size` (Core Image coordinates, bottom-left origin).
    static func contentRect(style: RecordingStyle, sourceSize: CGSize, outputSize size: CGSize) -> CGRect {
        let canvas = canvasSize(style: style, sourceSize: sourceSize)
        let k = min(size.width / canvas.width, size.height / canvas.height)
        let width = sourceSize.width * k
        let height = sourceSize.height * k
        return CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - height) / 2).rounded(), width: width, height: height)
    }

    // MARK: - Frame

    /// `timeline` is the cut of the video being drawn, which may lag behind the latest edits for a moment:
    /// the pointer and camera must follow the frames actually on screen.
    func render(source: CIImage, webcam: CIImage? = nil, outputTime: Double, timeline: ClipTimeline, renderSize: CGSize) -> CIImage {
        let scene = currentScene
        let style = scene.style
        let t = timeline.sourceTime(atOutput: outputTime)
        let rect = Self.contentRect(style: style, sourceSize: scene.contentSize, outputSize: renderSize)
        /// Output pixels per recording point.
        let unit = rect.width / max(scene.pointSize.width, 1)
        let camera = scene.motion.camera(at: t)
        /// A point of the recording (normalized, top-left origin) on the output.
        let place = { (p: CGPoint) -> CGPoint in
            let q = scene.framed(p)
            return CGPoint(x: rect.minX + q.x * rect.width, y: rect.maxY - q.y * rect.height)
        }

        var image = backdrop(for: scene, rect: rect, size: renderSize)
        let framed = Self.framedSource(source, frame: scene.frame)
        image = recording(framed, in: rect, radius: style.cornerRadius * unit, zoom: camera.scale).composited(over: image)
        if style.showCursor {
            if style.clickEffect {
                for ripple in ripples(scene: scene, at: t, unit: unit, place: place) {
                    image = ripple.composited(over: image)
                }
            }
            if let pointer = pointer(scene: scene, at: t, unit: unit, place: place) {
                image = pointer.composited(over: image)
            }
        }
        // The camera works in the framed recording already.
        let focus = CGPoint(x: rect.minX + camera.x * rect.width, y: rect.maxY - camera.y * rect.height)
        image = applyCamera(camera, focus: focus, to: image, size: renderSize)
        if let webcam, let style = scene.webcam,
           let bubble = WebcamArt.bubble(camera: webcam, style: style, canvas: renderSize, zoomScale: camera.scale) {
            image = bubble.composited(over: image).cropped(to: CGRect(origin: .zero, size: renderSize))
        }
        let content = CGRect(x: rect.minX, y: renderSize.height - rect.maxY, width: rect.width, height: rect.height)
        var captionHeight: CGFloat = 0
        if let overlay = scene.captions,
           let shown = CaptionPresentation.at(outputTime, source: t, pieces: captionPieces(overlay, timeline: timeline)),
           let caption = CaptionArt.overlay(shown, style: overlay.style, backdrop: image, canvas: renderSize, content: content) {
            image = caption.image.composited(over: image).cropped(to: CGRect(origin: .zero, size: renderSize))
            captionHeight = caption.frame.height * CGFloat(shown.opacity)
        }
        if let overlay = scene.keystrokes,
           let pill = KeystrokeArt.overlay(
               groups: keystrokeGroups(overlay, timeline: timeline), style: overlay.style, at: outputTime,
               backdrop: image, canvas: renderSize, content: content,
               // On the same edge as a caption, the pill steps back to sit beside it rather than over it.
               lift: overlay.style.position == scene.captions?.style.position && captionHeight > 0
                   ? captionHeight + KeystrokeLayout.height(overlay.style, canvas: renderSize) * 0.3 : 0
           ) {
            image = pill.composited(over: image).cropped(to: CGRect(origin: .zero, size: renderSize))
        }
        return image
    }

    /// The captions follow the cut being drawn, so they're laid out again only when it or they change.
    private func captionPieces(_ overlay: CaptionOverlay, timeline: ClipTimeline) -> [CaptionPiece] {
        if let cached = lock.withLock({ captionPieces }), cached.segments == timeline.segments, cached.cues == overlay.cues {
            return cached.pieces
        }
        let pieces = CaptionTimeline.pieces(overlay.cues, timeline: timeline)
        lock.withLock { captionPieces = (timeline.segments, overlay.cues, pieces) }
        return pieces
    }

    /// The pills follow the cut being drawn, so they're regrouped only when it changes.
    private func keystrokeGroups(_ overlay: KeystrokeOverlay, timeline: ClipTimeline) -> [KeystrokeGroup] {
        if let cached = lock.withLock({ keystrokeGroups }), cached.segments == timeline.segments, cached.events == overlay.events {
            return cached.groups
        }
        let groups = KeystrokeTimeline.groups(overlay.events, timeline: timeline)
        lock.withLock { keystrokeGroups = (timeline.segments, overlay.events, groups) }
        return groups
    }

    /// The video frame cut at its edges and with its title bar replaced, when framed; origin at zero either way.
    private static func framedSource(_ source: CIImage, frame: RecordingFrame?) -> CIImage {
        let extent = source.extent
        let image = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard let frame else { return image }
        // Core Image's origin is at the bottom, so the top of the window is the end of the kept range.
        let size = frame.size(of: extent.size)
        let kept = CGRect(x: frame.left, y: 0, width: size.width, height: size.height - frame.bar)
        var framed = image.cropped(to: kept).transformed(by: CGAffineTransform(translationX: -frame.left, y: 0))
        let area = CGRect(x: 0, y: 0, width: kept.width, height: kept.height)
        if let fill = frame.fillColor {
            framed = framed.composited(over: CIImage(color: CIColor(cgColor: fill)).cropped(to: area))
        }
        if frame.bar > 0, let bar = WindowChromeArt.bar(width: Int(size.width), frame: frame) {
            framed = CIImage(cgImage: bar)
                .transformed(by: CGAffineTransform(translationX: 0, y: kept.height))
                .composited(over: framed)
        }
        return framed
    }

    /// The recording scaled into place and clipped to its rounded corners. When it ends up smaller than
    /// the source, it is downsampled with Lanczos first so small text doesn't shimmer.
    private func recording(_ source: CIImage, in rect: CGRect, radius: CGFloat, zoom: Double) -> CIImage {
        let extent = source.extent
        let fitX = rect.width / extent.width
        let fitY = rect.height / extent.height
        var image = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        var placed: CGAffineTransform
        if fitY * zoom < 0.98 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = image
            lanczos.scale = Float(fitY * zoom)
            lanczos.aspectRatio = Float(fitX / fitY)
            image = lanczos.outputImage ?? image
            placed = CGAffineTransform(scaleX: 1 / zoom, y: 1 / zoom)
        } else {
            placed = CGAffineTransform(scaleX: fitX, y: fitY)
        }
        placed = placed.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        image = image.transformed(by: placed)

        guard radius > 0.5 else { return image.cropped(to: rect) }
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = rect
        mask.radius = Float(min(radius, rect.width / 2, rect.height / 2))
        mask.color = .white
        guard let maskImage = mask.outputImage else { return image.cropped(to: rect) }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: maskImage,
        ])
    }

    private func pointer(scene: RenderScene, at t: Double, unit: CGFloat, place: (CGPoint) -> CGPoint) -> CIImage? {
        let style = scene.style
        let state = scene.motion.cursor(at: t)
        guard state.opacity > 0.01 else { return nil }

        // A short squeeze on every click.
        var press = 1.0
        if let click = scene.motion.clicks.last(where: { $0.t <= t }), t - click.t < 0.24 {
            press = 1 - 0.16 * sin(.pi * (t - click.t) / 0.24)
        }
        let height = CursorArt.baseHeight * style.cursorSize * unit * press
        guard height >= 2, let art = CursorArt.image(style.cursorStyle, height: height) else { return nil }

        let tip = place(state.point)
        let artScale = height / CGFloat(art.image.height)
        var image = CIImage(cgImage: art.image)
            .transformed(by: CGAffineTransform(scaleX: artScale, y: artScale))
        let hotspot = CGPoint(x: art.hotspot.x * artScale, y: CGFloat(art.image.height) * artScale - art.hotspot.y * artScale)
        image = image.transformed(by: CGAffineTransform(translationX: tip.x - hotspot.x, y: tip.y - hotspot.y))

        if style.cursorMotionBlur {
            // Output pixels per second, from a step along the velocity.
            let ahead = place(CGPoint(x: state.point.x + state.velocity.dx / 60, y: state.point.y + state.velocity.dy / 60))
            let vx = (ahead.x - tip.x) * 60
            let vy = (ahead.y - tip.y) * 60
            // Roughly the distance travelled while a frame is exposed.
            let radius = min(hypot(vx, vy) / 60 * 0.3, height)
            if radius > 2.5 {
                let blur = CIFilter.motionBlur()
                blur.inputImage = image
                blur.radius = Float(radius)
                blur.angle = Float(atan2(vy, vx))
                image = blur.outputImage ?? image
            }
        }
        if state.opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity)])
        }
        return image
    }

    private func ripples(scene: RenderScene, at t: Double, unit: CGFloat, place: (CGPoint) -> CGPoint) -> [CIImage] {
        let duration = 0.55
        return scene.motion.clicks.compactMap { click in
            let age = t - click.t
            guard age >= 0, age < duration, let ring = CursorArt.ring else { return nil }
            let p = age / duration
            let eased = 1 - pow(1 - p, 3)
            let radius = (6 + 20 * eased) * unit * max(scene.style.cursorSize, 0.8) * 0.75
            let alpha = 0.55 * (1 - p)
            let c = place(scene.motion.cursor(at: click.t).point)
            let k = radius * 2 / CGFloat(ring.width)
            return CIImage(cgImage: ring)
                .transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: c.x - radius, y: c.y - radius)))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
        }
    }

    /// Zooms the whole picture into a view centered on `focus`. The motion track already keeps the view
    /// inside the recording; this only guards against showing past the edge of the canvas.
    private func applyCamera(_ camera: CameraState, focus: CGPoint, to image: CIImage, size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        guard camera.scale > 1.001 else { return image.cropped(to: bounds) }
        let s = camera.scale
        let view = CGSize(width: size.width / s, height: size.height / s)
        let x = min(max(focus.x - view.width / 2, 0), size.width - view.width)
        let y = min(max(focus.y - view.height / 2, 0), size.height - view.height)
        let transform = CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(scaleX: s, y: s))
        return image.transformed(by: transform).cropped(to: bounds)
    }

    // MARK: - Backdrop

    /// Background and shadow only change with the style, so they're rendered once into a bitmap.
    private func backdrop(for scene: RenderScene, rect: CGRect, size: CGSize) -> CIImage {
        let style = scene.style
        let key = [
            "\(style.background)", "\(style.backgroundBlur)", "\(style.shadow)", "\(style.cornerRadius)", "\(scene.pointSize)",
            "\(rect)", "\(size)",
            scene.wallpaper.map { "\(ObjectIdentifier($0))" } ?? "-",
            scene.customBackground.map { "\(ObjectIdentifier($0))" } ?? "-",
        ].joined(separator: "|")
        if let cached = lock.withLock({ backdrop }), cached.key == key { return cached.image }

        let bounds = CGRect(origin: .zero, size: size)
        var image = Self.background(scene: scene, size: size)
        if style.shadow > 0.01 {
            let unit = rect.width / max(scene.pointSize.width, 1)
            let radius = min(style.cornerRadius * unit, rect.width / 2, rect.height / 2)
            // A wide, soft shadow for depth plus a tight one that defines the edge.
            let ambient = (18 + 50 * style.shadow) * unit
            image = Self.shadow(rect: rect, radius: radius, blur: ambient, opacity: 0.16 + 0.34 * style.shadow, offset: ambient * 0.28)
                .composited(over: image)
            image = Self.shadow(rect: rect, radius: radius, blur: 2.5 * unit, opacity: 0.12 + 0.2 * style.shadow, offset: 0.8 * unit)
                .composited(over: image)
        }
        let flat = Self.context.createCGImage(image.cropped(to: bounds), from: bounds).map { CIImage(cgImage: $0) } ?? image
        lock.withLock { backdrop = (key, flat) }
        return flat
    }

    /// A rounded rectangle's shadow, faded out smoothly on every side.
    private static func shadow(rect: CGRect, radius: CGFloat, blur: CGFloat, opacity: Double, offset: CGFloat) -> CIImage {
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = rect
        shape.radius = Float(radius)
        shape.color = CIColor(red: 0, green: 0, blue: 0, alpha: opacity)
        let area = rect.insetBy(dx: -blur * 3, dy: -blur * 3)
        // Blurred over transparent space: the shape's own extent ends at its edges.
        let padded = (shape.outputImage ?? CIImage.empty()).composited(over: CIImage(color: .clear).cropped(to: area))
        return padded.applyingGaussianBlur(sigma: blur / 2)
            .cropped(to: area)
            .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
    }

    static func background(scene: RenderScene, size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let style = scene.style
        var picture: CGImage?
        switch style.background {
        case .wallpaper: picture = scene.wallpaper
        case .image: picture = scene.customBackground
        case let .gradient(index):
            if let gradient = BackgroundArt.gradient(index, size: size) { return CIImage(cgImage: gradient) }
        case let .color(index):
            return CIImage(color: CIColor(cgColor: BackgroundArt.color(index))).cropped(to: bounds)
        }
        guard let picture else {
            return BackgroundArt.gradient(0, size: size).map { CIImage(cgImage: $0) } ?? CIImage(color: .black).cropped(to: bounds)
        }
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let k = max(size.width / w, size.height / h)
        var image = CIImage(cgImage: picture).transformed(by: CGAffineTransform(scaleX: k, y: k)
            .concatenating(CGAffineTransform(translationX: (size.width - w * k) / 2, y: (size.height - h * k) / 2)))
        if style.backgroundBlur > 0.01 {
            image = image.clampedToExtent().applyingGaussianBlur(sigma: style.backgroundBlur * max(size.width, size.height) * 0.02)
        }
        return image.cropped(to: bounds)
    }
}

// MARK: - Artwork

/// The pointer, drawn as vectors so it stays sharp at any size and zoom.
nonisolated enum CursorArt {
    /// Height of the arrow at size 1, in points (like the system pointer).
    static let baseHeight: CGFloat = 22

    struct Art: @unchecked Sendable {
        let image: CGImage
        /// From the image's top-left corner, in its pixels.
        let hotspot: CGPoint
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Art] = [:]

    static func image(_ style: CursorStyle, height: CGFloat) -> Art? {
        // Drawn at a bucketed size a little larger than needed, then scaled down.
        let bucket = max(8, Int((height / 8).rounded(.up)) * 8)
        let key = "\(style.rawValue)-\(bucket)"
        if let cached = lock.withLock({ cache[key] }) { return cached }
        guard let art = draw(style, height: CGFloat(bucket)) else { return nil }
        lock.withLock { cache[key] = art }
        return art
    }

    private static func draw(_ style: CursorStyle, height: CGFloat) -> Art? {
        let k = height / baseHeight
        let margin = (3 * k).rounded(.up)
        let isDot = style == .dot
        let shapeSize = isDot ? CGSize(width: 14 * k, height: 14 * k) : CGSize(width: 15 * k, height: 22 * k)
        let width = Int((shapeSize.width + margin * 2).rounded(.up))
        let pixelHeight = Int((shapeSize.height + margin * 2).rounded(.up))
        guard let ctx = CGContext(
            data: nil, width: width, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Top-left origin, like the shape coordinates below.
        ctx.translateBy(x: margin, y: CGFloat(pixelHeight) - margin)
        ctx.scaleBy(x: k, y: -k)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * k), blur: 2.2 * k, color: CGColor(gray: 0, alpha: 0.35))

        if isDot {
            let circle = CGRect(x: 0.5, y: 0.5, width: 13, height: 13)
            ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.55))
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: circle)
            guard let image = ctx.makeImage() else { return nil }
            return Art(image: image, hotspot: CGPoint(x: margin + 7 * k, y: margin + 7 * k))
        }

        // The classic macOS arrow, tip at the origin.
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 0, y: 0))
        arrow.addLine(to: CGPoint(x: 0, y: 16.6))
        arrow.addLine(to: CGPoint(x: 3.9, y: 12.9))
        arrow.addLine(to: CGPoint(x: 6.5, y: 19.1))
        arrow.addLine(to: CGPoint(x: 9.3, y: 17.9))
        arrow.addLine(to: CGPoint(x: 6.7, y: 11.8))
        arrow.addLine(to: CGPoint(x: 12.1, y: 11.8))
        arrow.closeSubpath()

        let fill = style == .whiteArrow ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
        let outline = style == .whiteArrow ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(2.4)
        ctx.addPath(arrow)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(fill)
        ctx.addPath(arrow)
        ctx.fillPath()
        guard let image = ctx.makeImage() else { return nil }
        return Art(image: image, hotspot: CGPoint(x: margin, y: margin))
    }

    /// A translucent disc with a white rim and a faint dark edge, for click ripples: visible on light and dark content.
    static let ring: CGImage? = {
        let size = 160
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 10, y: 10, width: size - 20, height: size - 20)
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.28))
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.3))
        ctx.setLineWidth(10)
        ctx.strokeEllipse(in: rect)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: rect)
        return ctx.makeImage()
    }()
}

nonisolated enum WindowChromeArt {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    private static let lights: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.373, blue: 0.341, alpha: 1),
        CGColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
        CGColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1),
    ]

    /// The plain bar: the sampled color with three traffic lights on the left.
    static func bar(width: Int, frame: RecordingFrame) -> CGImage? {
        let height = max(1, Int(frame.bar.rounded()))
        let color = frame.barColor ?? CGColor(gray: 0.93, alpha: 1)
        let key = "\(width)x\(height)@\(frame.scale)-\(color.components ?? [])"
        if let cached = lock.withLock({ cache[key] }) { return cached }
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let k = frame.scale
        let diameter = 12.5 * k
        let centerY = CGFloat(height) / 2
        ctx.setLineWidth(0.5 * k)
        for (i, color) in lights.enumerated() {
            let center = CGPoint(x: (19 + CGFloat(i) * 20) * k, y: centerY)
            let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.14))
            ctx.strokeEllipse(in: circle.insetBy(dx: 0.25 * k, dy: 0.25 * k))
        }
        guard let image = ctx.makeImage() else { return nil }
        lock.withLock {
            if cache.count > 16 { cache.removeAll() }
            cache[key] = image
        }
        return image
    }

    /// The most common color along one row of `image` (rows counted from the top), ignoring the edges.
    /// The most common rather than the average, so icons and text in a toolbar don't tint the result.
    static func dominantColor(of image: CGImage, row: Int) -> CGColor? {
        let y = min(max(row, 0), image.height - 1)
        let x = image.width / 6
        let width = max(1, image.width - x * 2)
        guard let strip = image.cropping(to: CGRect(x: x, y: y, width: width, height: 1)),
              let ctx = CGContext(
                  data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = ctx.data
        else { return nil }
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: 1))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * 4)

        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<width {
            let r = Int(bytes[i * 4]), g = Int(bytes[i * 4 + 1]), b = Int(bytes[i * 4 + 2]), a = Int(bytes[i * 4 + 3])
            guard a > 200 else { continue }
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            let bin = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (bin.count + 1, bin.r + r, bin.g + g, bin.b + b)
        }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return nil }
        let n = CGFloat(top.count) * 255
        return CGColor(srgbRed: CGFloat(top.r) / n, green: CGFloat(top.g) / n, blue: CGFloat(top.b) / n, alpha: 1)
    }
}

nonisolated enum BackgroundArt {
    /// Three colors each: a diagonal blend with two soft glows on top.
    static let gradients: [[UInt32]] = [
        [0x1E1B4B, 0x4338CA, 0xA855F7],
        [0xF97316, 0xEC4899, 0x7C3AED],
        [0x0EA5E9, 0x2563EB, 0x1E3A8A],
        [0x6EE7B7, 0x10B981, 0x0F766E],
        [0xFDBA74, 0xFB7185, 0xC084FC],
        [0x52525B, 0x27272A, 0x09090B],
        [0x22D3EE, 0x818CF8, 0xF472B6],
        [0xFEF3C7, 0xFBCFE8, 0xC4B5FD],
    ]

    static let colors: [UInt32] = [0xF5F5F7, 0xD4D4D8, 0x18181B, 0x2563EB, 0x7C3AED, 0xF97316]

    static func color(_ index: Int) -> CGColor {
        cgColor(colors[min(max(index, 0), colors.count - 1)])
    }

    static func gradient(_ index: Int, size: CGSize) -> CGImage? {
        let palette = gradients[min(max(index, 0), gradients.count - 1)].map(cgColor)
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let linear = CGGradient(colorsSpace: space, colors: palette as CFArray, locations: [0, 0.55, 1])
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.drawLinearGradient(linear, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        let reach = max(w, h)
        for (color, center, radius) in [
            (palette[2], CGPoint(x: w * 0.82, y: h * 0.86), reach * 0.75),
            (palette[0], CGPoint(x: w * 0.12, y: h * 0.1), reach * 0.65),
        ] {
            let glow = CGGradient(colorsSpace: space, colors: [color.copy(alpha: 0.7)!, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        return ctx.makeImage()
    }

    private static func cgColor(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
