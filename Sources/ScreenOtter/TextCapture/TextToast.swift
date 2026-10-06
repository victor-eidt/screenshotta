import AppKit
import SwiftUI

/// The small glass confirmation after Capture Text, at the bottom center of the screen: what was copied,
/// or a gentle note when there was no text or it couldn't be read. Hovering keeps it; a click dismisses it.
enum TextToast {
    enum Kind: Equatable {
        case copied(TextCaptureSummary)
        case noText
        case failed

        var announcement: String {
            switch self {
            case .copied(let summary): "Text copied, \(summary.detail())"
            case .noText: "No text found"
            case .failed: "Couldn't read text"
            }
        }
    }

    private static var panel: TextToastPanel?
    private static var hideTask: Task<Void, Never>?
    /// Transparent room around the glass for its shadow.
    static let shadowMargin: CGFloat = 24
    private static let rise: CGFloat = 10

    static func show(_ kind: Kind, on screen: NSScreen?) {
        dismiss(animated: false)
        guard let screen = screen ?? NSScreen.main else { return }

        let panel = TextToastPanel(kind: kind)
        panel.toast.onHover = { hovering in
            if hovering { hideTask?.cancel() } else { scheduleHide(after: 1.2) }
        }
        panel.toast.onClick = { dismiss(animated: true) }
        self.panel = panel

        let size = panel.frame.size
        let visible = screen.visibleFrame
        let target = NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 36 - shadowMargin, width: size.width, height: size.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: -rise), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: kind.announcement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        scheduleHide(after: kind == .failed ? 3 : kind == .noText ? 2.2 : 2.6)
    }

    static func dismiss(animated: Bool) {
        hideTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduceMotion {
                panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -rise / 2), display: true)
            }
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private static func scheduleHide(after delay: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            dismiss(animated: true)
        }
    }
}

final class TextToastPanel: NSPanel {
    let toast: TextToastContainer

    init(kind: TextToast.Kind) {
        let hosting = NSHostingView(rootView: TextToastView(kind: kind))
        let content = hosting.fittingSize
        let margin = TextToast.shadowMargin
        let size = NSSize(width: content.width + margin * 2, height: content.height + margin * 2)
        toast = TextToastContainer(frame: NSRect(origin: .zero, size: size))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        // On macOS 26 the glass draws its own shadow; the older material needs the window's.
        if #unavailable(macOS 26) { hasShadow = true } else { hasShadow = false }
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        let glass = GlassBackground.make(content: hosting, cornerRadius: TextToastView.cornerRadius)
        glass.frame = toast.bounds.insetBy(dx: margin, dy: margin)
        glass.autoresizingMask = [.width, .height]
        toast.addSubview(glass)
        contentView = toast
    }

    override var canBecomeKey: Bool { false }
}

/// Hover and click on a panel that never becomes key, so the app you copied from stays in front.
final class TextToastContainer: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Clicks land here, not in the SwiftUI content; the shadow margin lets them through.
        let glass = bounds.insetBy(dx: TextToast.shadowMargin, dy: TextToast.shadowMargin)
        return glass.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let glass = bounds.insetBy(dx: TextToast.shadowMargin, dy: TextToast.shadowMargin)
        addTrackingArea(NSTrackingArea(rect: glass, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

struct TextToastView: View {
    static let cornerRadius: CGFloat = 18
    let kind: TextToast.Kind

    var body: some View {
        HStack(spacing: 11) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if let detail {
                        Spacer(minLength: 0)
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 268, alignment: .leading)
        }
        .padding(.leading, 11)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        // A smoky layer keeps it a crisp dark HUD over light, busy content (it lands on text, after all).
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// The accent only marks success; the notes get a muted badge.
    private var badge: some View {
        let symbol = switch kind {
        case .copied: "checkmark"
        case .noText: "text.magnifyingglass"
        case .failed: "exclamationmark"
        }
        let isCopied = if case .copied = kind { true } else { false }
        return ZStack {
            Circle().fill(isCopied ? Brand.accent : Color.white.opacity(0.12))
            Image(systemName: symbol)
                .font(.system(size: kind == .noText ? 13 : 12, weight: .bold))
                .foregroundStyle(.white.opacity(isCopied ? 1 : 0.8))
        }
        .frame(width: 30, height: 30)
    }

    private var title: String {
        switch kind {
        case .copied: "Text copied"
        case .noText: "No text found"
        case .failed: "Couldn\u{2019}t read text"
        }
    }

    private var detail: String? {
        guard case .copied(let summary) = kind else { return nil }
        return summary.lineCount > 1 ? "\(summary.lineCount) lines" : nil
    }

    private var subtitle: String {
        switch kind {
        case .copied(let summary): "\u{201C}\(summary.firstLine)\u{201D}"
        case .noText: "Try a larger area or sharper text."
        case .failed: "Try again, or select a smaller area."
        }
    }
}
