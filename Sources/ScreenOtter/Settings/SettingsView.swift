import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $model.pane)
                .frame(width: 226)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PageHeader(pane: model.pane)
                    page
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .id(model.pane)
        }
        .ignoresSafeArea()
        .tint(Brand.accent)
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private var page: some View {
        switch model.pane {
        case .general: GeneralPane(model: model)
        case .output: OutputPane()
        case .windowStyle: WindowStylePane()
        case .recording: RecordingPane()
        case .shelf: ShelfPane()
        case .shortcuts: ShortcutsPane()
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                AppIconImage(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Brand.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Version \(Brand.version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 50)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(SettingsPane.groups.indices, id: \.self) { group in
                    VStack(spacing: 2) {
                        ForEach(SettingsPane.groups[group]) { pane in
                            SidebarRow(pane: pane, isSelected: selection == pane) { selection = pane }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffect(material: .sidebar))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
        }
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 24)
                Text(pane.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Brand.accent.opacity(0.16) : Color.primary.opacity(isHovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.gradient)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.25), radius: 2, y: 1)
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Page building blocks

private struct PageHeader: View {
    let pane: SettingsPane

    var body: some View {
        if pane != .about {
            VStack(alignment: .leading, spacing: 5) {
                Text(pane.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(pane.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A titled group of rows on a soft card: no outlines, just a fill and hairlines between rows.
private struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .settingsCard()
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 1.5, y: 0.5)
        )
    }
}

private extension View {
    func settingsCard(radius: CGFloat = 12) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

/// A title (and optional detail) on the left, a control on the right.
private struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let accessory: Accessory

    init(_ title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 46)
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 12) {
                Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                    .controlSize(.small)
                    .frame(width: 190)
                Text("\(Int(value)) \(unit)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Soft, borderless buttons; `prominent` fills with the brand color.
private struct SoftButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration, prominent: prominent)
    }

    private struct SoftButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Brand.accent : Color.primary.opacity(isHovering && isEnabled ? 0.11 : 0.07))
                )
                .brightness(prominent && isHovering && isEnabled ? 0.06 : 0)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

private extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static var softProminent: SoftButtonStyle { SoftButtonStyle(prominent: true) }
}

/// A shortcut shown as small key caps.
private struct ShortcutBadge: View {
    let shortcut: Shortcut?

    var body: some View {
        if let shortcut {
            HStack(spacing: 3) {
                ForEach(Array((shortcut.modifierSymbols + [shortcut.keyName]).enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, key.count > 1 ? 5 : 0)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                QuickAction(title: "Capture Area", symbol: "rectangle.dashed", tint: Brand.accent, shortcut: prefs.areaShortcut) {
                    SelectionController.shared.begin(.area)
                }
                QuickAction(title: "Capture Window", symbol: "macwindow", tint: .purple, shortcut: prefs.windowShortcut) {
                    SelectionController.shared.begin(.window)
                }
                QuickAction(title: "Capture Text", symbol: "text.viewfinder", tint: .teal, shortcut: prefs.textShortcut) {
                    SelectionController.shared.begin(.area, purpose: .text)
                }
                QuickAction(title: "Record Screen", symbol: "record.circle", tint: .red, shortcut: prefs.recordShortcut) {
                    RecordingController.shared.toggle()
                }
            }
            // One height for every card, so a title that wraps doesn't knock its neighbors out of line.
            .fixedSize(horizontal: false, vertical: true)

            SettingsSection("Behavior", footer: "ScreenOtter lives in the menu bar: click the otter there, or use the shortcuts from any app.") {
                SettingsRow("Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                RowDivider()
                ToggleRow(title: "Play shutter sound", detail: "When a screenshot is taken.", isOn: $prefs.playSound)
            }

            SettingsSection("More") {
                SettingsRow("Change shortcuts", detail: "Pick your own keys for every capture.") {
                    Button("Shortcuts") { model.pane = .shortcuts }
                        .buttonStyle(.soft)
                }
                RowDivider()
                SettingsRow("Recording drafts", detail: "Every recording, with its edits, ready to pick up again.") {
                    Button("Open Drafts") { DraftsWindowController.shared.show() }
                        .buttonStyle(.soft)
                }
            }
        }
    }
}

private struct QuickAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let shortcut: Shortcut?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    ShortcutBadge(shortcut: shortcut)
                        .frame(height: 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .settingsCard(radius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(isHovering ? 0.05 : 0))
            )
            .scaleEffect(isHovering ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
        .help("Start now")
    }
}

// MARK: - After capture

private struct OutputPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Save & Copy") {
                ToggleRow(title: "Copy to clipboard", detail: "Paste a capture straight away.", isOn: $prefs.copyToClipboard)
                RowDivider()
                ToggleRow(title: "Save to folder", detail: "Keep every capture as a PNG file.", isOn: $prefs.saveToFolder)
                RowDivider()
                SettingsRow("Folder") {
                    HStack(spacing: 8) {
                        Button {
                            try? FileManager.default.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(prefs.saveFolder)
                        } label: {
                            Label {
                                Text(prefs.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "folder.fill").foregroundStyle(Brand.accent)
                            }
                            .font(.system(size: 12))
                            .frame(maxWidth: 220)
                        }
                        .buttonStyle(.plain)
                        .help("Open in Finder")
                        Button("Change…", action: chooseFolder)
                            .buttonStyle(.soft)
                    }
                }
                .disabled(!prefs.saveToFolder)
                .opacity(prefs.saveToFolder ? 1 : 0.5)
            }

            SettingsSection("Floating Thumbnail", footer: "Click the thumbnail to crop and annotate. Drag it into any app or onto a shelf, or swipe it away.") {
                ToggleRow(title: "Show thumbnail after capture", isOn: $prefs.showThumbnail)
                RowDivider()
                SliderRow(title: "Keep on screen", value: $prefs.thumbnailDuration, range: 2...15, unit: "s")
                    .disabled(!prefs.showThumbnail)
                    .opacity(prefs.showThumbnail ? 1 : 0.5)
            }
        }
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
        VStack(alignment: .leading, spacing: 28) {
            WindowStylePreview(prefs: prefs)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            SettingsSection("Background") {
                HStack(spacing: 10) {
                    BackgroundOption(title: "Desktop Wallpaper", symbol: "photo", isSelected: prefs.windowBackground == .wallpaper) {
                        prefs.windowBackground = .wallpaper
                    }
                    BackgroundOption(title: "Transparent", symbol: "checkerboard.rectangle", isSelected: prefs.windowBackground == .transparent) {
                        prefs.windowBackground = .transparent
                    }
                }
                .padding(10)
            }

            SettingsSection("Frame") {
                SliderRow(title: "Padding", value: $prefs.windowPadding, range: 0...160, unit: "pt")
                RowDivider()
                SliderRow(title: "Corner radius", value: $prefs.windowCornerRadius, range: 0...30, unit: "pt")
                RowDivider()
                ToggleRow(title: "Drop shadow", isOn: $prefs.windowShadow)
                RowDivider()
                ToggleRow(
                    title: "Minimal title bar",
                    detail: "Swaps the app's own top bar for a thin, plain one with just the traffic lights. The editor can change it, pick the bar's color and cut the window's sides, for each shot.",
                    isOn: $prefs.windowMinimalTitleBar
                )
            }

            SettingsSection {
                ToggleRow(
                    title: "Bring window to front before capturing",
                    detail: "Makes it the active window, so its traffic lights are in color. With Accessibility access the exact window is raised; without it, its app is activated.",
                    isOn: $prefs.bringWindowToFront
                )
            }
        }
    }
}

