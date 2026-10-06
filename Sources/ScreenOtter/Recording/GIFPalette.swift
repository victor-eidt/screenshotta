import Foundation

/// One color of a GIF palette.
nonisolated struct GIFColor: Hashable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

/// The one palette a whole GIF is drawn with. A shared palette is what lets frames store only what changed:
/// a pixel that didn't change maps to exactly the same color as before, so nothing shows where a frame is
/// patched in. Built from frames sampled across the video:
/// - the flat colors of the UI (backgrounds, text, buttons, a solid wallpaper) are kept exactly, so they
///   stay crisp and never dither;
/// - everything else (gradients, shadows, photos, anti-aliasing) shares the rest by median cut, splitting
///   wherever the colors spread the most.
nonisolated struct GIFPalette: Equatable, Sendable {
    /// GIFs hold 256 colors; one is kept for transparency.
    static let maximumColors = 255

    let colors: [GIFColor]

    init(colors: [GIFColor]) {
        precondition(!colors.isEmpty && colors.count <= Self.maximumColors)
        self.colors = colors
    }

    /// RGB triplets, as ImageIO wants a GIF color map.
    var colorMap: Data {
        Data(colors.flatMap { [$0.r, $0.g, $0.b] })
    }

    /// A color covering at least this share of the sampled pixels is kept exactly.
    static let flatShare = 0.004
    /// At most this many colors are kept exactly; the rest of the palette goes to everything else.
    static let maximumFlats = 48

    /// `frames` are BGRA (premultiplied, opaque), `width` × `height`, rows of `width * 4` bytes.
    /// `stride` skips pixels in both directions, for speed: the palette needs proportions, not every pixel.
    static func make(frames: [[UInt8]], width: Int, height: Int, stride step: Int = 2, maximumColors: Int = maximumColors) -> GIFPalette {
        var counts: [UInt32: Int] = [:]
        var total = 0
        let step = max(step, 1)
        for frame in frames where frame.count >= width * height * 4 {
            for y in Swift.stride(from: 0, to: height, by: step) {
                for x in Swift.stride(from: 0, to: width, by: step) {
                    let i = (y * width + x) * 4
                    counts[UInt32(frame[i + 2]) << 16 | UInt32(frame[i + 1]) << 8 | UInt32(frame[i]), default: 0] += 1
                    total += 1
                }
            }
        }
        guard total > 0 else { return GIFPalette(colors: [GIFColor(r: 0, g: 0, b: 0), GIFColor(r: 255, g: 255, b: 255)]) }

        let flats = counts
            .filter { Double($0.value) >= Double(total) * flatShare }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(min(maximumFlats, maximumColors - 1))
            .map { GIFColor(key: $0.key) }

        // Colors a hair away from a flat one map to it anyway: they don't need entries of their own.
        var bins: [Int: Bin] = [:]
        for (key, count) in counts {
            let color = GIFColor(key: key)
            if flats.contains(where: { $0.distance(to: color) <= 3 }) { continue }
            let index = Int(color.r >> 3) << 10 | Int(color.g >> 3) << 5 | Int(color.b >> 3)
            bins[index, default: Bin()].add(color, count: count)
        }
        let rest = medianCut(Array(bins.values), into: maximumColors - flats.count)
        var colors = flats
        for color in rest where !colors.contains(color) { colors.append(color) }
        return GIFPalette(colors: colors)
    }

    /// Pixels of one 32-level cell of the color cube: how many, and their sums for the mean.
    struct Bin {
        var count = 0
        var r = 0, g = 0, b = 0

        mutating func add(_ color: GIFColor, count: Int) {
            self.count += count
            r += Int(color.r) * count
            g += Int(color.g) * count
            b += Int(color.b) * count
        }

        func channel(_ axis: Int) -> Double {
            Double(axis == 0 ? r : axis == 1 ? g : b) / Double(max(count, 1))
        }
    }

    /// Splits `bins` into at most `boxes` groups, each time splitting the group whose colors spread the most
    /// (by weighted variance), at the weighted median of its widest channel. Each group becomes its mean.
    static func medianCut(_ bins: [Bin], into boxes: Int) -> [GIFColor] {
        guard !bins.isEmpty, boxes > 0 else { return [] }
        /// A group of bins, with its widest channel and spread worked out once.
        struct Box {
            let bins: [Bin]
            /// The channel with the largest spread, and that spread (weighted variance times count).
            let axis: Int
            let error: Double

            init(bins: [Bin]) {
                self.bins = bins
                let n = Double(max(bins.reduce(0) { $0 + $1.count }, 1))
                var best = (axis: 0, error: -1.0)
                for axis in 0..<3 {
                    let mean = bins.reduce(0) { $0 + $1.channel(axis) * Double($1.count) } / n
                    let error = bins.reduce(0) { $0 + pow($1.channel(axis) - mean, 2) * Double($1.count) }
                    if error > best.error { best = (axis, error) }
                }
                axis = best.axis
                error = best.error
            }

            var mean: GIFColor {
                let n = max(bins.reduce(0) { $0 + $1.count }, 1)
                func avg(_ v: Int) -> UInt8 { UInt8(min(255, max(0, (Double(v) / Double(n)).rounded()))) }
                return GIFColor(r: avg(bins.reduce(0) { $0 + $1.r }), g: avg(bins.reduce(0) { $0 + $1.g }), b: avg(bins.reduce(0) { $0 + $1.b }))
            }
        }
        var all = [Box(bins: bins)]
        while all.count < boxes {
            guard let index = all.indices.filter({ all[$0].bins.count > 1 }).max(by: { all[$0].error < all[$1].error }) else { break }
            let axis = all[index].axis
            let sorted = all[index].bins.sorted { $0.channel(axis) < $1.channel(axis) }
            let half = sorted.reduce(0) { $0 + $1.count } / 2
            var running = 0
            var cut = 1
            for (i, bin) in sorted.enumerated() {
                running += bin.count
                if running >= half { cut = min(max(i + 1, 1), sorted.count - 1); break }
            }
            all[index] = Box(bins: Array(sorted[..<cut]))
            all.append(Box(bins: Array(sorted[cut...])))
        }
        return all.map(\.mean)
    }
}

