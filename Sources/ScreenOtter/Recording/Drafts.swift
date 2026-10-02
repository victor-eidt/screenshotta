import AppKit
import AVFoundation
import SwiftUI

/// A recording with its edits, as listed in the Drafts window.
struct RecordingDraft: Identifiable {
    let project: RecordingProject
    var metadata: RecordingMetadata
    var edited: Date
    /// Length of the edited video.
    var length: Double

    var id: URL { project.folder }
}

/// Every recording on disk. Edits save as you go, so each one is a draft that can be picked up again.
final class DraftsLibrary: ObservableObject {
    static let shared = DraftsLibrary()

    @Published private(set) var drafts: [RecordingDraft] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private var loadingThumbnails: Set<URL> = []

    func reload() {
        drafts = RecordingProject.recent().map { project, metadata in
            let length = project.loadEdits().map { ClipTimeline($0.segments).duration } ?? metadata.duration
            return RecordingDraft(project: project, metadata: metadata, edited: project.lastEdited(fallback: metadata.createdAt), length: length)
        }
        for draft in drafts where thumbnails[draft.id] == nil {
            loadThumbnail(draft)
        }
    }

    func open(_ draft: RecordingDraft) {
        RecordingEditorWindowController.open(draft.project)
    }

    func rename(_ draft: RecordingDraft, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != draft.metadata.title else { return }
        var metadata = draft.metadata
        metadata.title = title
        try? draft.project.save(metadata)
        RecordingEditorWindowController.titleChanged(for: draft.project, to: title)
        reload()
    }

    func duplicate(_ draft: RecordingDraft) {
        do {
            _ = try draft.project.duplicate(title: "\(draft.metadata.title) copy")
        } catch {
            CaptureOutput.presentError(error)
        }
        reload()
    }

    func moveToTrash(_ draft: RecordingDraft) {
        RecordingEditorWindowController.close(draft.project)
        try? FileManager.default.trashItem(at: draft.project.folder, resultingItemURL: nil)
        thumbnails[draft.id] = nil
        reload()
    }

    /// A frame from the start of the kept video, saved next to the recording so it's only made once.
    private func loadThumbnail(_ draft: RecordingDraft) {
        guard loadingThumbnails.insert(draft.id).inserted else { return }
        let url = draft.project.folder.appendingPathComponent("thumbnail.png")
        let start = draft.project.loadEdits()?.segments.first?.start ?? 0
        Task {
            defer { loadingThumbnails.remove(draft.id) }
            if let saved = NSImage(contentsOf: url) {
                thumbnails[draft.id] = saved
                return
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: draft.project.videoURL))
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            let time = CMTime(seconds: min(start + 0.5, start + draft.metadata.duration / 2), preferredTimescale: 600)
            guard let frame = try? await generator.image(at: time).image else { return }
            try? CaptureOutput.write(frame, scale: 1, to: url)
            thumbnails[draft.id] = NSImage(cgImage: frame, size: .zero)
        }
    }
}

// MARK: - Window

final class DraftsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DraftsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: DraftsView(library: .shared))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Drafts"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 620))
        window.minSize = NSSize(width: 560, height: 400)
        window.center()
        window.setFrameAutosaveName("DraftsWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        DraftsLibrary.shared.reload()
        AppActivation.present(window!)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DraftsLibrary.shared.reload()
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.windowClosed()
    }
}

// MARK: - Views

private struct DraftsView: View {
    @ObservedObject var library: DraftsLibrary
    @State private var search = ""
    @State private var renaming: URL?

    private var filtered: [RecordingDraft] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.drafts }
        return library.drafts.filter { $0.metadata.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if library.drafts.isEmpty {
                ContentUnavailableView {
                    VStack(spacing: 14) {
                        if let illustration = Brand.illustration {
                            Image(nsImage: illustration)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 150, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                        }
                        Text("No Drafts Yet")
                    }
                } description: {
                    Text("Like an otter with its favorite stone, ScreenOtter keeps every recording here with its edits, ready to pick up again.")
                } actions: {
                    Button("Record Screen") { RecordingController.shared.toggle() }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 20)], spacing: 24) {
                        ForEach(filtered) { draft in
                            DraftCard(draft: draft, thumbnail: library.thumbnails[draft.id], library: library, renaming: $renaming)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .ignoresSafeArea(edges: .top)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 64, height: 1) // traffic lights
            AppIconImage(size: 24)
            Text("Drafts")
                .font(.system(size: 15, weight: .semibold))
            Text("\(library.drafts.count)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(width: 200, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            Button {
                RecordingController.shared.toggle()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .help("Record the screen (\(Preferences.shared.recordShortcut?.displayString ?? "menu bar"))")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

private struct DraftCard: View {
    let draft: RecordingDraft
    let thumbnail: NSImage?
    let library: DraftsLibrary
    @Binding var renaming: URL?

    @State private var title = ""
    @State private var isHovering = false
    @FocusState private var titleFocused: Bool

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Text(RecordingFormat.duration(draft.length))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovering ? Brand.accent : Color.primary.opacity(0.08), lineWidth: isHovering ? 2 : 1)
            )

            if renaming == draft.id {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = nil }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(draft.metadata.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Edited \(Self.relative.localizedString(for: draft.edited, relativeTo: Date()))")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { library.open(draft) }
        .help("Double-click to open")
        .contextMenu {
            Button("Open") { library.open(draft) }
            Button("Rename…") { startRename() }
            Button("Duplicate") { library.duplicate(draft) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([draft.project.folder]) }
            Divider()
            Button("Move to Trash", role: .destructive) { library.moveToTrash(draft) }
        }
    }

    private func startRename() {
        title = draft.metadata.title
        renaming = draft.id
        Task { titleFocused = true }
    }

    private func commitRename() {
        guard renaming == draft.id else { return }
        renaming = nil
        library.rename(draft, to: title)
    }
}
