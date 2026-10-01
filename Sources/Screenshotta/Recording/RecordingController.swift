import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

enum RecordingTarget {
    /// `rect` is in global Cocoa coordinates and lies on the screen.
    case area(CGRect, NSScreen)
    case display(NSScreen)
    case window(WindowCandidate)
}

/// Runs one screen recording: countdown, capture, pointer tracking, then opens the editor.
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum State: Equatable {
        case idle
        case preparing
        case countingDown
        case recording(since: Date)
        case finishing
    }

    @Published private(set) var state: State = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private struct Session {
        let project: RecordingProject
        let metadata: RecordingMetadata
        let recorder: ScreenRecorder
        let tracker: CursorTracker
    }

    private var session: Session?
    private var border: RecordingBorderPanel?
    private var countdownCancelled = false

    /// The menu bar item and the shortcut: pick what to record, or stop.
    func toggle() {
        switch state {
        case .idle: SelectionController.shared.begin(.area, purpose: .recording)
        case .recording: stop()
        case .countingDown: countdownCancelled = true
        case .preparing, .finishing: break
        }
    }

    // MARK: - Starting

    func start(_ target: RecordingTarget) {
        guard state == .idle else { return }
        state = .preparing
        Task {
            do {
                try await begin(target)
            } catch {
                state = .idle
                CaptureOutput.presentError(error)
            }
        }
    }

    private struct Setup {
        var filter: SCContentFilter
        var configuration: SCStreamConfiguration
        var source: RecordingMetadata.Source
        var pointSize: CGSize
        var scale: CGFloat
        var alpha = false
        var display: SCDisplay
        /// Global Cocoa rect to outline while recording, for areas.
        var outline: CGRect?
        var countdownCenter: CGPoint
        var locate: (CGPoint) -> CGPoint?
    }

    private func begin(_ target: RecordingTarget) async throws {
        let content = try await CaptureService.shareableContent()
        let setup = try makeSetup(target, content: content)
        let project = try RecordingProject.create(named: "Recording \(CaptureOutput.timestamp())")

        do {
            // The desktop picture, for the "Wallpaper" background in the editor.
            if let wallpaper = await CaptureService.wallpaper(of: setup.display, content: content, scale: 1) {
                try? CaptureOutput.write(wallpaper, scale: 1, to: project.wallpaperURL)
            }

            if Preferences.shared.recordingCountdown {
                state = .countingDown
                guard await countdown(at: setup.countdownCenter) else {
                    try? FileManager.default.removeItem(at: project.folder)
                    state = .idle
                    return
                }
            }

            let recorder = try ScreenRecorder(filter: setup.filter, configuration: setup.configuration, outputURL: project.videoURL, alpha: setup.alpha)
            recorder.onFailure = { _ in
                Task { @MainActor in RecordingController.shared.stop() }
            }
            let tracker = CursorTracker(locate: setup.locate)
            tracker.start()
            do {
                try await recorder.start()
            } catch {
                _ = tracker.stop(start: 0, duration: 0)
                throw error
            }

            let metadata = RecordingMetadata(
                source: setup.source,
                title: project.folder.lastPathComponent,
                createdAt: Date(),
                pointSize: setup.pointSize,
                scale: setup.scale,
                duration: 0
            )
            session = Session(project: project, metadata: metadata, recorder: recorder, tracker: tracker)
            state = .recording(since: Date())
            if let outline = setup.outline {
                border = RecordingBorderPanel(around: outline)
                border?.orderFrontRegardless()
            }
        } catch {
            try? FileManager.default.removeItem(at: project.folder)
            throw error
        }
    }

    private func makeSetup(_ target: RecordingTarget, content: SCShareableContent) throws -> Setup {
        func display(for screen: NSScreen) throws -> SCDisplay {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.displayNotFound
            }
            return display
        }

        switch target {
        case let .area(rect, screen):
            let display = try display(for: screen)
            // Our own panels (the outline, the countdown) never end up in the video.
            let filter = CaptureService.displayFilter(display, content: content)
            let scale = CGFloat(filter.pointPixelScale)
            var local = CaptureService.pixelAligned(CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            ), scale: scale)
            // Whole, even pixel sizes, so the video isn't resampled.
            let pixelWidth = max(2, Int((local.width * scale).rounded()) / 2 * 2)
            let pixelHeight = max(2, Int((local.height * scale).rounded()) / 2 * 2)
            local.size = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
            let configuration = ScreenRecorder.configuration(width: pixelWidth, height: pixelHeight)
            configuration.sourceRect = local

            let left = screen.frame.minX + local.minX
            let top = screen.frame.maxY - local.minY
            let outline = CGRect(x: left, y: top - local.height, width: local.width, height: local.height)
            return Setup(
                filter: filter, configuration: configuration, source: .area, pointSize: local.size, scale: scale,
                display: display, outline: outline, countdownCenter: CGPoint(x: outline.midX, y: outline.midY),
                locate: { CGPoint(x: $0.x - left, y: top - $0.y) }
            )

        case let .display(screen):
            let display = try display(for: screen)
            let filter = CaptureService.displayFilter(display, content: content)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = ScreenRecorder.configuration(
                width: Int((screen.frame.width * scale).rounded()),
                height: Int((screen.frame.height * scale).rounded())
            )
            let frame = screen.frame
            return Setup(
                filter: filter, configuration: configuration, source: .display,
                pointSize: CGSize(width: CGFloat(configuration.width) / scale, height: CGFloat(configuration.height) / scale),
                scale: scale, display: display, countdownCenter: CGPoint(x: frame.midX, y: frame.midY),
                locate: { CGPoint(x: $0.x - frame.minX, y: frame.maxY - $0.y) }
            )

        case let .window(candidate):
            guard let window = content.windows.first(where: { $0.windowID == candidate.id }) else {
                throw CaptureError.windowNotFound
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = ScreenRecorder.configuration(
                width: Int((window.frame.width * scale).rounded()),
                height: Int((window.frame.height * scale).rounded())
            )
            configuration.ignoreShadowsSingleWindow = true
            configuration.shouldBeOpaque = false
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
                throw CaptureError.displayNotFound
            }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let windowID = candidate.id
            var bounds = candidate.quartzFrame
            return Setup(
                filter: filter, configuration: configuration, source: .window,
                pointSize: CGSize(width: CGFloat(configuration.width) / scale, height: CGFloat(configuration.height) / scale),
                scale: scale, alpha: true, display: display,
                countdownCenter: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY),
                locate: { point in
                    // The window may move while recording; follow it.
                    if let current = Self.quartzBounds(of: windowID) { bounds = current }
                    return CGPoint(x: point.x - bounds.minX, y: (primaryHeight - point.y) - bounds.minY)
                }
            )
        }
    }

    private static func quartzBounds(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCreateDescriptionFromArray([windowID] as CFArray) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    // MARK: - Countdown

    /// 3, 2, 1 in the middle of what's about to be recorded. Esc (or the record shortcut) cancels.
    private func countdown(at center: CGPoint) async -> Bool {
        countdownCancelled = false
        let model = CountdownModel()
        let panel = CountdownPanel(center: center, model: model)
        panel.orderFrontRegardless()
        HotKeyManager.shared.register(.escape, Shortcut(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)) { [weak self] in
            self?.countdownCancelled = true
        }
        defer {
            HotKeyManager.shared.unregister(.escape)
            panel.orderOut(nil)
        }
        for number in [3, 2, 1] {
            withAnimation(.snappy(duration: 0.25)) { model.number = number }
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(100))
                if countdownCancelled { return false }
            }
        }
        return true
    }

    // MARK: - Stopping

    func stop() {
        guard isRecording, let session else { return }
        state = .finishing
        border?.orderOut(nil)
        border = nil
        Task {
            defer {
                self.session = nil
                state = .idle
            }
            do {
                let result = try await session.recorder.stop()
                let cursor = session.tracker.stop(start: result.startHostTime, duration: result.duration)
                var metadata = session.metadata
                metadata.duration = result.duration
                try session.project.save(metadata)
                try session.project.save(cursor)
                try session.project.save(RecordingEdits.initial(duration: result.duration, clicks: cursor.clicks, style: .lastUsed))
                RecordingEditorWindowController.open(session.project)
            } catch {
                _ = session.tracker.stop(start: 0, duration: 0)
                try? FileManager.default.removeItem(at: session.project.folder)
                CaptureOutput.presentError(error)
            }
        }
    }
}

// MARK: - Panels

/// A thin outline around the area being recorded. Excluded from the recording like all our windows.
final class RecordingBorderPanel: NSPanel {
    init(around rect: CGRect) {
        let margin: CGFloat = 4
        super.init(contentRect: rect.insetBy(dx: -margin, dy: -margin), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = RecordingBorderView()
    }
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}

final class CountdownModel: ObservableObject {
    @Published var number = 3
}

private final class CountdownPanel: NSPanel {
    init(center: CGPoint, model: CountdownModel) {
        let size = NSSize(width: 150, height: 150)
        super.init(
            contentRect: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        isReleasedWhenClosed = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: CountdownView(model: model))
    }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            Text("\(model.number)")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
            Text("Esc to cancel")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(y: 44)
        }
        .padding(12)
        .environment(\.colorScheme, .dark)
    }
}
