import AVFoundation
import SwiftUI

struct RecordingEditorActions {
    var delete: () -> Void
    var showDrafts: () -> Void
    var showInFinder: (URL) -> Void
    var addToShelf: (URL) -> Void
}

enum RecordingTheme {
    static let background = Color(white: 0.075)
    static let panel = Color(white: 0.115)
    static let raised = Color(white: 0.16)
    static let hairline = Color.white.opacity(0.08)
    static let clip = LinearGradient(colors: [Color(red: 0.93, green: 0.65, blue: 0.24), Color(red: 0.80, green: 0.50, blue: 0.13)], startPoint: .top, endPoint: .bottom)
    static let zoom = LinearGradient(colors: [Color(red: 0.47, green: 0.40, blue: 0.98), Color(red: 0.36, green: 0.29, blue: 0.86)], startPoint: .top, endPoint: .bottom)
}

struct RecordingEditorView: View {
    @ObservedObject var doc: RecordingDocument
    let actions: RecordingEditorActions

    static let barHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            RecordingTopBar(doc: doc, actions: actions)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewToolbar(doc: doc)
                    PlayerSurface(player: doc.player)
                        .aspectRatio(doc.previewSize, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 28)
                        .contentShape(Rectangle())
                        .onTapGesture { doc.togglePlayback() }
                    TransportBar(doc: doc)
                }
                RecordingInspector(doc: doc)
                    .frame(width: 318)
                    .padding([.trailing, .bottom], 12)
            }
            RecordingTimelineView(doc: doc)
                .frame(height: 184)
        }
        .background(RecordingTheme.background)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Top bar

private struct RecordingTopBar: View {
    @ObservedObject var doc: RecordingDocument
    let actions: RecordingEditorActions
    @State private var showExport = false

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 76, height: 1) // traffic lights
            IconButton(symbol: "film.stack", help: "All drafts", action: actions.showDrafts)
            IconButton(symbol: "trash", help: "Delete recording", action: actions.delete)
            IconButton(symbol: "folder", help: "Show raw recording in Finder") { actions.showInFinder(doc.project.videoURL) }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Text(doc.metadata.title)
                    .foregroundStyle(.primary)
                Text(RecordingFormat.duration(doc.duration))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)

            Spacer(minLength: 12)

            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: doc.undo)
                .disabled(!doc.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: doc.redo)
                .disabled(!doc.canRedo)

            Button {
                showExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.leading, 8)
            .popover(isPresented: $showExport, arrowEdge: .bottom) {
                ExportPopover(doc: doc, actions: actions)
            }
            .onChange(of: doc.export) { _, state in
                if case .exporting = state { showExport = true }
            }
        }
        .padding(.trailing, 14)
        .frame(height: RecordingEditorView.barHeight)
        .overlay(alignment: .bottom) { RecordingTheme.hairline.frame(height: 1) }
    }
}

private struct ExportPopover: View {
    @ObservedObject var doc: RecordingDocument
    let actions: RecordingEditorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch doc.export {
            case .idle, .failed:
                Text("Export Video").font(.headline)
                Picker("Resolution", selection: $doc.exportSize) {
                    ForEach(ExportSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                let size = doc.exportPixelSize(doc.exportSize)
                Text(verbatim: "MP4 · \(Int(size.width)) × \(Int(size.height)) · 60 fps · \(RecordingFormat.duration(doc.duration))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if case let .failed(message) = doc.export {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Button {
                    doc.startExport()
                } label: {
                    Text("Export to \(Preferences.shared.saveFolder.lastPathComponent)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            case let .exporting(progress):
                Text("Exporting…").font(.headline)
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

            case let .done(url):
                Label("Exported", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(url.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button("Show in Finder") { actions.showInFinder(url) }
                    Button("Copy") { doc.copyFile(url) }
                    Button("Add to Shelf") { actions.addToShelf(url) }
                }
                Button("Export Again…") { doc.resetExport() }
                    .buttonStyle(.link)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

// MARK: - Preview

private struct PreviewToolbar: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Aspect Ratio", selection: Binding(
                    get: { doc.edits.style.aspect },
                    set: { aspect in doc.update { $0.style.aspect = aspect } }
                )) {
                    ForEach(RecordingAspect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(doc.edits.style.aspect.title, systemImage: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Aspect ratio")

            Spacer()

            let size = doc.exportPixelSize(doc.exportSize)
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 28)
        .frame(height: 44)
    }
}

/// Shows the player's output through an AVPlayerLayer.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @ObservedObject var doc: RecordingDocument

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "scissors", help: "Split clip at playhead (S)", action: doc.splitAtPlayhead)
                .padding(.leading, 16)

            Spacer()

            HStack(spacing: 18) {
                Text(RecordingFormat.timecode(doc.currentTime))
                    .frame(width: 64, alignment: .trailing)
                IconButton(symbol: "backward.end.fill", help: "Go to start") { doc.seek(to: 0) }
                Button(action: doc.togglePlayback) {
                    Image(systemName: doc.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                IconButton(symbol: "forward.end.fill", help: "Go to end") { doc.seek(to: doc.duration) }
                Text(RecordingFormat.timecode(doc.duration))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
            }
            .font(.system(size: 12.5, weight: .medium))
            .monospacedDigit()

            Spacer()

            if let index = doc.activeSegmentIndex {
                SpeedMenu(speed: doc.edits.segments[index].speed) { doc.setSpeed($0, for: index) }
            }
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $doc.timelineZoom, in: 1...12)
                    .controlSize(.mini)
                    .frame(width: 90)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.leading, 14)
            .padding(.trailing, 20)
            .help("Timeline zoom")
        }
        .frame(height: 56)
    }
}

struct SpeedMenu: View {
    let speed: Double
    let onChange: (Double) -> Void

    static let options: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.self) { option in
                Button {
                    onChange(option)
                } label: {
                    if option == speed { Label(RecordingFormat.speed(option), systemImage: "checkmark") } else { Text(RecordingFormat.speed(option)) }
                }
            }
        } label: {
            Text(RecordingFormat.speed(speed))
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Speed of this clip")
    }
}

// MARK: - Pieces

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

enum RecordingFormat {
    /// 1:05.32
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    /// 1:05, or 12.4s under a minute.
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func speed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : "\(String(format: "%g", value))×"
    }
}
