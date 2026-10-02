import AppKit
import Combine
import SwiftUI

/// The small bar at the bottom of the screen while choosing what to record: microphone, system audio and camera.
/// It floats above the selection overlay and never takes focus, like the overlay itself. It sits on the
/// screen with the pointer, so it's there whichever display is being recorded.
final class RecordingOptionsBar {
    static let shared = RecordingOptionsBar()

    private var panel: OptionsPanel?

    func show() {
        guard panel == nil, let screen = Self.screen(containing: NSEvent.mouseLocation) else { return }
        let panel = OptionsPanel(screenFrame: screen.frame)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Moves the bar to the screen under `point` when the pointer changes screens.
    func follow(_ point: CGPoint) {
        guard let panel, let screen = Self.screen(containing: point), screen.frame != panel.screenFrame else { return }
        panel.screenFrame = screen.frame
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class RecordingOptionsModel: ObservableObject {
    @Published var showsMicrophones = false
    @Published private(set) var microphones: [Microphones.Device] = []
    @Published private(set) var microphoneDenied = Microphones.isDenied
    @Published var showsCameras = false
    @Published private(set) var cameras: [Webcams.Device] = []
    @Published private(set) var cameraDenied = Webcams.isDenied
    @Published private(set) var keystrokesBlocked = !KeystrokePermission.isGranted

    func refreshDevices() {
        microphones = Microphones.all()
        microphoneDenied = Microphones.isDenied
        cameras = Webcams.all()
        cameraDenied = Webcams.isDenied
        keystrokesBlocked = !KeystrokePermission.isGranted
    }

    /// Turns the keystroke overlay on or off; turning it on asks for Input Monitoring the first time.
    func toggleKeystrokes() {
        let prefs = Preferences.shared
        prefs.recordKeystrokes.toggle()
        if prefs.recordKeystrokes, !KeystrokePermission.isGranted { KeystrokePermission.request() }
        keystrokesBlocked = !KeystrokePermission.isGranted
    }

    /// The camera that will record: the chosen one if it's connected, else the default.
    var selectedCamera: Webcams.Device? {
        let prefs = Preferences.shared
        guard prefs.recordCamera else { return nil }
        return Webcams.recording(saved: prefs.cameraID, in: cameras)
    }

    /// The camera is on and allowed.
    var cameraActive: Bool { Preferences.shared.recordCamera && !cameraDenied && !cameras.isEmpty }

    /// The microphone that will record: the chosen one if it's plugged in, else the system's.
    var selectedMicrophone: Microphones.Device? {
        let prefs = Preferences.shared
        guard prefs.recordMicrophone else { return nil }
        return Microphones.recording(saved: prefs.microphoneID, in: microphones)
    }

    /// The microphone is on and allowed.
    var microphoneActive: Bool { Preferences.shared.recordMicrophone && !microphoneDenied }
}

private final class OptionsPanel: NSPanel {
    private let model = RecordingOptionsModel()
    var screenFrame: CGRect {
        didSet { fit() }
    }
    private var hosting: NSHostingView<RecordingOptionsView>!
    private var observers: Set<AnyCancellable> = []

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        // Just above the selection overlay.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hosting = NSHostingView(rootView: RecordingOptionsView(model: model, prefs: .shared))
        contentView = hosting
        model.refreshDevices()

        // The bar grows upward when the microphone list opens.
        Publishers.Merge(model.objectWillChange, Preferences.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fit() }
            .store(in: &observers)
        fit()
    }

    override var canBecomeKey: Bool { false }

    private func fit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        setFrame(NSRect(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.minY + 64, width: size.width, height: size.height), display: true)
    }
}

// MARK: - View

struct RecordingOptionsView: View {
    @ObservedObject var model: RecordingOptionsModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 8) {
            if model.showsMicrophones {
                microphoneList
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if model.showsCameras {
                cameraList
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            HStack(spacing: 6) {
                OptionChip(
                    symbol: model.microphoneActive ? "mic.fill" : "mic.slash.fill",
                    title: microphoneTitle,
                    isOn: model.microphoneActive,
                    warning: prefs.recordMicrophone && model.microphoneDenied,
                    disclosure: true
                ) {
                    model.refreshDevices()
                    withAnimation(.snappy(duration: 0.2)) {
                        model.showsCameras = false
                        model.showsMicrophones.toggle()
                    }
                }
                OptionChip(
                    symbol: prefs.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    title: "System Audio",
                    isOn: prefs.recordSystemAudio
                ) {
                    prefs.recordSystemAudio.toggle()
                }
                OptionChip(
                    symbol: model.cameraActive ? "video.fill" : "video.slash.fill",
                    title: cameraTitle,
                    isOn: model.cameraActive,
                    warning: prefs.recordCamera && model.cameraDenied,
                    disclosure: true
                ) {
                    model.refreshDevices()
                    withAnimation(.snappy(duration: 0.2)) {
                        model.showsMicrophones = false
                        model.showsCameras.toggle()
                    }
                }
                OptionChip(
                    symbol: "keyboard",
                    title: prefs.recordKeystrokes && model.keystrokesBlocked ? "Keystrokes Blocked" : "Keystrokes",
                    isOn: prefs.recordKeystrokes && !model.keystrokesBlocked,
                    warning: prefs.recordKeystrokes && model.keystrokesBlocked
                ) {
                    model.toggleKeystrokes()
                }
            }
            .padding(5)
            .background(HUDBackground(cornerRadius: 21))
        }
        .padding(16) // room for the shadow
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            if inside { NSCursor.arrow.set() }
        }
        .fixedSize()
    }

