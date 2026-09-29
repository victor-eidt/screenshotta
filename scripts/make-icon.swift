// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt body with continuous-ish corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.30, green: 0.66, blue: 1.00, alpha: 1),
        CGColor(red: 0.20, green: 0.38, blue: 0.98, alpha: 1),
        CGColor(red: 0.42, green: 0.22, blue: 0.90, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22), CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

    // Viewfinder corners.
    let frame = CGRect(x: 232, y: 232, width: 560, height: 560)
    let arm: CGFloat = 132
    let corners = CGMutablePath()
    corners.move(to: CGPoint(x: frame.minX, y: frame.maxY - arm))
    corners.addArc(tangent1End: CGPoint(x: frame.minX, y: frame.maxY), tangent2End: CGPoint(x: frame.minX + arm, y: frame.maxY), radius: 56)
    corners.addLine(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
    corners.move(to: CGPoint(x: frame.maxX - arm, y: frame.maxY))
    corners.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.maxY), tangent2End: CGPoint(x: frame.maxX, y: frame.maxY - arm), radius: 56)
    corners.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - arm))
    corners.move(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
    corners.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.minY), tangent2End: CGPoint(x: frame.maxX - arm, y: frame.minY), radius: 56)
    corners.addLine(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
    corners.move(to: CGPoint(x: frame.minX + arm, y: frame.minY))
    corners.addArc(tangent1End: CGPoint(x: frame.minX, y: frame.minY), tangent2End: CGPoint(x: frame.minX, y: frame.minY + arm), radius: 56)
    corners.addLine(to: CGPoint(x: frame.minX, y: frame.minY + arm))
    ctx.addPath(corners)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // A little window in the middle.
    let window = CGRect(x: 342, y: 382, width: 340, height: 260)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(CGPath(roundedRect: window, cornerWidth: 38, cornerHeight: 38, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    let lights: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.37, 0.34), (1, 0.74, 0.18), (0.16, 0.79, 0.25)]
    for (i, c) in lights.enumerated() {
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: window.minX + 30 + CGFloat(i) * 40, y: window.maxY - 56, width: 26, height: 26))
    }
    ctx.setFillColor(CGColor(red: 0.2, green: 0.38, blue: 0.98, alpha: 0.18))
    ctx.addPath(CGPath(roundedRect: CGRect(x: window.minX + 30, y: window.minY + 30, width: window.width - 60, height: 140), cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print(iconset.path)