private struct BackgroundOption: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.accent)
                }
            }
            .foregroundStyle(isSelected ? Brand.accent : Color.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Brand.accent.opacity(0.12) : Color.primary.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}

// MARK: - Recording

private struct RecordingPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var drafts = DraftsLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection {
                SettingsRow("Record Screen", detail: "Drag an area, click for the whole screen, or press Space and pick a window.") {
                    HStack(spacing: 10) {
                        ShortcutBadge(shortcut: prefs.recordShortcut)
                        Button("Start") { RecordingController.shared.toggle() }
                            .buttonStyle(.softProminent)
                    }
                }
                RowDivider()
                ToggleRow(title: "Count down before recording", detail: "3, 2, 1 in the middle of what's being recorded. Esc cancels.", isOn: $prefs.recordingCountdown)
            }

            RecordingAudioSection()

            RecordingCameraSection()

            RecordingKeystrokesSection()

            SettingsSection("Drafts", footer: "Every recording is a draft: edits save as you go. Reopen, rename, duplicate or trash them from the Drafts window.") {
                SettingsRow(drafts.drafts.isEmpty ? "No drafts yet" : "\(drafts.drafts.count) draft\(drafts.drafts.count == 1 ? "" : "s")") {
                    Button("Open Drafts") { DraftsWindowController.shared.show() }
                        .buttonStyle(.soft)
                }
            }

            SettingsSection("In the editor") {
                FeatureRow(symbol: "photo.on.rectangle", title: "Backgrounds", detail: "Wallpaper, gradients, colors or your own image, with padding, corners and shadow.")
                RowDivider()
                FeatureRow(symbol: "cursorarrow.motionlines", title: "Smooth cursor", detail: "Redrawn so it glides, with motion blur and a ripple on clicks.")
                RowDivider()
                FeatureRow(symbol: "plus.magnifyingglass", title: "Auto zoom", detail: "Eases in where you click and follows the pointer.")
                RowDivider()
                FeatureRow(symbol: "scissors", title: "Clips & speed", detail: "Trim, split, cut the sides and change the speed of each clip.")
                RowDivider()
                FeatureRow(symbol: "waveform", title: "Audio", detail: "Microphone and system audio on their own tracks, with volume and mute.")
                RowDivider()
                FeatureRow(symbol: "person.crop.square", title: "Camera bubble", detail: "A circle, a rounded square or a pebble, in any corner, out of the way while zoomed in.")
                RowDivider()
                FeatureRow(symbol: "keyboard", title: "Keystrokes", detail: "The shortcuts you press, on a small glass pill at the bottom of the video.")
            }
        }
        .onAppear { drafts.reload() }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var historyCount = ShelfManager.shared.history.count

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Opening", footer: "Drop screenshots or files on a shelf, then drag them all, or just the selected ones, into a folder, a chat or a browser upload. The thumbnail after a capture has a button that adds it to the shelf.") {
                ToggleRow(title: "Shake to open a shelf", detail: "Shake the pointer while dragging files.", isOn: $prefs.shakeToOpenShelf)
                RowDivider()
                SettingsRow("New shelf") {
                    HStack(spacing: 10) {
                        ShortcutBadge(shortcut: prefs.shelfShortcut)
                        Button("Open") { ShelfManager.shared.newShelf() }
                            .buttonStyle(.soft)
                    }
                }
            }

            SettingsSection("History", footer: "Reopen recent shelves from the menu bar. Shelves only point to your files: clearing the history never deletes them.") {
                SettingsRow(historyCount == 1 ? "1 recent shelf" : "\(historyCount) recent shelves") {
                    Button("Clear History") {
                        ShelfManager.shared.clearHistory()
                        historyCount = ShelfManager.shared.history.count
                    }
                    .buttonStyle(.soft)
                    .disabled(historyCount == 0)
                }
            }
        }
        .onAppear { historyCount = ShelfManager.shared.history.count }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Capture", footer: "While selecting, Space switches between area and window, and Esc cancels.") {
                ShortcutRow(title: "Capture Area", symbol: "rectangle.dashed", shortcut: $prefs.areaShortcut, conflict: hotKeys.conflicts.contains(.area))
                RowDivider()
                ShortcutRow(title: "Capture Window", symbol: "macwindow", shortcut: $prefs.windowShortcut, conflict: hotKeys.conflicts.contains(.window))
                RowDivider()
                ShortcutRow(title: "Capture Text", symbol: "text.viewfinder", shortcut: $prefs.textShortcut, conflict: hotKeys.conflicts.contains(.text))
                RowDivider()
                ShortcutRow(title: "Record Screen", symbol: "record.circle", shortcut: $prefs.recordShortcut, conflict: hotKeys.conflicts.contains(.record))
                RowDivider()
                ShortcutRow(title: "New Shelf", symbol: "tray", shortcut: $prefs.shelfShortcut, conflict: hotKeys.conflicts.contains(.shelf))
            }

            SettingsSection("System Screenshot Shortcuts", footer: "To use ⇧⌘3 or ⇧⌘4 for ScreenOtter, turn off the macOS ones first: select Screenshots in that list and uncheck them.") {
                SettingsRow("macOS keyboard shortcuts") {
                    Button {
                        Permissions.openKeyboardShortcutsSettings()
                    } label: {
                        Label("Open", systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.soft)
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let symbol: String
    @Binding var shortcut: Shortcut?
    let conflict: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if conflict {
                    Text("Already used by another app")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            ShortcutRecorder(shortcut: $shortcut)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
    }
}

/// Microphone and system audio, also offered in the bar at the bottom of the screen when choosing what to record.
private struct RecordingAudioSection: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var microphones: [Microphones.Device] = []
    @State private var denied = Microphones.isDenied

    var body: some View {
        SettingsSection("Audio", footer: "Each source is saved as its own track, so its volume can be changed or muted in the editor.") {
            ToggleRow(title: "Microphone", detail: "Records your voice with the screen.", isOn: Binding(
                get: { prefs.recordMicrophone },
                set: { on in
                    prefs.recordMicrophone = on
                    if on { Task { _ = await Microphones.requestAccess(); denied = Microphones.isDenied } }
                }
            ))
            if prefs.recordMicrophone {
                RowDivider()
                if denied {
                    SettingsRow("Microphone access is off", detail: "Recordings go on without it until it's allowed.") {
                        Button("Open Settings") { Microphones.openPrivacySettings() }
                            .buttonStyle(.soft)
                    }
                } else {
                    SettingsRow("Input") {
                        // A saved microphone that's unplugged shows as System Default, which is what records; it's kept for when it's back.
                        Picker("", selection: Binding(
                            get: { microphones.contains { $0.id == prefs.microphoneID } ? prefs.microphoneID ?? "" : "" },
                            set: { prefs.microphoneID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("System Default").tag("")
                            ForEach(microphones) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            RowDivider()
            ToggleRow(title: "System audio", detail: "Sound from your apps. ScreenOtter's own sounds are left out.", isOn: $prefs.recordSystemAudio)
        }
        .onAppear {
            microphones = Microphones.all()
            denied = Microphones.isDenied
        }
    }
}

/// The camera, also offered in the bar at the bottom of the screen when choosing what to record.
private struct RecordingCameraSection: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var cameras: [Webcams.Device] = []
    @State private var denied = Webcams.isDenied

    var body: some View {
        SettingsSection("Camera", footer: "The camera is saved on its own and shows as a bubble over the video. Shape it, move it or hide it in the editor.") {
            ToggleRow(title: "Camera", detail: "Records you next to the screen, with a live bubble while recording.", isOn: Binding(
                get: { prefs.recordCamera },
                set: { on in
                    prefs.recordCamera = on
                    if on { Task { _ = await Webcams.requestAccess(); denied = Webcams.isDenied } }
                }
            ))
            if prefs.recordCamera {
                RowDivider()
                if denied {
                    SettingsRow("Camera access is off", detail: "Recordings go on without it until it's allowed.") {
                        Button("Open Settings") { Webcams.openPrivacySettings() }
                            .buttonStyle(.soft)
                    }
                } else {
                    SettingsRow("Device") {
                        // A saved camera that's disconnected shows as System Default, which is what records; it's kept for when it's back.
                        Picker("", selection: Binding(
                            get: { cameras.contains { $0.id == prefs.cameraID } ? prefs.cameraID ?? "" : "" },
                            set: { prefs.cameraID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("System Default").tag("")
                            ForEach(cameras) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
        .onAppear {
            cameras = Webcams.all()
            denied = Webcams.isDenied
        }
    }
}

/// The keystroke overlay: off by default, shortcuts only unless all keys are asked for.
private struct RecordingKeystrokesSection: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var granted = KeystrokePermission.isGranted

    var body: some View {
        SettingsSection(
            "Keystrokes",
            footer: "Only shortcuts (keys pressed with ⌘, ⌃ or ⌥) and keys like Return, Esc, Tab and the arrows are kept, unless All keys is on. Nothing is kept while a password field is active."
        ) {
            ToggleRow(title: "Keystrokes", detail: "Records the shortcuts you press, to show them in the video.", isOn: Binding(
                get: { prefs.recordKeystrokes },
                set: { on in
                    prefs.recordKeystrokes = on
                    if on, !KeystrokePermission.isGranted { KeystrokePermission.request() }
                    granted = KeystrokePermission.isGranted
                }
            ))
            if prefs.recordKeystrokes {
                RowDivider()
                if !granted {
                    SettingsRow("Input Monitoring is off", detail: "macOS needs it to show ScreenOtter your key presses. Recordings go on without keys until it's allowed.") {
                        Button("Open Settings") { KeystrokePermission.openSettings() }
                            .buttonStyle(.soft)
                    }
                    RowDivider()
                }
                ToggleRow(title: "All keys", detail: "Also records what you type, not only shortcuts.", isOn: $prefs.recordAllKeys)
            }
        }
        .onAppear { granted = KeystrokePermission.isGranted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = KeystrokePermission.isGranted
        }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @State private var screenRecording = Permissions.screenRecordingGranted
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var inputMonitoring = KeystrokePermission.isGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(footer: "After granting Screen Recording, macOS may ask you to quit and reopen ScreenOtter.") {
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
                RowDivider()
                PermissionRow(
                    title: "Accessibility",
                    detail: "Optional. Raises the exact window you click before a window capture.",
                    symbol: "accessibility",
                    tint: Brand.accent,
                    granted: accessibility,
                    action: Permissions.requestAccessibility
                )
                RowDivider()
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Optional. Shows the shortcuts you press in recordings, when Keystrokes is on.",
                    symbol: "keyboard",
                    tint: .orange,
                    granted: inputMonitoring,
                    action: {
                        if !KeystrokePermission.request() { KeystrokePermission.openSettings() }
                    }
                )
            }
        }
        .onReceive(timer) { _ in
            screenRecording = Permissions.screenRecordingGranted
            accessibility = Permissions.accessibilityGranted
            inputMonitoring = KeystrokePermission.isGranted
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
        HStack(spacing: 14) {
            SettingsIcon(symbol: symbol, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Granted", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.green.opacity(0.13)))
            } else {
                Button("Grant Access…", action: action)
                    .buttonStyle(.softProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // The otter and the sky above it; the water and the name sit below.
            GeometryReader { geo in
                Group {
                    if let illustration = Brand.illustration {
                        Image(nsImage: illustration)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width)
                            .offset(y: -geo.size.width * 0.06)
                    } else {
                        LinearGradient(colors: [Brand.accent, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 14, y: 6)

            HStack(spacing: 14) {
                AppIconImage(size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Brand.name)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Version \(Brand.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Text("A sea otter keeps a favorite stone tucked under its arm, always within reach. ScreenOtter does the same for what you capture.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSection("What it keeps") {
                FeatureRow(symbol: "camera.viewfinder", title: "Screenshots", detail: "Areas and windows, styled on your wallpaper, straight to the clipboard and a folder.")
                RowDivider()
                FeatureRow(symbol: "record.circle", title: "Recordings", detail: "Polished screen recordings with a smooth cursor, auto zoom and drafts.")
                RowDivider()
                FeatureRow(symbol: "tray.2", title: "Shelves", detail: "A floating spot for files on their way somewhere else.")
            }
        }
    }
}
