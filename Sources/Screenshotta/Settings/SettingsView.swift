import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.pane) {
                Section {
                    row(.general)
                    row(.output)
                    row(.windowStyle)
                    row(.shelf)
                }
                Section {
                    row(.shortcuts)
                    row(.permissions)
                }
                Section {
                    row(.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch model.pane ?? .general {
                case .general: GeneralPane()
                case .output: OutputPane()
                case .windowStyle: WindowStylePane()
                case .shelf: ShelfPane()
                case .shortcuts: ShortcutsPane()
                case .permissions: PermissionsPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((model.pane ?? .general).title)
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint)
        }
        .tag(pane)
    }
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Play shutter sound", isOn: $prefs.playSound)
            }

            Section {
                LabeledContent("Capture Area") {
                    Button("Start") { SelectionController.shared.begin(.area) }
                }
                LabeledContent("Capture Window") {
                    Button("Start") { SelectionController.shared.begin(.window) }
                }
            } header: {
                Text("Capture")
            } footer: {
                FooterText("Screenshotta lives in the menu bar. Use the shortcuts, or the camera icon in the menu bar.")
            }

            Section {
                LabeledContent("Record Screen") {
                    Button("Start") { RecordingController.shared.toggle() }
                }
                LabeledContent("Drafts") {
                    Button("Open") { DraftsWindowController.shared.show() }
                }
                Toggle("Count down before recording", isOn: $prefs.recordingCountdown)
            } header: {
                Text("Screen Recording")
            } footer: {
                FooterText("Drag an area, click to record the whole screen, or press Space and pick a window. Click the timer in the menu bar (or press the shortcut again) to stop. The recording then opens in the editor: background, smooth cursor, auto zoom on clicks, trimming and speed.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - After capture

private struct OutputPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Save & Copy") {
                Toggle("Copy to clipboard", isOn: $prefs.copyToClipboard)
                Toggle("Save to folder", isOn: $prefs.saveToFolder)
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Label {
                            Text(prefs.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                        }
                        Button("Change…", action: chooseFolder)
                        Button {
                            try? FileManager.default.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(prefs.saveFolder)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Open in Finder")
                    }
                }
                .disabled(!prefs.saveToFolder)
            }

            Section {
                Toggle("Show thumbnail after capture", isOn: $prefs.showThumbnail)
                LabeledContent("Keep on screen") {
                    HStack {
                        Slider(value: Binding(get: { prefs.thumbnailDuration }, set: { prefs.thumbnailDuration = $0.rounded() }), in: 2...15)
                            .frame(width: 180)
                        Text("\(Int(prefs.thumbnailDuration)) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                .disabled(!prefs.showThumbnail)
            } header: {
                Text("Floating Thumbnail")
            } footer: {
                FooterText("Click the thumbnail to crop and annotate. Drag it into any app or onto a shelf, or swipe it away.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            prefs.saveFolder = url
        }
    }
}

// MARK: - Window style

private struct WindowStylePane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                WindowStylePreview(prefs: prefs)
                    .listRowInsets(EdgeInsets())
            }

            Section("Background") {
                Picker("Background", selection: $prefs.windowBackground) {
                    ForEach(WindowBackground.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Frame") {
                SliderRow(title: "Padding", value: $prefs.windowPadding, range: 0...160, unit: "pt")
                SliderRow(title: "Corner radius", value: $prefs.windowCornerRadius, range: 0...30, unit: "pt")
                Toggle("Drop shadow", isOn: $prefs.windowShadow)
            }

            Section {
                Toggle("Bring window to front before capturing", isOn: $prefs.bringWindowToFront)
            } footer: {
                FooterText("Makes the window active so its traffic lights are in color. With Accessibility access, the exact window is raised; without it, its app is activated.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                    .frame(width: 200)
                Text("\(Int(value)) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var historyCount = ShelfManager.shared.history.count

    var body: some View {
        Form {
            Section {
                Toggle("Shake the pointer while dragging to open a shelf", isOn: $prefs.shakeToOpenShelf)
                LabeledContent("New shelf") {
                    Button("Open") { ShelfManager.shared.newShelf() }
                }
            } header: {
                Text("Opening")
            } footer: {
                FooterText("A shelf holds files for a moment: drop screenshots or files on it, then drag them all, or just the selected ones, into a folder, a chat or a browser upload. The thumbnail after a capture has a tray button that adds it to the shelf.")
            }

            Section {
                LabeledContent("Recent shelves") {
                    HStack {
                        Text("\(historyCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Clear History") {
                            ShelfManager.shared.clearHistory()
                            historyCount = ShelfManager.shared.history.count
                        }
                        .disabled(historyCount == 0)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                FooterText("Reopen recent shelves from the menu bar. Shelves only point to your files; clearing the history never deletes them.")
            }
        }
        .formStyle(.grouped)
        .onAppear { historyCount = ShelfManager.shared.history.count }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared

    var body: some View {
        Form {
            Section {
                ShortcutRow(title: "Capture Area", shortcut: $prefs.areaShortcut, conflict: hotKeys.conflicts.contains(.area))
                ShortcutRow(title: "Capture Window", shortcut: $prefs.windowShortcut, conflict: hotKeys.conflicts.contains(.window))
                ShortcutRow(title: "Record Screen", shortcut: $prefs.recordShortcut, conflict: hotKeys.conflicts.contains(.record))
                ShortcutRow(title: "New Shelf", shortcut: $prefs.shelfShortcut, conflict: hotKeys.conflicts.contains(.shelf))
            } header: {
                Text("Screenshots")
            } footer: {
                FooterText("Global shortcuts are active while Screenshotta is running. While selecting, press Space to switch between area and window, and Esc to cancel.")
            }

            Section {
                Button(action: Permissions.openKeyboardShortcutsSettings) {
                    HStack {
                        Text("Open System Keyboard Shortcuts")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("System Screenshot Shortcuts")
            } footer: {
                FooterText("To use ⇧⌘3 / ⇧⌘4 here, first select Screenshots in that list and turn off the macOS shortcuts.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: Shortcut?
    let conflict: Bool

    var body: some View {
        LabeledContent {
            ShortcutRecorder(shortcut: $shortcut)
        } label: {
            Text(title)
            if conflict {
                Text("Already used by another app")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @State private var screenRecording = Permissions.screenRecordingGranted
    @State private var accessibility = Permissions.accessibilityGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Required to take screenshots and record the screen.",
                    symbol: "rectangle.dashed.badge.record",
                    tint: .red,
                    granted: screenRecording,
                    action: {
                        CGRequestScreenCaptureAccess()
                        Permissions.openScreenRecordingSettings()
                    }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Optional. Raises the exact window you click before a window capture.",
                    symbol: "accessibility",
                    tint: .blue,
                    granted: accessibility,
                    action: Permissions.requestAccessibility
                )
            } footer: {
                FooterText("After granting Screen Recording, macOS may ask you to quit and reopen Screenshotta.")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            screenRecording = Permissions.screenRecordingGranted
            accessibility = Permissions.accessibilityGranted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access…", action: action)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("Screenshotta")
                .font(.system(size: 26, weight: .bold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("Area and window screenshots, straight to your clipboard and folder.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct FooterText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
