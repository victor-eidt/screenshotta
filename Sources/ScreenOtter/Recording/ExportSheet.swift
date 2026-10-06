import SwiftUI

/// The export popover: one click on where the video is going (X, LinkedIn, Reels, YouTube, Product Hunt,
/// Dribbble, a README), or Custom for picking the format, size and frame rate by hand.
struct ExportPopover: View {
    @ObservedObject var doc: RecordingDocument
    let actions: RecordingEditorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch doc.export {
            case .idle, .failed:
                ExportSetup(doc: doc)

            case let .exporting(progress):
                Text(doc.exportSettings.format == .gif ? "Exporting GIF…" : "Exporting…").font(.headline)
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
        .frame(width: 404)
    }
}

private struct ExportSetup: View {
    @ObservedObject var doc: RecordingDocument

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let choice = doc.exportChoice
        let settings = doc.exportSettings
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ExportTemplate.all) { template in
                    ExportTile(
                        title: template.title, summary: template.summary, symbol: template.symbol, help: template.detail,
                        selected: choice.templateID == template.id
                    ) { doc.selectExport(template: template) }
                }
                ExportTile(
                    title: "Custom", summary: choice.custom.summary, symbol: "slider.horizontal.3",
                    help: "Pick the format, size and frame rate yourself.", selected: choice.templateID == nil
                ) { doc.selectExport(template: nil) }
            }

            Group {
                if let template = choice.template {
                    if template.variants.count > 1 {
                        SegmentedPills(
                            options: template.variants,
                            selection: Binding(
                                get: { choice.variant ?? template.variants[0] },
                                set: { doc.selectExport(template: template, variant: $0.id) }
                            ),
                            title: \.label
                        )
                    }
                } else {
                    CustomExportControls(custom: $doc.exportChoice.custom)
                }
            }
            .animation(nil, value: choice.templateID)

            Divider().opacity(0.5)

            ExportSummary(doc: doc, settings: settings)

            if case let .failed(message) = doc.export {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Button {
                doc.startExport()
            } label: {
                Text("Export \(settings.format.title) to \(Preferences.shared.saveFolder.lastPathComponent)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// One template: a symbol in a soft tile, the name, and its specs. The selected one is outlined in the accent.
private struct ExportTile: View {
    let title: String
    let summary: String
    let symbol: String
    let help: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Brand.accent : Color.white.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.09 : hovering ? 0.06 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Brand.accent.opacity(0.9) : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.snappy(duration: 0.18), value: selected)
        .help(help)
        .accessibilityLabel("\(title), \(summary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CustomExportControls: View {
    @Binding var custom: CustomExport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Format") {
                SegmentedPills(options: ExportFormat.allCases, selection: $custom.format, title: \.title)
            }
            switch custom.format {
            case .mp4:
                row("Size") {
                    SegmentedPills(options: ExportSize.allCases, selection: $custom.videoSize, title: \.title)
                }
                row("Frame rate") {
                    SegmentedPills(options: CustomExport.videoFrameRates, selection: $custom.videoFPS, title: \.fpsTitle)
                }
            case .gif:
                row("Size") {
                    SegmentedPills(options: CustomExport.gifSizes, selection: $custom.gifSize, title: \.description, name: \.pixelsName)
                }
                row("Frame rate") {
                    SegmentedPills(options: CustomExport.gifFrameRates, selection: $custom.gifFPS, title: \.fpsTitle)
                }
            }
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            content()
        }
    }
}

private extension Int {
    var fpsTitle: String { "\(self) fps" }
    var pixelsName: String { "\(self) pixels on the long side" }
}

/// What will be written: format, pixels, frame rate and length, plus a size estimate for GIFs.
private struct ExportSummary: View {
    @ObservedObject var doc: RecordingDocument
    let settings: ExportSettings

    var body: some View {
        let size = doc.exportPixelSize(settings)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(settings.format.title) · \(Int(size.width)) × \(Int(size.height)) · \(settings.fps) fps · \(RecordingFormat.duration(doc.duration))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let bytes = doc.gifSizeEstimate {
                let large = bytes > GIFEstimate.largeBytes
                Label {
                    Text(large
                        ? "\(GIFEstimate.label(bytes).capitalizedFirst): more than GitHub and many sites accept. A lower frame rate or size helps."
                        : "\(GIFEstimate.label(bytes).capitalizedFirst), loops forever")
                } icon: {
                    Image(systemName: large ? "exclamationmark.triangle.fill" : "doc")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(large ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let aspect = doc.exportAspectMismatch {
                HStack(spacing: 6) {
                    Text("The canvas is \(doc.edits.style.aspect.title); this template is \(aspect.title).")
                        .foregroundStyle(.secondary)
                    Button("Use \(aspect.title)") { doc.setAspect(aspect) }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11.5))
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