extension GIFColor {
    nonisolated init(key: UInt32) {
        self.init(r: UInt8((key >> 16) & 0xFF), g: UInt8((key >> 8) & 0xFF), b: UInt8(key & 0xFF))
    }

    /// The largest difference in any channel.
    nonisolated func distance(to other: GIFColor) -> Int {
        max(abs(Int(r) - Int(other.r)), abs(Int(g) - Int(other.g)), abs(Int(b) - Int(other.b)))
    }
}

/// Maps pixels to a palette, dithering where the palette has no exact match.
///
/// The dither is ordered (it depends only on the pixel's color and position, never on its neighbours), so a
/// pixel that doesn't change maps to the same entry every frame and the frames stay small and steady. Each
/// pixel picks between the nearest entry and the one on the other side of it, in the proportion that
/// averages out to the true color, so gradients come out smooth instead of banded, and colors the palette
/// holds exactly (the flat UI) aren't dithered at all.
nonisolated final class GIFQuantizer {
    let palette: GIFPalette
    /// Levels (out of 255, in any channel) within which the nearest entry is taken as is.
    static let exactEnough: Int32 = 2
    /// The furthest apart (in any channel) two entries can be and still be mixed.
    static let widestMix: Int32 = 48
    private let r: [Int32], g: [Int32], b: [Int32]
    /// Nearest entry for each 64-level cell of the color cube, filled in as cells come up (-1: not yet).
    private var nearestCell: [Int16]

    init(palette: GIFPalette) {
        self.palette = palette
        r = palette.colors.map { Int32($0.r) }
        g = palette.colors.map { Int32($0.g) }
        b = palette.colors.map { Int32($0.b) }
        nearestCell = [Int16](repeating: -1, count: 1 << 18)
    }

    /// The palette index for a pixel at (`x`, `y`).
    @inline(__always)
    func index(r pr: UInt8, g pg: UInt8, b pb: UInt8, x: Int, y: Int) -> UInt8 {
        let c1 = nearest(Int32(pr), Int32(pg), Int32(pb))
        let er = Int32(pr) - r[c1], eg = Int32(pg) - g[c1], eb = Int32(pb) - b[c1]
        // Too close to tell apart: no dither, so near-flat areas (and a level or two of video noise) stay clean.
        if max(abs(er), abs(eg), abs(eb)) <= Self.exactEnough { return UInt8(c1) }
        // The next entry on the far side of the pixel from the nearest one: looking further out until one
        // turns up, so pixels close to an entry still mix in a little of the next (no bands near entries).
        var c2 = c1
        var k: Int32 = 2
        while c2 == c1 && k <= 16 {
            c2 = nearest(Int32(pr) + er * k, Int32(pg) + eg * k, Int32(pb) + eb * k)
            k *= 2
        }
        guard c2 != c1 else { return UInt8(c1) }
        let dr = r[c2] - r[c1], dg = g[c2] - g[c1], db = b[c2] - b[c1]
        // Mixing colors far apart reads as speckle, not as the color between them.
        if max(abs(dr), abs(dg), abs(db)) > Self.widestMix { return UInt8(c1) }
        let length = Float(dr * dr + dg * dg + db * db)
        guard length > 0 else { return UInt8(c1) }
        // How far along from c1 to c2 the pixel sits: the share of pixels that should take c2.
        let t = Float(er * dr + eg * dg + eb * db) / length
        return Self.threshold(x: x, y: y) < t ? UInt8(c2) : UInt8(c1)
    }

    /// Interleaved gradient noise: an even, pattern-free threshold in 0..<1 for each pixel.
    @inline(__always)
    static func threshold(x: Int, y: Int) -> Float {
        let v = 0.06711056 * Float(x) + 0.00583715 * Float(y)
        let w = 52.9829189 * (v - v.rounded(.down))
        return w - w.rounded(.down)
    }

    @inline(__always)
    private func nearest(_ pr: Int32, _ pg: Int32, _ pb: Int32) -> Int {
        let cr = min(max(pr, 0), 255) >> 2, cg = min(max(pg, 0), 255) >> 2, cb = min(max(pb, 0), 255) >> 2
        let cell = Int(cr << 12 | cg << 6 | cb)
        let cached = nearestCell[cell]
        if cached >= 0 { return Int(cached) }
        // Exact colors (the flat UI) are matched on their own value, the rest on the cell's middle.
        let exact = palette.colors.firstIndex { Int32($0.r) >> 2 == cr && Int32($0.g) >> 2 == cg && Int32($0.b) >> 2 == cb }
        let found = exact ?? search(cr << 2 + 2, cg << 2 + 2, cb << 2 + 2)
        nearestCell[cell] = Int16(found)
        return found
    }

    /// Weighted for the eye: green counts most, blue least.
    private func search(_ pr: Int32, _ pg: Int32, _ pb: Int32) -> Int {
        var best = 0
        var bestDistance = Int32.max
        for i in r.indices {
            let dr = pr - r[i], dg = pg - g[i], db = pb - b[i]
            let d = 3 * dr * dr + 4 * dg * dg + 2 * db * db
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }
}
