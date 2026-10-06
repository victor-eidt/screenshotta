import SwiftUI

struct EditorActions {
    var delete: () -> Void
    var copy: () -> Void
    var saveAs: () -> Void
    var showInFinder: () -> Void
}

struct EditorView: View {
    @ObservedObject var doc: EditorDocument
    let actions: EditorActions
    @State private var copied = false

    static let barHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            CanvasRepresentable(doc: doc)
            Divider()
            bottomBar
        }
        .ignoresSafeArea()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 76, height: 1) // traffic lights
            AppIconImage(size: 20)
                .padding(.trailing, 4)
                .help(Brand.name)

            BarButton(symbol: "trash", help: "Delete screenshot", action: actions.delete)
            BarButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: doc.undo)
                .disabled(!doc.canUndo)
            BarButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: doc.redo)
                .disabled(!doc.canRedo)

            Spacer(minLength: 12)

            ToolGroup {
                ToolButton(tool: .crop, selection: $doc.tool)
                if let shot = doc.windowShot {
                    WindowFrameButton(doc: doc, shot: shot)
                }
            }
            ToolGroup {
                ForEach(EditorTool.drawing) { tool in
                    ToolButton(tool: tool, selection: $doc.tool)
                }
            }
            ToolGroup {
                ColorSwatches(selection: $doc.color)
            }
            ToolGroup {
                ForEach(StrokeSize.allCases) { size in
                    StrokeButton(size: size, selection: $doc.stroke)
                }
            }
        }
        .padding(.trailing, 14)
        .frame(height: Self.barHeight)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text("\(Int((doc.zoom * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .leading)
            Text(infoText)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            if doc.tool == .crop {
                Button("Cancel") { doc.cancelCrop() }
                Button {
                    doc.applyCrop()
                    doc.tool = .arrow
                } label: {
                    Label("Apply Crop", systemImage: "checkmark")
                }
                .keyboardShortcut(.return, modifiers: [])
                Spacer()
            }

            if doc.fileURL != nil {
                Button(action: actions.showInFinder) {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
            Button(action: actions.saveAs) {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)

            Button {
                actions.copy()
                withAnimation(.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.snappy) { copied = false }
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 64)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: Self.barHeight)
    }

    private var infoText: String {
        let size = doc.tool == .crop ? (doc.pendingCrop ?? doc.crop).size : doc.crop.size
        var parts = ["\(Int(size.width))×\(Int(size.height))"]
        if let fileSize = doc.fileSizeDescription { parts.append(fileSize) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pieces

private struct CanvasRepresentable: NSViewRepresentable {
    let doc: EditorDocument

    func makeNSView(context: Context) -> EditorCanvasView {
        EditorCanvasView(document: doc)
    }

    func updateNSView(_ view: EditorCanvasView, context: Context) {
        view.needsDisplay = true
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct ToolGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    @Binding var selection: EditorTool

    var body: some View {
        let selected = selection == tool
        Button { selection = tool } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .frame(width: 30, height: 30)
                .foregroundStyle(selected ? Brand.accent : Color.primary.opacity(0.8))
                .background(Circle().fill(selected ? Brand.accent.opacity(0.2) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tool.help)
    }
}

/// Window shots: the window's frame, as in window recordings.
private struct WindowFrameButton: View {
    @ObservedObject var doc: EditorDocument
    let shot: WindowShot
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "macwindow")
                .font(.system(size: 14, weight: isShown ? .semibold : .regular))
                .frame(width: 30, height: 30)
                .foregroundStyle(isShown ? Brand.accent : Color.primary.opacity(0.8))
                .background(Circle().fill(isShown ? Brand.accent.opacity(0.2) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Window frame")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            WindowFramePanel(doc: doc, shot: shot)
        }
    }
}

private struct WindowFramePanel: View {
    @ObservedObject var doc: EditorDocument
    let shot: WindowShot

    var body: some View {
        let minimal = doc.windowFrame?.minimalTitleBar ?? false
        VStack(alignment: .leading, spacing: 22) {
            InspectorToggle(
                title: "Minimal title bar",
                detail: "Swaps the app's own top bar for a thin, plain one with just the traffic lights, so every window looks alike.",
                isOn: Binding(get: { minimal }, set: { on in change { $0.minimalTitleBar = on } })
            )
            InspectorBarColor(color: doc.windowFrame?.barColor, sampled: doc.windowFrame.flatMap(shot.sampledBarColor)) { [weak doc] color, continuing in
                guard let doc, var frame = doc.windowFrame else { return }
                frame.barColor = color
                if !continuing { doc.checkpoint() }
                doc.setWindowFrame(frame)
            }
            .disabled(!minimal)
            InspectorSection("Cut") {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSlider(
                        title: "Top", value: cut(\.top), range: 0...min(160, (shot.frameInDisplay.height / 2).rounded()),
                        format: Self.points, onEditing: editing
                    )
                    .disabled(!minimal)
                    InspectorSlider(title: "Left", value: cut(\.left), range: 0...shot.maximumSideCut, format: Self.points, onEditing: editing)
                    InspectorSlider(title: "Right", value: cut(\.right), range: 0...shot.maximumSideCut, format: Self.points, onEditing: editing)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(18)
        .frame(width: 300)
    }

    private static func points(_ value: Double) -> String { "\(Int(value)) pt" }

    /// One undo step per toggle.
    private func change(_ edit: (inout WindowFrame) -> Void) {
        guard var frame = doc.windowFrame else { return }
        edit(&frame)
        doc.checkpoint()
        doc.setWindowFrame(frame)
    }

    /// Sliders: one undo step per drag, taken when it begins.
    private func cut(_ keyPath: WritableKeyPath<WindowFrame, Double>) -> Binding<Double> {
        Binding(
            get: { doc.windowFrame?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard var frame = doc.windowFrame else { return }
                frame[keyPath: keyPath] = value.rounded()
                doc.setWindowFrame(frame)
            }
        )
    }

    private func editing(_ began: Bool) {
        if began { doc.checkpoint() }
    }
}

private struct ColorSwatches: View {
    @Binding var selection: NSColor

    var body: some View {
        ForEach(Array(AnnotationPalette.colors.enumerated()), id: \.offset) { _, color in
            let selected = selection == color
            Button { selection = color } label: {
                Circle()
                    .fill(Color(nsColor: color))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 16, height: 16)
                    .padding(3)
                    .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.85) : .clear, lineWidth: 1.5))
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StrokeButton: View {
    let size: StrokeSize
    @Binding var selection: StrokeSize

    var body: some View {
        let selected = selection == size
        Button { selection = size } label: {
            Capsule()
                .fill(selected ? Brand.accent : Color.primary.opacity(0.7))
                .frame(width: 16, height: size.points * 0.9)
                .frame(width: 28, height: 30)
                .background(Circle().fill(selected ? Brand.accent.opacity(0.2) : .clear).frame(width: 30, height: 30))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stroke width")
    }
}
