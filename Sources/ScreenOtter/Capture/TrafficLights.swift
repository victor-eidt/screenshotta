import CoreGraphics

/// Inactive windows draw gray traffic lights. This finds them in a window capture
/// and paints the active red / yellow / green over them, so window shots always look "live".
nonisolated enum TrafficLights {
    private static let colors: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.373, blue: 0.341, alpha: 1), // close
        CGColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1), // minimize
        CGColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1), // zoom
    ]

    private struct Circle {
        var x: Double
        var y: Double
        var radius: Double
        var color: Pixel
    }

    private struct Pixel {
        var r: Int, g: Int, b: Int, a: Int

        func distance(to other: Pixel) -> Int {
            max(abs(r - other.r), abs(g - other.g), abs(b - other.b), abs(a - other.a))
        }

        var saturation: Int { max(r, g, b) - min(r, g, b) }
    }

    /// Returns a recolored copy, or nil when there are no gray traffic lights to fix.
    static func colorize(_ image: CGImage, scale: CGFloat) -> CGImage? {
        guard let bitmap = Bitmap(image),
              let lights = findLights(scale: Double(scale), width: bitmap.width, height: bitmap.height, anyColor: false, pixel: bitmap.pixel)
        else { return nil }
        let ctx = bitmap.context
        let height = bitmap.height

        for (circle, color) in zip(lights, colors) {
            let r = circle.radius + 0.75
            let rect = CGRect(x: circle.x - r, y: Double(height) - circle.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
            ctx.setLineWidth(0.5 * scale)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.25 * scale, dy: 0.25 * scale))
        }
        return ctx.makeImage()
    }

    /// Where the traffic lights sit, active (colored) or not: the center of the close button,
    /// in pixels from the image's top-left corner.
    static func closeButtonCenter(in image: CGImage, scale: CGFloat) -> CGPoint? {
        guard let bitmap = Bitmap(image),
              let lights = findLights(scale: Double(scale), width: bitmap.width, height: bitmap.height, anyColor: true, pixel: bitmap.pixel)
        else { return nil }
        return CGPoint(x: lights[0].x, y: lights.map(\.y).reduce(0, +) / 3)
    }

    /// The image drawn into an RGBA buffer whose row 0 is the top of the image.
    private struct Bitmap {
        let context: CGContext
        let width: Int
        let height: Int
        private let bytes: UnsafeMutablePointer<UInt8>

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  let data = ctx.data
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context = ctx
            bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        }

        func pixel(_ x: Int, _ y: Int) -> Pixel? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let i = (y * width + x) * 4
            return Pixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
        }
    }

    /// Three matching grays (an inactive window), or with `anyColor` also red, yellow and green.
    private static func looksLikeLights(_ a: Pixel, _ b: Pixel, _ c: Pixel, anyColor: Bool) -> Bool {
        let gray = a.saturation <= 24 && b.distance(to: a) <= 16 && c.distance(to: a) <= 16
        guard anyColor, !gray else { return gray }
        let red = a.r > a.g + 60 && a.r > a.b + 60
        let yellow = b.r > b.b + 80 && b.g > b.b + 50 && b.r >= b.g
        let green = c.g > c.r + 40 && c.g > c.b + 40
        return red && yellow && green
    }

    /// `anyColor` also finds active (red, yellow, green) lights; otherwise only the gray inactive ones.
    private static func findLights(scale s: Double, width: Int, height: Int, anyColor: Bool, pixel: (Int, Int) -> Pixel?) -> [Circle]? {
        let minRadius = 4.5 * s
        let maxRadius = 8.0 * s
        let maxWalk = Int(maxRadius * 1.4)

        // Distance from (x, y) to the first pixel that no longer matches the fill color.
        func walk(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int, _ fill: Pixel) -> Double? {
            for step in 1...maxWalk {
                guard let p = pixel(x + dx * step, y + dy * step) else { return nil }
                if p.distance(to: fill) > 14 {
                    return Double(step) * (dx != 0 && dy != 0 ? 2.0.squareRoot() : 1)
                }
            }
            return nil
        }

        var hits: [Circle] = []
        let region = (x: Int(4 * s)..<min(width, Int(100 * s)), y: Int(4 * s)..<min(height, Int(72 * s)))
        for y in region.y {
            for x in region.x {
                guard let fill = pixel(x, y), fill.a >= 240, anyColor || fill.saturation <= 24,
                      let right = walk(x, y, 1, 0, fill), let left = walk(x, y, -1, 0, fill),
                      abs(right - left) <= 1,
                      let down = walk(x, y, 0, 1, fill), let up = walk(x, y, 0, -1, fill),
                      abs(down - up) <= 1
                else { continue }
                let radius = (right + left + down + up) / 4
                guard radius >= minRadius, radius <= maxRadius, abs(radius - (down + up) / 2) <= 1.5 else { continue }

                // Round, not square: the diagonals end at about the same radius.
                let diagonals = [(1, 1), (1, -1), (-1, 1), (-1, -1)].compactMap { walk(x, y, $0.0, $0.1, fill) }
                guard diagonals.count == 4, diagonals.allSatisfy({ abs($0 - radius) <= max(2, radius * 0.22) }) else { continue }

                // Clearly different from what surrounds it.
                let ring = radius + 2.5 * s
                let outside = (0..<16).filter { i in
                    let angle = Double(i) / 16 * 2 * .pi
                    guard let p = pixel(x + Int((cos(angle) * ring).rounded()), y + Int((sin(angle) * ring).rounded())) else { return false }
                    return p.distance(to: fill) > 16
                }.count
                guard outside >= 13 else { continue }

                hits.append(Circle(x: Double(x), y: Double(y), radius: radius, color: fill))
            }
        }

        // Merge neighbouring hits of the same circle.
        var circles: [Circle] = []
        for hit in hits {
            if let i = circles.firstIndex(where: { abs($0.x - hit.x) <= 3 && abs($0.y - hit.y) <= 3 }) {
                circles[i].x = (circles[i].x + hit.x) / 2
                circles[i].y = (circles[i].y + hit.y) / 2
            } else {
                circles.append(hit)
            }
        }
        circles.sort { $0.x < $1.x }

        // Three evenly spaced, same-sized, same-colored circles in a row.
        for a in circles where a.x <= 48 * s {
            for b in circles where b.x > a.x {
                let spacing = b.x - a.x
                guard spacing >= 15 * s, spacing <= 27 * s,
                      abs(b.y - a.y) <= 2, abs(b.radius - a.radius) <= 1.5
                else { continue }
                if let c = circles.first(where: {
                    abs($0.x - (b.x + spacing)) <= 2.5 && abs($0.y - a.y) <= 2
                        && abs($0.radius - a.radius) <= 1.5 && looksLikeLights(a.color, b.color, $0.color, anyColor: anyColor)
                }) {
                    return [a, b, c]
                }
            }
        }
        return nil
    }
}
