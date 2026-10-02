import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// How a redaction hides what's under it. Both are equally strong: they sample the same coarse grid
/// and only differ in how it is drawn back.
nonisolated enum RedactionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case blur, pixelate

    var id: Self { self }

    var title: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        }
    }

    /// The other mode, for `B` pressed again with the tool already active.
    var toggled: RedactionMode { self == .blur ? .pixelate : .blur }
}

/// The sizing of a redaction, in image pixels. Nothing here is a user setting: the grid scales with the
/// region, so a box drawn around a line of text always swallows whole letters.
nonisolated enum RedactionGeometry {
    /// The smallest block, in points: a little more than the cap height of UI text, so no block holds
    /// less than a letter and the shapes of letters can't be matched back.
    static let minimumBlockPoints: CGFloat = 12
    /// The largest block, in points, so a big region stays a fine wash instead of a few giant tiles.
    static let maximumBlockPoints: CGFloat = 28
    /// Soft continuous corners, kept small: the region should read as a pane, not a pill.
    static let cornerPoints: CGFloat = 5

    /// The side of a sampling block. A region is usually drawn snugly around what it hides, so its
    /// short side stands in for the text size: half of it, within the limits above.
    static func blockSize(for rect: CGRect, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        let side = min(abs(rect.width), abs(rect.height))
        return min(max(side / 2, minimumBlockPoints * s), maximumBlockPoints * s)
    }

    /// Columns and rows of whole blocks that fill the rect exactly. Rounding down keeps every block at
    /// least `blockSize`, and fitting the grid to the rect leaves no thin slivers along its edges.
    static func grid(for rect: CGRect, scale: CGFloat) -> (columns: Int, rows: Int) {
        let block = blockSize(for: rect, scale: scale)
        return (max(1, Int((abs(rect.width) / block).rounded(.down))), max(1, Int((abs(rect.height) / block).rounded(.down))))
    }

    /// The blur drawn over the grid. About half a block melts the grid into a smooth wash without
    /// smearing the region's colors into a single gray.
    static func blurSigma(for rect: CGRect, scale: CGFloat) -> CGFloat {
        blockSize(for: rect, scale: scale) * 0.55
    }

    static func cornerRadius(for rect: CGRect, scale: CGFloat) -> CGFloat {
        let side = min(abs(rect.width), abs(rect.height))
        return min(cornerPoints * max(scale, 1), side * 0.2, ContinuousCorners.maxRadius(for: rect))
    }

    /// The rect whose rounded outline clips a redaction. Sides that reach the image's edge are pushed
    /// past it, so the corners there fall outside the image and stay square: a region flush with the
    /// edge covers it completely instead of leaving small unredacted wedges in its corners.
    static func clipRect(for rect: CGRect, in imageBounds: CGRect, radius: CGFloat) -> CGRect {
        let r = rect.standardized
        let overhang = radius * ContinuousCorners.extent + 1
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if minX <= imageBounds.minX + 0.5 { minX = min(minX, imageBounds.minX) - overhang }
        if maxX >= imageBounds.maxX - 0.5 { maxX = max(maxX, imageBounds.maxX) + overhang }
        if minY <= imageBounds.minY + 0.5 { minY = min(minY, imageBounds.minY) - overhang }
        if maxY >= imageBounds.maxY - 0.5 { maxY = max(maxY, imageBounds.maxY) + overhang }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The pixels a redaction samples and covers: its rect grown to whole pixels, inside the image.
    static func area(of rect: CGRect, in imageBounds: CGRect) -> CGRect {
        rect.standardized.integral.intersection(imageBounds)
    }
}

/// Turns a region of the original screenshot into its redacted pixels.
///
/// Both modes first shrink the region to a grid of a few large blocks (Lanczos, which averages each
/// block's pixels). That is what makes them irreversible: everything finer than a block is gone from
/// the data, not just hidden. Pixelate draws the grid back as hard tiles, blur upsamples it smoothly and
/// softens it. The source is clamped to the region's own pixels so the edges neither darken (from
/// sampling transparent pixels outside) nor pull in what lies next to the region.
final class RedactionRenderer {
    struct Output {
        /// For pixelate the grid itself (one pixel per block), for blur the region at full size.
        let image: CGImage
        /// Where it goes, in image pixels with a top-left origin.
        let area: CGRect
        let mode: RedactionMode
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The original screenshot, which every redaction samples.
    let image: CGImage

    /// The last result for each redaction, so redrawing the canvas doesn't redo the filters for regions
    /// that didn't change. One entry per redaction, replaced when its rect or mode changes, so dragging a
    /// region out keeps a single entry; and owned by one document, so it goes away with the editor.
    private struct Entry {
        let rect: CGRect
        let mode: RedactionMode
        let scale: CGFloat
        let output: Output
    }

    private var entries: [UUID: Entry] = [:]

    init(image: CGImage) {
        self.image = image
    }

    func output(for a: Annotation) -> Output? {
        let rect = a.rect, mode = a.style.redaction
        if let entry = entries[a.id], entry.rect == rect, entry.mode == mode, entry.scale == a.scale {
            return entry.output
        }
        let output = Self.render(rect, of: image, mode: mode, scale: a.scale)
        entries[a.id] = output.map { Entry(rect: rect, mode: mode, scale: a.scale, output: $0) }
        return output
    }

    /// Drops the results of redactions that are gone (deleted, undone, or a draft that was discarded).
    func keepOnly(_ ids: Set<UUID>) {
        if entries.keys.contains(where: { !ids.contains($0) }) {
            entries = entries.filter { ids.contains($0.key) }
        }
    }

    var cachedCount: Int { entries.count }

    private static func render(_ rect: CGRect, of image: CGImage, mode: RedactionMode, scale: CGFloat) -> Output? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = RedactionGeometry.area(of: rect, in: bounds)
        guard area.width >= 1, area.height >= 1 else { return nil }
        let (columns, rows) = RedactionGeometry.grid(for: area, scale: scale)
        let colorSpace = WindowStyler.rgbColorSpace(of: image)

        // Core Image is y-up: flip the region, then move it to the origin.
        let flipped = CGRect(x: area.minX, y: bounds.height - area.maxY, width: area.width, height: area.height)
        let source = CIImage(cgImage: image)
            .cropped(to: flipped)
            .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
            .clampedToExtent()

        let shrink = CIFilter.lanczosScaleTransform()
        shrink.inputImage = source
        let sy = CGFloat(rows) / area.height
        let sx = CGFloat(columns) / area.width
        shrink.scale = Float(sy)
        shrink.aspectRatio = Float(sx / sy)
        guard let shrunk = shrink.outputImage else { return nil }
        let grid = shrunk.cropped(to: CGRect(x: 0, y: 0, width: columns, height: rows))

        switch mode {
        case .pixelate:
            guard let tiles = context.createCGImage(grid, from: grid.extent, format: .RGBA8, colorSpace: colorSpace) else { return nil }
            return Output(image: tiles, area: area, mode: mode)
        case .blur:
            let size = CGRect(origin: .zero, size: area.size)
            let wash = grid
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 1 / sx, y: 1 / sy))
                .applyingGaussianBlur(sigma: RedactionGeometry.blurSigma(for: area, scale: scale))
                .cropped(to: size)
            guard let smooth = context.createCGImage(wash, from: size, format: .RGBA8, colorSpace: colorSpace) else { return nil }
            return Output(image: smooth, area: area, mode: mode)
        }
    }
}

extension RedactionRenderer {
    /// Draws a redaction from the original screenshot's pixels, never from annotations drawn on top,
    /// clipped to soft continuous corners.
    /// - Parameter visible: the part of the image being drawn (the crop). Sides that reach its edge stay
    ///   square, like sides on the image's own edge, so the output's corners are fully covered.
    func draw(_ a: Annotation, visible: CGRect, in ctx: CGContext) {
        guard let output = output(for: a) else { return }
        ctx.saveGState()
        // The corners follow the drawn rect; the pixels cover its whole-pixel area, so nothing peeks out.
        let radius = RedactionGeometry.cornerRadius(for: a.rect, scale: a.scale)
        let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let shown = whole.intersection(visible)
        let bounds = shown.isNull ? whole : shown
        ctx.addPath(ContinuousCorners.path(in: RedactionGeometry.clipRect(for: a.rect, in: bounds, radius: radius), radius: radius))
        ctx.clip()
        ctx.interpolationQuality = output.mode == .pixelate ? .none : .high
        // The context is flipped (top-left origin); images draw upright in a y-up space.
        ctx.translateBy(x: output.area.minX, y: output.area.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(output.image, in: CGRect(origin: .zero, size: output.area.size))
        ctx.restoreGState()
    }
}
