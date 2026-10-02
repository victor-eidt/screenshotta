import SwiftUI
import UniformTypeIdentifiers

struct RecordingInspector: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(RecordingInspectorTab.allCases) { tab in
                    let selected = doc.inspector == tab
                    Button { doc.inspector = tab } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: selected ? .semibold : .regular))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(selected ? Brand.accent : Color.secondary)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Brand.accent.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
                Spacer()
            }
            .padding(.top, 10)
            .frame(width: 50)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(doc.inspector.title)
                        .font(.system(size: 15, weight: .semibold))
                    switch doc.inspector {
                    case .background: BackgroundPanel(doc: doc)
                    case .cursor: CursorPanel(doc: doc)
                    case .zoom: ZoomPanel(doc: doc)
                    case .clip: ClipPanel(doc: doc)
                    case .audio: AudioPanel(doc: doc)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RecordingTheme.panel))
        }
        .font(.system(size: 12.5))
    }
}

// MARK: - Bindings

private extension RecordingDocument {
    /// A binding to one style option. Changes made while a slider is held count as one undo step.
    func style<T>(_ keyPath: WritableKeyPath<RecordingStyle, T>) -> Binding<T> {
        Binding(
            get: { self.edits.style[keyPath: keyPath] },
            set: { value in self.update { $0.style[keyPath: keyPath] = value } }
        )
    }

    func sliderEditing(_ editing: Bool) {
        if editing { beginInteraction() } else { endInteraction() }
    }
}

// MARK: - Background

private struct BackgroundPanel: View {
    @ObservedObject var doc: RecordingDocument

    private let columns = Array(repeating: GridItem(.fixed(49), spacing: 6), count: 4)

    var body: some View {
        let style = doc.edits.style
        VStack(alignment: .leading, spacing: 22) {
            if doc.isWindowRecording {
                InspectorToggle(
                    title: "Minimal title bar",
                    detail: "Swaps the app's own top bar for a thin, plain one with just the traffic lights, so every window looks alike.",
                    isOn: doc.style(\.minimalWindowFrame)
                )
            }
            InspectorSection("Cut") {
                VStack(alignment: .leading, spacing: 14) {
                    if doc.isWindowRecording {
                        InspectorSlider(
                            title: "Top",
                            value: Binding(get: { doc.edits.windowTopTrim ?? 0 }, set: { value in doc.update { $0.windowTopTrim = value.rounded() } }),
                            range: 0...160,
                            format: { "\(Int($0)) pt" },
                            onEditing: doc.sliderEditing
                        )
                        .disabled(!style.minimalWindowFrame)
                    }
                    InspectorSlider(
                        title: "Left",
                        value: Binding(get: { doc.edits.cutLeft ?? 0 }, set: { value in doc.update { $0.cutLeft = value.rounded() } }),
                        range: 0...doc.maximumSideCut,
                        format: { "\(Int($0)) pt" },
                        onEditing: doc.sliderEditing
                    )
                    InspectorSlider(
                        title: "Right",
                        value: Binding(get: { doc.edits.cutRight ?? 0 }, set: { value in doc.update { $0.cutRight = value.rounded() } }),
                        range: 0...doc.maximumSideCut,
                        format: { "\(Int($0)) pt" },
                        onEditing: doc.sliderEditing
                    )
                }
            }

            InspectorSection("Wallpaper & Gradients") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    if let wallpaper = doc.wallpaper {
                        Swatch(selected: style.background == .wallpaper, help: "Desktop wallpaper") {
                            Image(decorative: wallpaper, scale: 1).resizable().scaledToFill()
                        } action: { select(.wallpaper) }
                    }
                    ForEach(BackgroundArt.gradients.indices, id: \.self) { index in
                        Swatch(selected: style.background == .gradient(index), help: "Gradient") {
                            if let image = BackgroundSwatches.gradient(index) {
                                Image(decorative: image, scale: 1).resizable()
                            }
                        } action: { select(.gradient(index)) }
                    }
                    if case let .image(path) = style.background, let image = BackgroundSwatches.image(path) {
                        Swatch(selected: true, help: URL(fileURLWithPath: path).lastPathComponent) {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } action: {}
                    }
                    Swatch(selected: false, help: "Choose an image…") {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.06))
                    } action: { chooseImage() }
                }
            }

            InspectorSection("Colors") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(BackgroundArt.colors.indices, id: \.self) { index in
                        Swatch(selected: style.background == .color(index), help: "Solid color") {
                            Color(cgColor: BackgroundArt.color(index))
                        } action: { select(.color(index)) }
                    }
                }
            }

            InspectorSlider(title: "Padding", value: doc.style(\.padding), range: 0...0.3, format: { "\(Int(($0 * 100).rounded()))%" }, onEditing: doc.sliderEditing)
            InspectorSlider(title: "Corner radius", value: doc.style(\.cornerRadius), range: 0...40, format: { "\(Int($0.rounded())) pt" }, onEditing: doc.sliderEditing)
            InspectorSlider(title: "Shadow", value: doc.style(\.shadow), range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }, onEditing: doc.sliderEditing)
            InspectorSlider(title: "Background blur", value: doc.style(\.backgroundBlur), range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }, onEditing: doc.sliderEditing)
                .disabled(!style.background.isPicture)
        }
    }

    private func select(_ background: RecordingBackground) {
        doc.update { $0.style.background = background }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(.image(url.path))
    }
}

