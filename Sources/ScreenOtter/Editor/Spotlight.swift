import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// How a spotlight treats everything outside its areas: dimmed, or dimmed and softly blurred so the
/// eye goes straight to what's lit.
nonisolated enum SpotlightMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case dim, blur

    var id: Self { self }

    var title: String {
        switch self {
        case .dim: "Dim"
        case .blur: "Dim and blur"
        }
    }

    /// The other mode, for `S` pressed again with the tool already active.
    var toggled: SpotlightMode { self == .dim ? .blur : .dim }
}

/// The look of a spotlight, in image pixels. Nothing here is a setting: one tasteful dim, the same in
/// every screenshot, reads as a product shot rather than an effect.
nonisolated enum SpotlightGeometry {
    /// How dark the outside gets: the content stays legible as context, the lit areas clearly lead.
    static let dimAlpha: CGFloat = 0.56
    /// A deep, faintly cool ink rather than pure black, which looks flat and muddy over colors.
    static let dimColor = StyleColor(hex: "#07080C")!
    /// Continuous corners, generous enough to read as a deliberate frame around a card or a control.
    static let cornerPoints: CGFloat = 12
    /// The soft edge: the dim fades in over a couple of points instead of stopping at a hard line.
    /// Kept tight, so the edge reads as a clean frame rather than a glow.
    static let featherPoints: CGFloat = 1.25
    /// The blur outside the lit areas in blur mode: enough to push the context back, not to erase it.
    static let blurPoints: CGFloat = 3

    static func cornerRadius(for rect: CGRect, scale: CGFloat) -> CGFloat {
        let side = min(abs(rect.width), abs(rect.height))
        return min(cornerPoints * max(scale, 1), side * 0.3, ContinuousCorners.maxRadius(for: rect))
    }

    static func feather(scale: CGFloat) -> CGFloat {
        featherPoints * max(scale, 1)
    }

    /// The lit shape of each area. The fade is centered a little outside the drawn rect, so its edge
    /// stays bright and the dim settles just beyond it. Sides on the visible edge reach past it, so an
    /// area flush with the edge has no dimmed wedges in its corners.
    static func hole(for rect: CGRect, in visible: CGRect, scale: CGFloat) -> CGPath {
        let f = feather(scale: scale)
        let radius = cornerRadius(for: rect, scale: scale) + f / 2
        let grown = rect.standardized.insetBy(dx: -f / 2, dy: -f / 2)
        return ContinuousCorners.path(in: RedactionGeometry.clipRect(for: grown, in: visible, radius: radius), radius: radius)
    }

    /// The mode of the overlay: every spotlight shares one, set by the most recent.
    static func mode(of spotlights: [Annotation]) -> SpotlightMode {
        spotlights.last?.style.spotlight ?? .dim
    }
}

