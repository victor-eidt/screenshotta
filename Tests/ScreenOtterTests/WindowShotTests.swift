import CoreGraphics
import Foundation
import Testing
@testable import ScreenOtter

/// Window shots framed like window recordings: the minimal title bar, and cuts at the sides.
@Suite struct WindowShotTests {
    // A 400×300 pt window at 2×: a gray 52 pt title bar with its traffic lights, an 8 pt blue toolbar strip under it,
    // then white content. Composed with 10 pt of transparent padding, no shadow and square corners.
    static let titleGray = (r: 214, g: 214, b: 214)
    static let toolbarBlue = (r: 40, g: 110, b: 230)

    @Test func findsTheTitleBarFromTheTrafficLights() {
        #expect(Self.shot().titleBarHeight == 52)
    }

    @Test func leftAsItIsByDefault() throws {
        let shot = Self.shot()
        let image = try #require(shot.compose(shot.frame(minimalTitleBar: false)))
        #expect(image.width == 840 && image.height == 640)
        #expect(Self.near(Self.pixel(image, x: 420, y: 20 + 60), Self.titleGray))
    }

    @Test func minimalTitleBarSwapsTheAppsOwnBar() throws {
        let shot = Self.shot()
        let image = try #require(shot.compose(shot.frame(minimalTitleBar: true)))
        // 104 px of the app's bar cut, a 60 px plain bar added.
        #expect(image.width == 840 && image.height == 640 - 104 + 60)
        // The plain bar takes the color right under the cut, and the app's gray bar is gone.
        #expect(Self.near(Self.pixel(image, x: 600, y: 20 + 30), Self.toolbarBlue))
        for y in stride(from: 20, to: image.height - 20, by: 4) {
            #expect(!Self.near(Self.pixel(image, x: 600, y: y), Self.titleGray), "gray at row \(y)")
        }
        #expect(shot.contentOrigin(shot.frame(minimalTitleBar: true)) == CGPoint(x: 20, y: 20 + 60 - 104))
    }

    @Test func minimalTitleBarTakesAChosenColor() throws {
        let shot = Self.shot()
        let image = try #require(shot.compose(shot.frame(minimalTitleBar: true, barColor: 0x2B2B2D)))
        #expect(Self.near(Self.pixel(image, x: 600, y: 20 + 30), (0x2B, 0x2B, 0x2D)))
        // Auto still knows what it would have picked.
        let auto = try #require(shot.sampledBarColor(shot.frame(minimalTitleBar: true)))
        #expect(abs((auto.components?[2] ?? 0) - 230.0 / 255) < 0.02)
    }

    @Test func cutsTheSides() throws {
        let shot = Self.shot()
        let frame = WindowFrame(minimalTitleBar: false, top: 52, left: 20, right: 30)
        let image = try #require(shot.compose(frame))
        #expect(image.width == 840 - 40 - 60 && image.height == 640)
        #expect(shot.contentOrigin(frame) == CGPoint(x: 20 - 40, y: 20))
    }

    @Test func editorMovesAnnotationsWithTheWindowAndUndoes() async throws {
        let remembered = Preferences.shared.windowMinimalTitleBar
        defer { Preferences.shared.windowMinimalTitleBar = remembered }
        let shot = Self.shot()
        let frame = shot.frame(minimalTitleBar: false)
        let doc = EditorDocument(
            capture: CapturedImage(image: try #require(shot.compose(frame)), scale: 2, window: (shot, frame)),
            fileURL: nil
        )
        doc.add(Annotation(kind: .arrow, start: CGPoint(x: 100, y: 200), end: CGPoint(x: 150, y: 250), color: .red, width: 10))

        doc.checkpoint()
        var minimal = frame
        minimal.minimalTitleBar = true
        doc.setWindowFrame(minimal)
        #expect(await Self.eventually { doc.image.height == 596 })
        #expect(doc.annotations.first?.start == CGPoint(x: 100, y: 200 - 44))
        #expect(doc.crop == doc.imageBounds)
        #expect(Preferences.shared.windowMinimalTitleBar)

        doc.undo()
        #expect(doc.image.height == 640)
        #expect(doc.windowFrame == frame)
        #expect(doc.annotations.first?.start == CGPoint(x: 100, y: 200))
    }

    // MARK: - Helpers

    static func shot() -> WindowShot {
        let s: CGFloat = 2
        let width = 800, height = 600
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Top-left origin, in points.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: s, y: -s)
        func fill(_ rgb: (r: Int, g: Int, b: Int), _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1))
            ctx.fill(rect)
        }
        fill((255, 255, 255), CGRect(x: 0, y: 0, width: 400, height: 300))
        fill(titleGray, CGRect(x: 0, y: 0, width: 400, height: 52))
        fill(toolbarBlue, CGRect(x: 0, y: 52, width: 400, height: 8))
        let lights = [(255, 95, 87), (254, 188, 46), (40, 200, 64)]
        for (i, color) in lights.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 14 + CGFloat(i) * 20, y: 20, width: 12, height: 12))
        }
        return WindowShot(
            window: ctx.makeImage()!, scale: s, frameInDisplay: CGRect(x: 100, y: 100, width: 400, height: 300),
            wallpaper: nil, displaySize: CGSize(width: 1440, height: 900),
            style: WindowStyler.Style(padding: 10, cornerRadius: 0, shadow: false, background: .transparent)
        )
    }

    /// The pixel at `x`, `y` (from the top-left corner), as 8-bit sRGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    static func near(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Bool {
        abs(a.r - b.r) <= 4 && abs(a.g - b.g) <= 4 && abs(a.b - b.b) <= 4
    }

    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
