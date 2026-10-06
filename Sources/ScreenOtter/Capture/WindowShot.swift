import CoreImage

/// How a window is framed in a screenshot, in points: cut at the sides and, with the minimal title bar,
/// its own top bar (`top` points of it) swapped for a thin plain one with just the traffic lights, as in recordings.
nonisolated struct WindowFrame: Equatable, Sendable {
    var minimalTitleBar: Bool
    var top: Double
    var left: Double = 0
    var right: Double = 0
}

/// A window screenshot kept apart from its background, so the editor can frame it and compose it again.
nonisolated struct WindowShot: @unchecked Sendable {
    /// The window alone, traffic lights in color.
    let window: CGImage
    /// Pixels per point.
    let scale: CGFloat
    /// Where the window was, in points, display-local, top-left origin.
    let frameInDisplay: CGRect
    let wallpaper: CGImage?
    let displaySize: CGSize
    let style: WindowStyler.Style
    /// Points from the window's top to the bottom of its own top bar, found from the traffic lights (they sit
    /// in the middle of it): where the minimal title bar cuts unless told otherwise.
    let titleBarHeight: Double

    init(window: CGImage, scale: CGFloat, frameInDisplay: CGRect, wallpaper: CGImage?, displaySize: CGSize, style: WindowStyler.Style) {
        self.window = window
        self.scale = scale
        self.frameInDisplay = frameInDisplay
        self.wallpaper = wallpaper
        self.displaySize = displaySize
        self.style = style
        titleBarHeight = TrafficLights.closeButtonCenter(in: window, scale: scale).map { Double($0.y / scale * 2).rounded() } ?? 0
    }

    /// The most that can be cut from each side, in points.
    var maximumSideCut: Double { (Double(frameInDisplay.width) * 0.4).rounded() }

    func frame(minimalTitleBar: Bool) -> WindowFrame {
        WindowFrame(minimalTitleBar: minimalTitleBar, top: titleBarHeight)
    }

    /// The window framed and put on its background.
    func compose(_ frame: WindowFrame) -> CGImage? {
        guard let framing = framing(frame) else {
            return WindowStyler.compose(
                window: window, frameInDisplay: frameInDisplay, scale: scale,
                wallpaper: wallpaper, displaySize: displaySize, style: style
            )
        }
        let size = framing.size(of: CGSize(width: window.width, height: window.height))
        let framed = RecordingRenderer.framedSource(CIImage(cgImage: window), frame: framing)
        guard let image = RecordingRenderer.context.createCGImage(
            framed, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: WindowStyler.rgbColorSpace(of: window)
        ) else { return nil }
        // Where the framed window sat on the desktop, so the wallpaper behind it is the patch that was there.
        let placed = CGRect(
            x: frameInDisplay.minX + framing.left / scale,
            y: frameInDisplay.minY + (framing.top - framing.bar) / scale,
            width: size.width / scale,
            height: size.height / scale
        )
        return WindowStyler.compose(
            window: image, frameInDisplay: placed, scale: scale,
            wallpaper: wallpaper, displaySize: displaySize, style: style
        )
    }

    /// Where the window's own top-left corner lands in the composed image, in pixels from its top-left corner.
    /// What's drawn on the window moves by the difference when the frame changes.
    func contentOrigin(_ frame: WindowFrame) -> CGPoint {
        let padding = (style.padding * scale).rounded()
        guard let framing = framing(frame) else { return CGPoint(x: padding, y: padding) }
        return CGPoint(x: padding - framing.left, y: padding + framing.bar - framing.top)
    }

    /// In the window's pixels, like a recording's frame; nil when the window is left as it is.
    private func framing(_ frame: WindowFrame) -> RecordingFrame? {
        let left = (min(frame.left, maximumSideCut) * scale).rounded()
        let right = (min(frame.right, maximumSideCut) * scale).rounded()
        var framing = RecordingFrame(left: left, right: right, scale: scale)
        if frame.minimalTitleBar {
            let top = min(max(frame.top, 0), Double(frameInDisplay.height) / 2)
            framing.top = (top * scale).rounded()
            framing.bar = (RecordingFrame.barHeight * scale).rounded()
            // The bar takes the color right under the cut; the window's own rounded corners are filled with
            // the color along its bottom, so all four follow the chosen corner radius.
            framing.barColor = WindowChromeArt.dominantColor(of: window, row: Int((top + 2) * scale)) ?? CGColor(gray: 0.93, alpha: 1)
            framing.fillColor = WindowChromeArt.dominantColor(of: window, row: window.height - Int(4 * scale)) ?? framing.barColor
        }
        guard framing.left > 0 || framing.right > 0 || framing.bar > 0 else { return nil }
        return framing
    }
}
