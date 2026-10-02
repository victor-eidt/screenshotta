import AppKit

/// Capture Text: read the text in an area or a window and copy it. No image is saved.
/// SelectionController awaits these, so a new selection can't start while one is still being read.
enum TextCapture {
    /// `rect` is in global Cocoa coordinates and lies on `screen`.
    static func captureArea(_ rect: CGRect, on screen: NSScreen) async {
        await run(on: screen) { try await CaptureService.captureArea(rect, on: screen).image }
    }

    /// The window on its own, without the styling a window screenshot gets: wallpaper around it
    /// would only add text that isn't the window's.
    static func captureWindow(_ candidate: WindowCandidate) async {
        await run(on: candidate.screen) { try await CaptureService.captureWindowImage(candidate.id).image }
    }

    private static func run(on screen: NSScreen?, capture: () async throws -> CGImage) async {
        let text: String
        do {
            text = try await TextRecognizer.text(in: try await capture())
        } catch CaptureError.permissionDenied {
            CaptureOutput.presentError(CaptureError.permissionDenied)
            return
        } catch {
            TextToast.show(.failed, on: screen)
            return
        }
        guard !text.isEmpty else {
            TextToast.show(.noText, on: screen)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        TextToast.show(.copied(TextCaptureSummary(text)), on: screen)
    }
}
