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
                    case .captions: CaptionPanel(doc: doc)
                    case .webcam: WebcamPanel(doc: doc)
                    case .keystrokes: KeystrokePanel(doc: doc)
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

extension RecordingDocument {
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
                InspectorBarColor(color: style.windowBarColor, sampled: doc.sampledWindowBarColor) { [weak doc] color, continuing in
                    doc?.update(continuing: continuing) { $0.style.windowBarColor = color }
                }
                .disabled(!style.minimalWindowFrame)
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
                    SegmentedPills(
                        options: ZoomFocusMode.allCases,
                        selection: Binding(
                            get: { zoom.focus == nil ? .pointer : .spot },
                            set: { mode in
                                doc.setZoomFocus(id, mode == .spot ? doc.initialZoomFocus(zoom) : nil)
                                doc.showZoom(zoom)
                            }
                        ),
                        title: \.title
                    )
                    if let focus = zoom.focus {
                        ZoomSpotPicker(doc: doc, zoom: zoom, focus: focus)
                        Text("Drag the frame, or click where the zoom should look.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

private enum ZoomFocusMode: CaseIterable {
    case pointer, spot

    var title: String {
        switch self {
        case .pointer: "Follow pointer"
        case .spot: "Fixed spot"
        }
    }
}

/// A frame of the recording with the zoomed-in view drawn on it, to drag where the zoom should look.
private struct ZoomSpotPicker: View {
    @ObservedObject var doc: RecordingDocument
    let zoom: ZoomSegment
    let focus: CGPoint
    @State private var frame: CGImage?

    var body: some View {
        let aspect = frame.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16 / 10
        let view = doc.zoomViewSize(scale: zoom.scale)
        GeometryReader { proxy in
            let size = proxy.size
            let box = CGSize(width: view.width * size.width, height: view.height * size.height)
            let center = CGPoint(x: clamped(focus.x, view.width) * size.width, y: clamped(focus.y, view.height) * size.height)
            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable()
                } else {
                    Color.white.opacity(0.05)
                }
                // Dim what the zoom leaves out.
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .reverseMask {
                        Rectangle().frame(width: box.width, height: box.height).position(center)
                    }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .frame(width: box.width, height: box.height)
                    .position(center)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        doc.beginInteraction()
                        let x = clamped(value.location.x / max(size.width, 1), view.width)
                        let y = clamped(value.location.y / max(size.height, 1), view.height)
                        doc.setZoomFocus(zoom.id, CGPoint(x: x, y: y))
                    }
                    .onEnded { _ in doc.endInteraction() }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .task(id: zoom.start) { frame = await doc.zoomFrame(zoom) }
        .accessibilityElement()
        .accessibilityLabel("Zoom spot")
    }

    /// Keeps the view inside the recording.
    private func clamped(_ v: CGFloat, _ extent: CGFloat) -> CGFloat {
        let half = extent / 2
        return half >= 0.5 ? 0.5 : min(max(v, half), 1 - half)
    }
}

private extension View {
    /// Cuts `mask` out of the view.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle().overlay(alignment: .topLeading) { mask().blendMode(.destinationOut) }.compositingGroup()
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

// MARK: - Camera

private struct WebcamPanel: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if doc.hasWebcam {
                let style = doc.edits.style.webcam
                InspectorToggle(
                    title: "Show camera",
                    detail: doc.webcamDeviceName,
                    isOn: Binding(get: { doc.showsWebcam }, set: { doc.setWebcamVisible($0) })
                )
                Group {
                    InspectorSection("Shape") {
                        HStack(spacing: 8) {
                            ForEach(WebcamShape.allCases) { shape in
                                WebcamShapeTile(shape: shape, selected: style.shape == shape) {
                                    doc.update { $0.style.webcam.shape = shape }
                                }
                            }
                        }
                    }
                    InspectorSection("Size") {
                        SegmentedPills(options: WebcamSize.allCases, selection: doc.style(\.webcam.size), title: \.title, name: \.name)
                    }
                    InspectorSection("Position") {
                        HStack(alignment: .center, spacing: 14) {
                            WebcamCornerPicker(style: style) { corner in
                                doc.update { $0.style.webcam.x = corner.position.x; $0.style.webcam.y = corner.position.y }
                            }
                            Text("Or drag the bubble in the preview.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    InspectorSection("While zoomed in") {
                        SegmentedPills(options: WebcamZoomBehavior.allCases, selection: doc.style(\.webcam.duringZoom), title: \.title)
                    }
                    InspectorToggle(
                        title: "Mirror",
                        detail: "Shows you the way you saw yourself while recording.",
                        isOn: doc.style(\.webcam.mirror)
                    )
                    InspectorToggle(
                        title: "Border",
                        detail: "A fine light ring around the edge.",
                        isOn: doc.style(\.webcam.border)
                    )
                    InspectorToggle(
                        title: "Shadow",
                        isOn: doc.style(\.webcam.shadow)
                    )
                }
                .disabled(!doc.showsWebcam)
                .opacity(doc.showsWebcam ? 1 : 0.5)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No camera in this recording")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Turn on the camera in the bar at the bottom of the screen when you choose what to record, or in Settings › Recording. It's recorded on its own and shows here as a bubble you can shape and move.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A webcam shape as a SwiftUI shape, from the same outline the renderer draws.
struct WebcamShapeOutline: Shape {
    let shape: WebcamShape

    func path(in rect: CGRect) -> Path {
        Path(shape.path(in: rect))
    }
}

private struct WebcamShapeTile: View {
    let shape: WebcamShape
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .bottom) {
                    WebcamShapeOutline(shape: shape)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(selected ? 0.32 : 0.2), Color.white.opacity(selected ? 0.16 : 0.08)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    Image(systemName: "person.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(Color.white.opacity(selected ? 0.9 : 0.55))
                        .offset(y: 5)
                }
                .frame(width: 34 * shape.aspect, height: 34)
                .clipShape(WebcamShapeOutline(shape: shape))
                .overlay(WebcamShapeOutline(shape: shape).stroke(Color.white.opacity(0.25), lineWidth: 1))
                .frame(height: 38)
                Text(shape.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Brand.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shape.title)
        .accessibilityLabel(shape.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row of equal pills, one selected: the inspector's segmented control. `name` is the full name for
/// VoiceOver and the tooltip, when `title` is only an abbreviation.
struct SegmentedPills<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: KeyPath<Option, String>
    var name: KeyPath<Option, String>?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Brand.accent : Color.white.opacity(0.07)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name.map { option[keyPath: $0] } ?? "")
                .accessibilityLabel(option[keyPath: name ?? title])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A small frame with a target in each corner; the bubble's corner is filled.
private struct WebcamCornerPicker: View {
    let style: WebcamStyle
    let onSelect: (WebcamCorner) -> Void

    var body: some View {
        let current = WebcamLayout.corner(of: style)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            ForEach(WebcamCorner.allCases) { corner in
                let selected = corner == current
                Button { onSelect(corner) } label: {
                    WebcamShapeOutline(shape: style.shape)
                        .fill(selected ? Brand.accent : Color.white.opacity(0.18))
                        .frame(width: 16 * style.shape.aspect, height: 16)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(corner.title)
                .accessibilityLabel(corner.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            }
        }
        .frame(width: 96, height: 60)
        .animation(.snappy(duration: 0.18), value: current)
    }
}

private extension WebcamCorner {
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

// MARK: - Controls

struct InspectorSection<Content: View>: View {
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

struct InspectorToggle: View {
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

struct InspectorSlider: View {
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

/// The minimal title bar's color, in both editors: Auto (whatever is right under the bar), a window neutral,
/// or any color from the color panel.
struct InspectorBarColor: View {
    /// 0xRRGGBB, or nil for Auto.
    let color: UInt32?
    /// What Auto picks.
    let sampled: CGColor?
    /// The color panel sends a stream of changes while it's used: after the first, `continuing` is true,
    /// so they can share one undo step.
    let onChange: (_ color: UInt32?, _ continuing: Bool) -> Void

    private static let neutrals: [(hex: UInt32, name: String)] = [
        (0xFFFFFF, "White"), (0xECECEC, "Light gray"), (0x2B2B2D, "Dark gray"), (0x141416, "Black"),
    ]

    var body: some View {
        let custom = color.flatMap { hex in Self.neutrals.contains { $0.hex == hex } ? nil : hex }
        VStack(alignment: .leading, spacing: 8) {
            Text("Bar color")
            HStack(spacing: 4) {
                Dot(fill: AnyShapeStyle(sampled.map { Color(cgColor: $0) } ?? Color.gray), selected: color == nil, help: "Auto: the color right under the bar") {
                    onChange(nil, false)
                }
                .overlay {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .allowsHitTesting(false)
                }
                ForEach(Self.neutrals, id: \.hex) { neutral in
                    Dot(fill: AnyShapeStyle(Color(cgColor: BackgroundArt.cgColor(neutral.hex))), selected: color == neutral.hex, help: neutral.name) {
                        onChange(neutral.hex, false)
                    }
                }
                Dot(
                    fill: custom.map { AnyShapeStyle(Color(cgColor: BackgroundArt.cgColor($0))) }
                        ?? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)),
                    selected: custom != nil,
                    help: "Any color…"
                ) {
                    var continuing = false
                    let start = custom.flatMap { NSColor(cgColor: BackgroundArt.cgColor($0)) } ?? sampled.flatMap(NSColor.init(cgColor:)) ?? .white
                    ColorPanelLink.shared.open(with: start) { picked in
                        onChange(Self.hex(picked), continuing)
                        continuing = true
                    }
                }
            }
        }
    }

    private static func hex(_ color: NSColor) -> UInt32 {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(srgb.redComponent) << 16 | byte(srgb.greenComponent) << 8 | byte(srgb.blueComponent)
    }

    private struct Dot: View {
        let fill: AnyShapeStyle
        let selected: Bool
        let help: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Circle()
                    .fill(fill)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                    .frame(width: 22, height: 22)
                    .padding(3)
                    .overlay(Circle().strokeBorder(selected ? Brand.accent : .clear, lineWidth: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

/// The system color panel, opened for one color at a time. It sends its changes here rather than to a view,
/// since the popover it may be opened from closes as soon as the panel is clicked.
final class ColorPanelLink: NSObject {
    static let shared = ColorPanelLink()
    private var onChange: ((NSColor) -> Void)?

    func open(with color: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        // Setting the starting color sends it back as a change: not one of the user's.
        self.onChange = nil
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = color
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        onChange?(panel.color)
    }
}
