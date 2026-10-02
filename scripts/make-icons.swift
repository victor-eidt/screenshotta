// Builds the app's icons from the brand artwork in Resources/Brand:
//   Resources/AppIcon.icns          the app icon, on the macOS icon grid
//   Resources/MenuBarIcon(@2x).png  the menu bar template icon
//   Resources/OtterHero.jpg         the full illustration, sized for the app
// Run from the repo root: swift scripts/make-icons.swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let brand = URL(fileURLWithPath: "Resources/Brand")
let resources = URL(fileURLWithPath: "Resources")
let context = CIContext()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ name: String) -> CGImage {
    let source = CGImageSourceCreateWithURL(brand.appendingPathComponent(name) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func writePNG(_ image: CGImage, to url: URL) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

func canvas(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

// MARK: App icon

/// The squircle sits in the middle 824 points of a 1024 canvas, with a soft shadow, like Apple's icons.
func appIcon(pixels: Int) -> CGImage {
    let art = load("ScreenOtterNoBG.png")
    let ctx = canvas(pixels, pixels)
    let k = CGFloat(pixels) / 1024
    let fit = 824 * k / CGFloat(max(art.width, art.height))
    let size = CGSize(width: CGFloat(art.width) * fit, height: CGFloat(art.height) * fit)
    let rect = CGRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2 + 6 * k, width: size.width, height: size.height)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.28))
    ctx.draw(art, in: rect)
    return ctx.makeImage()!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(appIcon(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(appIcon(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()

// MARK: Menu bar icon

/// The simplified otter head as a black template: cropped to the drawing, with the thinnest strokes
/// (the whiskers) thickened a touch so they survive being shrunk to menu bar size.
func menuBarIcon(height: Int) -> CGImage {
    let art = CIImage(cgImage: load("ScreenOtterMenuBar.png"))
    let alphaOnly = art.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    ])
    let thicken = CIFilter.morphologyMaximum()
    thicken.inputImage = alphaOnly
    thicken.radius = 3
    let bold = thicken.outputImage!.cropped(to: art.extent)
    let bounds = opaqueBounds(context.createCGImage(bold, from: bold.extent)!)
    let cropped = bold.cropped(to: bounds).transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    let scale = CIFilter.lanczosScaleTransform()
    scale.inputImage = cropped
    scale.scale = Float(CGFloat(height) / bounds.height)
    scale.aspectRatio = 1
    let small = scale.outputImage!
    let width = Int(small.extent.width.rounded(.up))
    return context.createCGImage(small, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: sRGB)!
}

/// The smallest rectangle holding every visible pixel, in Core Image coordinates (bottom-left origin).
func opaqueBounds(_ image: CGImage) -> CGRect {
    let ctx = canvas(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    var minX = image.width, minY = image.height, maxX = 0, maxY = 0
    for y in 0..<image.height {
        for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 24 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Rows in the buffer run top to bottom.
    return CGRect(x: minX, y: image.height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

writePNG(menuBarIcon(height: 18), to: resources.appendingPathComponent("MenuBarIcon.png"))
writePNG(menuBarIcon(height: 36), to: resources.appendingPathComponent("MenuBarIcon@2x.png"))

// MARK: Illustration

let hero = CIImage(cgImage: load("ScreenOtterFull.png"))
let shrink = CIFilter.lanczosScaleTransform()
shrink.inputImage = hero
shrink.scale = Float(1024 / hero.extent.width)
shrink.aspectRatio = 1
let heroImage = context.createCGImage(shrink.outputImage!, from: shrink.outputImage!.extent)!
let jpeg = NSBitmapImageRep(cgImage: heroImage).representation(using: .jpeg, properties: [.compressionFactor: 0.86])!
try! jpeg.write(to: resources.appendingPathComponent("OtterHero.jpg"))

print("Wrote AppIcon.icns, MenuBarIcon.png, MenuBarIcon@2x.png and OtterHero.jpg to Resources")
