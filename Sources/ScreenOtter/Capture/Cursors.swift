import AppKit

enum Cursors {
    /// Camera cursor for window mode, like the native one: black glyph with a white outline.
    static let camera: NSCursor = {
        let size = NSSize(width: 30, height: 26)
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            guard let base = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
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
    }()
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