    private var microphoneTitle: String {
        if prefs.recordMicrophone, model.microphoneDenied { return "Microphone Blocked" }
        return model.selectedMicrophone?.name ?? "No Microphone"
    }

    private var microphoneList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.microphoneDenied {
                ListRow(title: "Allow in System Settings…", symbol: "lock.fill", isSelected: false) {
                    Microphones.openPrivacySettings()
                    SelectionController.shared.cancel()
                }
                Divider().padding(.vertical, 3).padding(.horizontal, 8)
            }
            ListRow(title: "No Microphone", symbol: "mic.slash", isSelected: !prefs.recordMicrophone) {
                prefs.recordMicrophone = false
                close()
            }
            ForEach(model.microphones) { device in
                ListRow(title: device.name, symbol: "mic", isSelected: model.selectedMicrophone == device) {
                    prefs.microphoneID = device.id
                    prefs.recordMicrophone = true
                    close()
                }
            }
        }
        .padding(5)
        .frame(width: 280)
        .background(HUDBackground(cornerRadius: 14))
    }

    private var cameraTitle: String {
        if prefs.recordCamera, model.cameraDenied { return "Camera Blocked" }
        return model.selectedCamera?.name ?? "No Camera"
    }

    private var cameraList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.cameraDenied {
                ListRow(title: "Allow in System Settings…", symbol: "lock.fill", isSelected: false) {
                    Webcams.openPrivacySettings()
                    SelectionController.shared.cancel()
                }
                Divider().padding(.vertical, 3).padding(.horizontal, 8)
            }
            ListRow(title: "No Camera", symbol: "video.slash", isSelected: !prefs.recordCamera) {
                prefs.recordCamera = false
                close()
            }
            ForEach(model.cameras) { device in
                ListRow(title: device.name, symbol: "video", isSelected: model.selectedCamera == device) {
                    prefs.cameraID = device.id
                    prefs.recordCamera = true
                    close()
                }
            }
        }
        .padding(5)
        .frame(width: 280)
        .background(HUDBackground(cornerRadius: 14))
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) {
            model.showsMicrophones = false
            model.showsCameras = false
        }
    }
}

/// Dark glass, as the countdown uses.
private struct HUDBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

private struct OptionChip: View {
    let symbol: String
    let title: String
    let isOn: Bool
    var warning = false
    var disclosure = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(warning ? Color.orange : isOn ? Brand.accent : Color.secondary)
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
                // Long device names are shortened by hand: the bar sizes itself to fit its content.
                Text(title.count > 28 ? title.prefix(27) + "…" : title)
                    .lineLimit(1)
                    .foregroundStyle(isOn || warning ? Color.primary : Color.secondary)
                if disclosure {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(isOn ? 0.13 : hovering ? 0.07 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}

private struct ListRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.accent)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
