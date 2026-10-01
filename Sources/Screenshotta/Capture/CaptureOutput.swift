import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What happens after a capture: file, clipboard, sound, thumbnail.
enum CaptureOutput {
    private static var shutter: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true
    )

    static func deliver(_ capture: CapturedImage, screen: NSScreen?) {
        let prefs = Preferences.shared
        if prefs.playSound {
            shutter?.stop()
            shutter?.play()
        }

        var url: URL?
        if prefs.saveToFolder {
            do {
                url = try save(capture, in: prefs.saveFolder)
            } catch {
                presentError(error)
            }
        }
        if prefs.copyToClipboard {
            copy(capture.image, scale: capture.scale)
        }
        if prefs.showThumbnail {
            ThumbnailController.shared.show(capture, fileURL: url, on: screen)
        }
    }

    // MARK: - Files

    static func save(_ capture: CapturedImage, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, baseName: "Screenshot \(timestamp())")
        try write(capture.image, scale: capture.scale, to: url)
        return url
    }

    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        guard let data = pngData(image, scale: scale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    /// PNG with DPI metadata, so a Retina capture opens at its point size (like native screenshots).
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72 * scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A file to drag out of the thumbnail when saving to the folder is turned off.
    static func temporaryFile(for capture: CapturedImage) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshotta", isDirectory: true)
        return try? save(capture, in: folder)
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    private static func uniqueURL(in folder: URL, baseName: String) -> URL {
        var url = folder.appendingPathComponent(baseName).appendingPathExtension("png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension("png")
            counter += 1
        }
        return url
    }

    // MARK: - Clipboard

    static func copy(_ image: CGImage, scale: CGFloat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let png = pngData(image, scale: scale) {
            item.setData(png, forType: .png)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }

    // MARK: - Errors

    static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if case CaptureError.permissionDenied = error {
            alert.messageText = "Screen Recording permission needed"
            alert.informativeText = "Allow Screenshotta in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen the app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openScreenRecordingSettings()
            }
        } else {
            alert.messageText = "Screenshot failed"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

enum Permissions {
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    static func openKeyboardShortcutsSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
