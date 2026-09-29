import Carbon.HIToolbox
import SwiftUI

/// Click to record a new global shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if hovering, shortcut != nil, !recording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
                .transition(.opacity)
            }

            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    if recording {
                        Chip(text: "Type shortcut…", highlighted: true)
                    } else if let shortcut {
                        ForEach(Array((shortcut.modifierSymbols + [shortcut.keyName]).enumerated()), id: \.offset) { _, key in
                            KeyCap(text: key)
                        }
                    } else {
                        Chip(text: "Not set", highlighted: false)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "Press a key combination, Esc to cancel, Delete to clear" : "Click to record a shortcut")
        }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        HotKeyManager.shared.suspendCaptureShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stopRecording()
            case kVK_Delete, kVK_ForwardDelete:
                shortcut = nil
                stopRecording()
            default:
                let candidate = Shortcut(event: event)
                if candidate.isValid {
                    shortcut = candidate
                    stopRecording()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if recording {
            recording = false
            HotKeyManager.shared.reloadCaptureShortcuts()
        }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, text.count > 1 ? 8 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
    }
}

private struct Chip: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted ? 0.2 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(highlighted ? 1 : 0.25), lineWidth: highlighted ? 1.5 : 1)
            )
    }
}
