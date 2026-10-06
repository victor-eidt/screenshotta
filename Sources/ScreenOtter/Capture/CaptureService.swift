import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "ScreenOtter needs Screen Recording permission."
        case .displayNotFound: "Couldn't find the display to capture."
        case .windowNotFound: "That window is no longer on screen."
        }
    }
}

struct CapturedImage {
    let image: CGImage
    /// Pixels per point, so saved files and the clipboard keep Retina sizing.
    let scale: CGFloat
    /// Window captures: the window apart from its background and how it's framed, so the editor can frame it again.
    var window: (shot: WindowShot, frame: WindowFrame)?
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

        let filter = displayFilter(display, content: content)

        // Display-local, top-left origin, snapped to whole device pixels: a fractional
        // rect (mouse positions often are) makes ScreenCaptureKit resample and blur text.
        let scale = CGFloat(filter.pointPixelScale)
        let local = pixelAligned(CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        ), scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int((local.width * scale).rounded()))
        config.height = max(1, Int((local.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }

    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1 / scale), height: max(maxY - minY, 1 / scale))
    }

    /// The whole display minus our own overlays: the selection overlay, thumbnail, shelves and recording
    /// panels never end up in a capture, while our regular windows (the editors, Settings) are captured
    /// like any app's. Excluding the app as a whole also covers panels that appear later, mid-recording.
    static func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let regular = Set(NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            .map { CGWindowID($0.windowNumber) })
        let shown = content.windows.filter { regular.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: shown)
    }

    // MARK: - Window

    static func captureStyledWindow(_ windowID: CGWindowID) async throws -> CapturedImage {
        let content = try await shareableContent()
        let window = try self.window(windowID, in: content)
        let raw = try await captureWindowImage(window)
        let scale = raw.scale
        let windowImage = TrafficLights.colorize(raw.image, scale: scale) ?? raw.image

        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
            ?? content.displays.first(where: { $0.frame.intersects(window.frame) })
            ?? content.displays.first
        else { throw CaptureError.displayNotFound }

        let prefs = Preferences.shared
        var wallpaper: CGImage?
        if prefs.windowBackground == .wallpaper {
            wallpaper = await self.wallpaper(of: display, content: content, scale: scale)
        }

        let style = WindowStyler.Style(
            padding: prefs.windowPadding,
            cornerRadius: prefs.windowCornerRadius,
            shadow: prefs.windowShadow,
            background: prefs.windowBackground
        )
        let shot = WindowShot(
            window: windowImage,
            scale: scale,
            frameInDisplay: window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY),
            wallpaper: wallpaper,
            displaySize: display.frame.size,
            style: style
        )
        let frame = shot.frame(minimalTitleBar: prefs.windowMinimalTitleBar, barColor: prefs.windowBarColor)
        return CapturedImage(image: shot.compose(frame) ?? windowImage, scale: scale, window: (shot, frame))
    }

    /// The window on its own, as it draws itself: no shadow, no styling, transparent around its corners.
    static func captureWindowImage(_ windowID: CGWindowID) async throws -> CapturedImage {
        let content = try await shareableContent()
        return try await captureWindowImage(try window(windowID, in: content))
    }

    private static func captureWindowImage(_ window: SCWindow) async throws -> CapturedImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }

    private static func window(_ windowID: CGWindowID, in content: SCShareableContent) throws -> SCWindow {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        return window
    }

    /// The display's desktop picture at `scale`: captured live, or read from its file.
    static func wallpaper(of display: SCDisplay, content: SCShareableContent, scale: CGFloat) async -> CGImage? {
        if let captured = try? await captureWallpaper(of: display, content: content, scale: scale) {
            return captured
        }
        return wallpaperFromFile(for: display, scale: scale)
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