private extension RecordingBackground {
    var isPicture: Bool {
        switch self {
        case .wallpaper, .image: true
        case .gradient, .color: false
        }
    }
}

/// Small previews for the background grid, drawn once.
private enum BackgroundSwatches {
    private static var gradients: [Int: CGImage] = [:]
    private static var images: [String: CGImage] = [:]

    static func gradient(_ index: Int) -> CGImage? {
        if let cached = gradients[index] { return cached }
        let image = BackgroundArt.gradient(index, size: CGSize(width: 88, height: 60))
        gradients[index] = image
        return image
    }

    static func image(_ path: String) -> CGImage? {
        if let cached = images[path] { return cached }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 120] as CFDictionary
        let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
        images[path] = image
        return image
    }
}

private struct Swatch<Content: View>: View {
    let selected: Bool
    let help: String
    @ViewBuilder let content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 44, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .padding(2.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Brand.accent : .clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Cursor

private struct CursorPanel: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        let style = doc.edits.style
        VStack(alignment: .leading, spacing: 22) {
            InspectorToggle(title: "Show cursor", isOn: doc.style(\.showCursor))

            Group {
                InspectorToggle(
                    title: "Smooth movement",
                    detail: "Glides between positions instead of following every twitch of the mouse.",
                    isOn: doc.style(\.smoothCursor)
                )
                InspectorSlider(title: "Size", value: doc.style(\.cursorSize), range: 0.5...3, format: { String(format: "%.1f×", $0) }, onEditing: doc.sliderEditing)

                InspectorSection("Style") {
                    HStack(spacing: 8) {
                        ForEach(CursorStyle.allCases) { cursorStyle in
                            let selected = style.cursorStyle == cursorStyle
                            Button { doc.update { $0.style.cursorStyle = cursorStyle } } label: {
                                Group {
                                    if let art = CursorArt.image(cursorStyle, height: 44) {
                                        Image(decorative: art.image, scale: 2)
                                    }
                                }
                                .frame(width: 54, height: 46)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(selected ? 0.14 : 0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Brand.accent : .clear, lineWidth: 2))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                InspectorToggle(title: "Motion blur", detail: "Blurs the pointer along fast movements.", isOn: doc.style(\.cursorMotionBlur))
                InspectorToggle(title: "Click effect", detail: "A ripple where you click.", isOn: doc.style(\.clickEffect))
                InspectorToggle(title: "Hide when not moving", isOn: doc.style(\.hideIdleCursor))
            }
            .disabled(!style.showCursor)
        }
    }
}

// MARK: - Zoom

private struct ZoomPanel: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        let style = doc.edits.style
        VStack(alignment: .leading, spacing: 22) {
            InspectorToggle(
                title: "Auto zoom on clicks",
                detail: "Zooms in where you click and follows the pointer, then zooms back out.",
                isOn: Binding(get: { style.autoZoom }, set: { doc.setAutoZoom($0) })
            )
            InspectorSlider(
                title: "Zoom level",
                value: Binding(get: { style.zoomScale }, set: { doc.setDefaultZoomScale($0) }),
                range: 1.25...4,
                format: { String(format: "%.1f×", $0) },
                onEditing: doc.sliderEditing
            )

            if case let .zoom(id) = doc.selection, let index = doc.edits.zooms.firstIndex(where: { $0.id == id }) {
                let zoom = doc.edits.zooms[index]
                VStack(alignment: .leading, spacing: 14) {
                    Text("Selected Zoom").font(.system(size: 12.5, weight: .semibold))
                    InspectorSlider(
                        title: "Zoom",
                        value: Binding(
                            get: { zoom.scale },
                            set: { scale in doc.update { $0.zooms[index].scale = scale } }
                        ),
                        range: 1.25...4,
                        format: { String(format: "%.1f×", $0) },
                        onEditing: doc.sliderEditing
                    )
                    Text("\(RecordingFormat.duration(zoom.end - zoom.start))\(zoom.isAuto ? " · from clicks" : "")")
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) { doc.deleteZoom(id) } label: {
                        Label("Delete Zoom", systemImage: "trash")
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            }

            Text("Click or drag on the zoom track below to add a zoom. Drag a zoom to move it, or its ends to resize it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Clip

private struct ClipPanel: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let index = doc.activeSegmentIndex {
                let segment = doc.edits.segments[index]
                InspectorSection("Speed") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(SpeedMenu.options, id: \.self) { speed in
                            let selected = segment.speed == speed
                            Button { doc.setSpeed(speed, for: index) } label: {
                                Text(RecordingFormat.speed(speed))
                                    .font(.system(size: 12, weight: .semibold))
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Brand.accent : Color.white.opacity(0.07)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Clip \(index + 1) of \(doc.edits.segments.count) · \(RecordingFormat.duration(segment.outputDuration)) in the video, \(RecordingFormat.duration(segment.end - segment.start)) recorded")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button { doc.splitAtPlayhead() } label: {
                        Label("Split at Playhead", systemImage: "scissors")
                    }
                    Button(role: .destructive) { doc.deleteSegment(segment.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(doc.edits.segments.count < 2)
                }
            }

            Text("Drag the ends of a clip on the timeline to trim it. Split with S or the scissors, then delete the part you don't want or change its speed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Audio

private struct AudioPanel: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if doc.audioTracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No audio in this recording")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Turn on the microphone or system audio in the bar at the bottom of the screen when you choose what to record, or in Settings › Recording.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(doc.audioTracks, id: \.source) { track in
                    AudioTrackRow(doc: doc, track: track)
                }
                Text("Sound follows your trims, cuts and speed changes, and voices keep their pitch when a clip is sped up.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AudioTrackRow: View {
    @ObservedObject var doc: RecordingDocument
    let track: RecordedAudioTrack

    var body: some View {
        let mix = doc.audioMix(for: track.source)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: track.source.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mix.isMuted ? Color.secondary : Color.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(mix.isMuted ? Color.white.opacity(0.08) : Brand.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.source.title).font(.system(size: 12.5, weight: .semibold))
                    if let name = track.deviceName {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                Button {
                    doc.setAudioMix(track.source) { $0.isMuted.toggle() }
                } label: {
                    Image(systemName: mix.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mix.isMuted ? Color.orange : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(mix.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(mix.isMuted ? "Unmute \(track.source.title)" : "Mute \(track.source.title)")
            }
            InspectorSlider(
                title: "Volume",
                value: Binding(get: { mix.volume }, set: { volume in doc.setAudioMix(track.source) { $0.volume = volume; $0.isMuted = false } }),
                range: 0...1,
                format: { "\(Int(($0 * 100).rounded()))%" },
                onEditing: doc.sliderEditing
            )
            .opacity(mix.isMuted ? 0.45 : 1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Controls

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            content
        }
    }
}

private struct InspectorToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

private struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onEditing: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, onEditingChanged: onEditing)
                .controlSize(.small)
        }
    }
}
