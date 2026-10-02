import SwiftUI

/// The inspector's keystroke tab: show or hide the pill, and its look.
struct KeystrokePanel: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let recording = doc.keystrokes, !recording.events.isEmpty {
                let style = doc.edits.style.keystrokes
                InspectorToggle(
                    title: "Show keystrokes",
                    detail: summary(recording),
                    isOn: Binding(get: { doc.showsKeystrokes }, set: { doc.setKeystrokesVisible($0) })
                )
                Group {
                    InspectorSection("Style") {
                        HStack(spacing: 8) {
                            ForEach(KeystrokeTheme.allCases) { theme in
                                KeystrokeThemeTile(theme: theme, selected: style.theme == theme) {
                                    doc.update { $0.style.keystrokes.theme = theme }
                                }
                            }
                        }
                    }
                    InspectorSection("Size") {
                        SegmentedPills(options: KeystrokeSize.allCases, selection: doc.style(\.keystrokes.size), title: \.title, name: \.name)
                    }
                    InspectorSection("Position") {
                        SegmentedPills(options: KeystrokePosition.allCases, selection: doc.style(\.keystrokes.position), title: \.title)
                    }
                    Text("Presses close together share one pill. Cuts and speed changes carry the keys along with the video.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!doc.showsKeystrokes)
                .opacity(doc.showsKeystrokes ? 1 : 0.5)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    if doc.keystrokes?.blocked == true {
                        Text("Input Monitoring was off")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Keystrokes was on, but macOS blocked key presses for this recording. Allow ScreenOtter in Privacy & Security › Input Monitoring to show them next time.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !KeystrokePermission.isGranted {
                            Button("Open Privacy & Security") { KeystrokePermission.openSettings() }
                                .controlSize(.small)
                                .padding(.top, 4)
                        }
                    } else if doc.hasKeystrokes {
                        Text("No shortcuts pressed")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Keystrokes were on for this recording, but no shortcut was pressed while it ran.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if Preferences.shared.recordKeystrokes {
                        // On now, but this recording was made before it was turned on.
                        Text("No keystrokes in this recording")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Keystrokes was off when this was recorded. The shortcuts you press in your next recording show here as a small pill over the video.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !KeystrokePermission.isGranted {
                            Text("Input Monitoring is off, so macOS will block them until you allow ScreenOtter in Privacy & Security.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Privacy & Security") { KeystrokePermission.openSettings() }
                                .controlSize(.small)
                                .padding(.top, 4)
                        }
                    } else {
                        Text("No keystrokes in this recording")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Turn on Keystrokes in Settings › Recording (or in the bar shown while you choose what to record) before you record. The shortcuts you press then show here as a small pill over the video.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Settings") { SettingsWindowController.shared.show(.recording) }
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func summary(_ recording: KeystrokeRecording) -> String {
        let count = recording.events.count
        let noun = recording.allKeys ? "key" : "shortcut"
        return "\(count) \(noun)\(count == 1 ? "" : "s") recorded"
    }
}

/// A theme as a small preview: a "⌘K" pill in that theme on a gradient.
private struct KeystrokeThemeTile: View {
    let theme: KeystrokeTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.35, green: 0.33, blue: 0.75), Color(red: 0.62, green: 0.4, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    HStack(spacing: 1.5) {
                        Text("⌘").opacity(0.62)
                        Text("K")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme == .dark ? Color.white : Color(white: 0.07))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(theme == .dark ? Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.84) : Color.white.opacity(0.85))
                            .shadow(color: .black.opacity(theme == .dark ? 0.3 : 0.15), radius: 4, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(theme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08), lineWidth: 0.5)
                    )
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(theme.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(6)
            .padding(.bottom, 2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Brand.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(theme.title)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
