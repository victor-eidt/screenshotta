import SwiftUI

/// The inspector's captions tab: transcribe the microphone, then show, style, edit and save the captions.
struct CaptionPanel: View {
    @ObservedObject var doc: RecordingDocument
    @State private var languages: [CaptionLanguage] = []
    @State private var language: CaptionLanguage?
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if doc.microphoneURL == nil {
                EmptyCaptions()
            } else if let track = doc.edits.captions, !track.cues.isEmpty {
                captions(track)
            } else {
                transcribe(title: "Transcribe what you said", detail: "The microphone track becomes captions under the video, each word lighting up as it's said. It all happens on this Mac.")
            }
        }
        .task {
            guard languages.isEmpty else { return }
            languages = await CaptionTranscriber.languages()
            language = CaptionTranscriber.preferred(in: languages)
        }
    }

    // MARK: - Transcribing

    private func transcribe(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch doc.transcription {
            case let .running(phase):
                progress(phase)
            case .idle, .failed:
                HStack(spacing: 8) {
                    Picker("Language", selection: $language) {
                        ForEach(languages) { Text($0.name).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(languages.isEmpty)
                    Button("Transcribe") {
                        if let language { doc.transcribe(language) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(language == nil)
                }
                if case let .failed(message) = doc.transcription {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func progress(_ phase: CaptionTranscriber.Phase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch phase {
            case let .downloading(fraction):
                ProgressView(value: fraction)
                Text("Downloading \(language?.name ?? "the language")… \(Int(fraction * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case let .transcribing(fraction):
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text(fraction.map { "Transcribing… \(Int($0 * 100))%" } ?? "Transcribing…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Cancel") { doc.cancelTranscription() }
                .controlSize(.small)
        }
        .controlSize(.small)
    }

    // MARK: - Captions

    private func captions(_ track: CaptionTrack) -> some View {
        let style = doc.edits.style.captions
        return Group {
            InspectorToggle(
                title: "Show captions",
                detail: "\(track.cues.count) caption\(track.cues.count == 1 ? "" : "s") · \(CaptionLanguage(id: track.language).name)",
                isOn: Binding(get: { doc.showsCaptions }, set: { doc.setCaptionsVisible($0) })
            )
            Group {
                InspectorSection("Style") {
                    HStack(spacing: 8) {
                        ForEach(KeystrokeTheme.allCases) { theme in
                            OverlayThemeTile(theme: theme, selected: style.theme == theme) {
                                doc.update { $0.style.captions.theme = theme }
                            } sample: {
                                HStack(spacing: 3) {
                                    Text("Say")
                                    Text("hi").opacity(0.5)
                                }
                            }
                        }
                    }
                }
                InspectorSection("Size") {
                    SegmentedPills(options: CaptionSize.allCases, selection: doc.style(\.captions.size), title: \.title, name: \.name)
                }
                InspectorSection("Position") {
                    SegmentedPills(options: KeystrokePosition.allCases, selection: doc.style(\.captions.position), title: \.title)
                }
                InspectorToggle(title: "Highlight words", detail: "Each word lights up as it's said.", isOn: doc.style(\.captions.highlightWords))
            }
            .disabled(!doc.showsCaptions)
            .opacity(doc.showsCaptions ? 1 : 0.5)

            InspectorSection("Text") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(track.cues) { cue in
                        CaptionRow(doc: doc, cue: cue)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    saved = try? doc.saveSubtitles()
                } label: {
                    Label("Save .srt", systemImage: "captions.bubble")
                }
                if let saved {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .buttonStyle(.link)
                }
            }
            .controlSize(.small)

            transcribe(title: "Transcribe again", detail: "Starts the captions over from the microphone, in the language you pick. ⌘Z brings your edits back.")
        }
    }
}

/// One caption: where it starts (click to go there) and its words, edited in place.
private struct CaptionRow: View {
    @ObservedObject var doc: RecordingDocument
    let cue: CaptionCue
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        let start = doc.outputStart(of: cue)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                if let start { doc.seek(to: start) }
            } label: {
                Text(start.map(RecordingFormat.duration) ?? "Cut")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(start == nil ? Color.secondary.opacity(0.5) : Color.secondary)
                    .frame(width: 38, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(start == nil)
            .help(start == nil ? "This part of the recording is cut out" : "Go to this caption")

            TextField("Caption", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, focused in
                    if !focused { commit() }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(editing ? 0.08 : 0.04)))
        .onAppear { text = cue.text }
        .onChange(of: cue.text) { _, new in
            if !editing { text = new }
        }
    }

    /// One undo step per edit, when it's done: on Return or when the field is left.
    private func commit() {
        guard text != cue.text else { return }
        doc.setCaptionText(cue.id, text)
    }
}

private struct EmptyCaptions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No microphone in this recording")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Captions are transcribed from what you say into the microphone. Turn on the microphone in the bar shown while you choose what to record, and your next recording can have them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
