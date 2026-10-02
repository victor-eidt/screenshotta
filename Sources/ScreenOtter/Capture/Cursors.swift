import AppKit

enum Cursors {
    /// Camera cursor for window mode, like the native one: black glyph with a white outline.
    static let camera = outlined("camera.fill", size: NSSize(width: 30, height: 26))

    /// Window mode for Capture Text, which reads the window instead of photographing it. An open glyph
    /// like this one breaks up when outlined, so it sits on a small white plate instead.
    static let textViewfinder: NSCursor = {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let glyph = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.black])))
            else { return false }
            let plate = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 6.5, yRadius: 6.5)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowBlurRadius = 2.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            NSColor.white.setFill()
            plate.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0, alpha: 0.18).setStroke()
            plate.lineWidth = 0.5
            plate.stroke()
            glyph.draw(at: NSPoint(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    private static func outlined(_ symbol: String, size: NSSize) -> NSCursor {
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config),
                let outline = base.withSymbolConfiguration(.init(paletteColors: [.white])),
                let glyph = base.withSymbolConfiguration(.init(paletteColors: [.black]))
            else { return false }
            let origin = NSPoint(x: (rect.width - base.size.width) / 2, y: (rect.height - base.size.height) / 2)
            for dx in [-1.5, 0, 1.5] {
                for dy in [-1.5, 0, 1.5] {
                    outline.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }
}

/// Lets a background (non-active) app set the cursor. The overlay never activates the app,
/// so without this macOS ignores our crosshair. Private SkyLight API, resolved at runtime.
enum BackgroundCursor {
    static func enable() {
        typealias ConnectionFn = @convention(c) () -> Int32
        typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connectionSym = dlsym(handle, "SLSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
              let setPropertySym = dlsym(handle, "SLSSetConnectionProperty") ?? dlsym(handle, "CGSSetConnectionProperty")
        else { return }

        let connection = unsafeBitCast(connectionSym, to: ConnectionFn.self)()
        let setProperty = unsafeBitCast(setPropertySym, to: SetPropertyFn.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