/// Draws the dim (and blur) around a document's spotlights. All of them share one overlay, so two
/// overlapping areas light their union instead of dimming each other.
///
/// The overlay is masked by a soft grayscale image: the areas cut out of a white field, blurred by the
/// feather. On the canvas it's made at screen resolution (it is smooth, so nothing is lost), for export
/// at full size. The latest mask and the blurred screenshot are kept while the editor is open.
///
/// Both layers only darken or soften pixels that are there: they are composited source-atop, so the
/// transparent margin and soft shadow of a window capture stay transparent.
final class SpotlightRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// The mask is coverage, not a picture: blurred as plain numbers, with no gamma, so the soft edge
    /// stays centered where it's drawn instead of creeping into the lit area.
    private static let maskContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    let image: CGImage
    let scale: CGFloat

    private struct MaskKey: Equatable {
        var holes: [CGRect]
        var visible: CGRect
        var resolution: CGFloat
    }

    /// What the blurred picture depends on besides the screenshot: the redactions, which are blurred in
    /// already redacted.
    private struct BlurKey: Equatable {
        struct Redaction: Equatable {
            var id: UUID
            var rect: CGRect
            var mode: RedactionMode
            var scale: CGFloat
        }

        var redactions: [Redaction]
        var visible: CGRect
    }

    private var mask: (key: MaskKey, image: CGImage)?
    private var blurred: (key: BlurKey, image: CGImage)?

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    /// The spotlights that light something in `visible`. One cropped out of view (or still a click)
    /// would leave the whole picture dimmed with nothing lit, so it is left out; with none left there
    /// is no overlay at all.
    static func shown(_ annotations: [Annotation], in visible: CGRect) -> [Annotation] {
        annotations.filter { a in
            guard a.kind == .spotlight, !a.isDegenerate else { return false }
            let inView = a.rect.intersection(visible)
            return !inView.isNull && inView.width >= 1 && inView.height >= 1
        }
    }

    /// The overlay's mask over `visible`: white where it dims, black where it's lit, at `resolution`
    /// mask pixels per image pixel.
    func mask(for rects: [CGRect], visible: CGRect, resolution: CGFloat) -> CGImage? {
        let key = MaskKey(holes: rects, visible: visible, resolution: resolution)
        if let mask, mask.key == key { return mask.image }
        let made = Self.makeMask(rects, visible: visible, resolution: resolution, scale: scale)
        mask = made.map { (key, $0) }
        return made
    }

    private static func makeMask(_ rects: [CGRect], visible: CGRect, resolution: CGFloat, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((visible.width * resolution).rounded(.up)))
        let height = max(1, Int((visible.height * resolution).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Image pixels with a top-left origin, like the rest of the editor.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: resolution, y: -resolution)
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        ctx.setFillColor(gray: 0, alpha: 1)
        for rect in rects {
            ctx.addPath(SpotlightGeometry.hole(for: rect, in: visible, scale: scale))
        }
        ctx.fillPath()
        guard let hard = ctx.makeImage() else { return nil }

        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let soft = CIImage(cgImage: hard)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: SpotlightGeometry.feather(scale: scale) * resolution)
            .cropped(to: extent)
        return maskContext.createCGImage(soft, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// The screenshot softly blurred, for blur mode, with its redactions applied first. Blurring the
    /// original instead would spread what a redaction hides past its edge: the redaction covers its own
    /// rect, not the halo around it. Remade only when a redaction (or the crop, which squares the corners
    /// of redactions on its edge) changes.
    func blurredImage(redacted: [Annotation], redactions: RedactionRenderer, visible: CGRect) -> CGImage? {
        let key = BlurKey(redactions: redacted.map { .init(id: $0.id, rect: $0.rect, mode: $0.style.redaction, scale: $0.scale) },
                          visible: visible)
        if let blurred, blurred.key == key { return blurred.image }
        let made = makeBlurred(redacted, redactions: redactions, visible: visible)
        blurred = made.map { (key, $0) }
        return made
    }

    private func makeBlurred(_ redacted: [Annotation], redactions: RedactionRenderer, visible: CGRect) -> CGImage? {
        var source = image
        if !redacted.isEmpty {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: WindowStyler.rgbColorSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(image.height))
            ctx.scaleBy(x: 1, y: -1)
            AnnotationRenderer.drawImage(image, in: ctx)
            for a in redacted {
                redactions.draw(a, visible: visible, in: ctx)
            }
            guard let composite = ctx.makeImage() else { return nil }
            source = composite
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let soft = CIImage(cgImage: source)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: SpotlightGeometry.blurPoints * max(scale, 1))
            .cropped(to: extent)
        return Self.context.createCGImage(soft, from: extent, format: .RGBA8, colorSpace: WindowStyler.rgbColorSpace(of: image))
    }

    /// Clips to the dimmed part of `visible` (soft-edged) and runs `body`, in a context whose user space
    /// is image pixels with a top-left origin.
    private func withOutside(_ spotlights: [Annotation], visible: CGRect, resolution: CGFloat, in ctx: CGContext, _ body: () -> Void) {
        guard !spotlights.isEmpty, !visible.isEmpty,
              let mask = mask(for: spotlights.map(\.rect), visible: visible, resolution: resolution)
        else { return }
        ctx.saveGState()
        // Masks draw upright in a y-up space, like images: flip around the visible rect.
        ctx.translateBy(x: visible.minX, y: visible.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(origin: .zero, size: visible.size), mask: mask)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -visible.minX, y: -visible.maxY)
        body()
        ctx.restoreGState()
    }

    /// Blur mode's first half: the blurred screenshot outside the lit areas. Drawn before the redactions
    /// and highlights, so those stay crisp on top.
    func drawBlur(
        _ spotlights: [Annotation], redacted: [Annotation], redactions: RedactionRenderer,
        visible: CGRect, resolution: CGFloat, in ctx: CGContext
    ) {
        guard !spotlights.isEmpty, SpotlightGeometry.mode(of: spotlights) == .blur,
              let blurred = blurredImage(redacted: redacted, redactions: redactions, visible: visible)
        else { return }
        withOutside(spotlights, visible: visible, resolution: resolution, in: ctx) {
            // Replaces the color of what's there and keeps its coverage: blur spills into transparent
            // margins, which must stay clear.
            ctx.setBlendMode(.sourceAtop)
            AnnotationRenderer.drawImage(blurred, in: ctx)
        }
    }

    /// The dim outside the lit areas. Annotations drawn after it stay bright, so an arrow can point
    /// into a spotlight from the dark.
    func drawDim(_ spotlights: [Annotation], visible: CGRect, resolution: CGFloat, in ctx: CGContext) {
        withOutside(spotlights, visible: visible, resolution: resolution, in: ctx) {
            // Darkens what's there in proportion to its coverage, so a transparent margin stays clear.
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(SpotlightGeometry.dimColor.withAlpha(SpotlightGeometry.dimAlpha).cgColor)
            ctx.fill(visible)
        }
    }
}
