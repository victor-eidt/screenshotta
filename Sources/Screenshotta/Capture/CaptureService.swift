import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screenshotta needs Screen Recording permission."
        case .displayNotFound: "Couldn't find the display to capture."
        case .windowNotFound: "That window is no longer on screen."
        }
    }
}

struct CapturedImage {
    let image: CGImage
    /// Pixels per point, so saved files and the clipboard keep Retina sizing.
    let scale: CGFloat
}

enum CaptureService {
    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw error
        }
    }

    // MARK: - Area

    /// `rect` is in global Cocoa coordinates and lies on `screen`.
    static func captureArea(_ rect: CGRect, on screen: NSScreen) async throws -> CapturedImage {
        let content = try await shareableContent()
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.displayNotFound }

        // Our overlay and thumbnail never end up in the shot.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        // Display-local, top-left origin.
        let local = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int((local.width * scale).rounded()))
        config.height = max(1, Int((local.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }

    // MARK: - Window

    static func captureStyledWindow(_ windowID: CGWindowID) async throws -> CapturedImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.captureResolution = .best
        let rawWindow = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let windowImage = TrafficLights.colorize(rawWindow, scale: scale) ?? rawWindow

        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
            ?? content.displays.first(where: { $0.frame.intersects(window.frame) })
            ?? content.displays.first
        else { throw CaptureError.displayNotFound }

        let prefs = Preferences.shared
        var wallpaper: CGImage?
        if prefs.windowBackground == .wallpaper {
            wallpaper = try? await captureWallpaper(of: display, content: content, scale: scale)
            if wallpaper == nil {
                wallpaper = wallpaperFromFile(for: display, scale: scale)
            }
        }

        let style = WindowStyler.Style(
            padding: prefs.windowPadding,
            cornerRadius: prefs.windowCornerRadius,
            shadow: prefs.windowShadow,
            background: prefs.windowBackground
        )
        let frameInDisplay = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let composed = WindowStyler.compose(
            window: windowImage,
            frameInDisplay: frameInDisplay,
            scale: scale,
            wallpaper: wallpaper,
            displaySize: display.frame.size,
            style: style
        )
        return CapturedImage(image: composed ?? windowImage, scale: scale)
    }

    /// Captures only the wallpaper windows (they sit below the desktop icons), so the
    /// background is the real desktop picture without icons or other windows on top.
    private static func captureWallpaper(of display: SCDisplay, content: SCShareableContent, scale: CGFloat) async throws -> CGImage? {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let wallpaperWindows = content.windows.filter {
            $0.windowLayer <= desktopLevel && $0.frame.intersects(display.frame)
        }
        guard !wallpaperWindows.isEmpty else { return nil }

        let filter = SCContentFilter(display: display, including: wallpaperWindows)
        let config = SCStreamConfiguration()
        config.width = Int((display.frame.width * scale).rounded())
        config.height = Int((display.frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Fallback: the desktop picture file, aspect-filled to the display size.
    private static func wallpaperFromFile(for display: SCDisplay, scale: CGFloat) -> CGImage? {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }),
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let size = CGSize(width: display.frame.width * scale, height: display.frame.height * scale)
        return WindowStyler.aspectFill(image, to: size)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
