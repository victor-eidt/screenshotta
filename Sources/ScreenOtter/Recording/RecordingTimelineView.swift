import SwiftUI

/// The timeline, in output time: the clips back to back (as long as they play), and the zooms under them.
struct RecordingTimelineView: View {
    @ObservedObject var doc: RecordingDocument

    private let inset: CGFloat = 20
    private let rulerHeight: CGFloat = 30
    private let clipTop: CGFloat = 34
    private let clipHeight: CGFloat = 54
    private let zoomTop: CGFloat = 98
    private let zoomHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let duration = max(doc.duration, 0.1)
            let pps = max(1, (geo.size.width - inset * 2) / duration * doc.timelineZoom)
            let width = duration * pps
            ScrollView(.horizontal, showsIndicators: doc.timelineZoom > 1.01) {
                ZStack(alignment: .topLeading) {
                    TimeRuler(duration: duration, pps: pps)
                        .frame(width: width, height: rulerHeight)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if doc.isPlaying { doc.player.pause() }
                                    doc.seek(to: value.location.x / pps)
                                }
                        )
                    ClipTrack(doc: doc, pps: pps, height: clipHeight)
                        .frame(width: width, height: clipHeight, alignment: .topLeading)
                        .offset(y: clipTop)
                    ZoomTrack(doc: doc, pps: pps, height: zoomHeight)
                        .frame(width: width, height: zoomHeight, alignment: .topLeading)
                        .offset(y: zoomTop)
                    Playhead(height: zoomTop + zoomHeight + 2)
                        .offset(x: doc.currentTime * pps - Playhead.width / 2, y: 2)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: zoomTop + zoomHeight + 8, alignment: .topLeading)
                .padding(.horizontal, inset)
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { RecordingTheme.hairline.frame(height: 1) }
    }
}

// MARK: - Ruler

private struct TimeRuler: View {
    let duration: Double
    let pps: CGFloat

    var body: some View {
        Canvas { context, size in
            let step = Self.step(for: pps)
            var t = 0.0
            while t <= duration + 0.0001 {
                let x = t * pps
                context.fill(Path(CGRect(x: x - 0.5, y: size.height - 7, width: 1, height: 5)), with: .color(.white.opacity(0.3)))
                let label = Text(Self.label(t, step: step))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                // Labels at the very ends stay inside the ruler.
                let anchor: UnitPoint = x < 24 ? .leading : x > size.width - 24 ? .trailing : .center
                context.draw(label, at: CGPoint(x: x, y: size.height - 17), anchor: anchor)
                let half = (t + step / 2) * pps
                if t + step / 2 < duration {
                    context.fill(Path(ellipseIn: CGRect(x: half - 1, y: size.height - 5.5, width: 2, height: 2)), with: .color(.white.opacity(0.25)))
                }
                t += step
            }
        }
    }

    /// Labels at least 64 points apart.
    static func step(for pps: CGFloat) -> Double {
        [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 * pps >= 64 } ?? 1200
    }

    static func label(_ t: Double, step: Double) -> String {
        let minutes = Int(t) / 60
        let seconds = t - Double(minutes * 60)
        return step < 1 ? String(format: "%d:%04.1f", minutes, seconds) : String(format: "%d:%02d", minutes, Int(seconds))
    }
}

private struct Playhead: View {
    static let width: CGFloat = 12
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Brand.accent)
                .frame(width: Self.width, height: Self.width)
            Rectangle()
                .fill(Brand.accent)
                .frame(width: 2, height: max(height - Self.width, 0))
        }
        .frame(width: Self.width)
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

// MARK: - Clips

private struct ClipTrack: View {
    @ObservedObject var doc: RecordingDocument
    let pps: CGFloat
    let height: CGFloat

    var body: some View {
        let timeline = doc.timeline
        ZStack(alignment: .topLeading) {
            ForEach(Array(doc.edits.segments.enumerated()), id: \.element.id) { index, segment in
                ClipBlock(doc: doc, segment: segment, index: index, pps: pps)
                    .frame(width: max(segment.outputDuration * pps - 3, 6), height: height)
                    .offset(x: timeline.outputStarts[index] * pps + 1.5)
            }
        }
    }
}

private struct ClipBlock: View {
    @ObservedObject var doc: RecordingDocument
    let segment: ClipSegment
    let index: Int
    let pps: CGFloat

    @State private var trimOrigin: ClipSegment?
    /// Resets when the drag ends or is cancelled; `onEnded` only runs for the first.
    @GestureState private var isTrimming = false

    private var isSelected: Bool { doc.selection == .segment(segment.id) }
    private var waveform: AudioWaveform? { doc.audibleWaveform }

    private func finishTrim() {
        guard trimOrigin != nil else { return }
        trimOrigin = nil
        doc.endTrim()
    }

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(RecordingTheme.clip)
                .overlay(alignment: .bottom) {
                    if let waveform {
                        ClipWaveform(levels: waveform.levels(from: segment.start, to: segment.end, count: ClipWaveform.barCount(width: geo.size.width - 20)))
                            .frame(height: ClipWaveform.height)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Color.black.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                )
                .overlay {
                    if geo.size.width > 84 {
                        VStack(spacing: 1) {
                            Text("Clip")
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.7)
                            HStack(spacing: 5) {
                                Text(RecordingFormat.duration(segment.outputDuration))
                                Image(systemName: "gauge.with.needle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(RecordingFormat.speed(segment.speed))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        // Makes room for the waveform underneath.
                        .offset(y: waveform == nil ? 0 : -6)
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    doc.selection = .segment(segment.id)
                    doc.inspector = .clip
                    doc.seek(to: doc.timeline.outputStarts[index] + location.x / pps)
                }
                .overlay(alignment: .leading) { handle(leading: true) }
                .overlay(alignment: .trailing) { handle(leading: false) }
        }
        .onChange(of: isTrimming) { _, trimming in
            if !trimming { finishTrim() }
        }
    }

    private func handle(leading: Bool) -> some View {
        Capsule()
            .fill(Color.white.opacity(isSelected ? 0.95 : 0.55))
            .frame(width: 4, height: 22)
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($isTrimming) { _, state, _ in state = true }
                    .onChanged { value in
                        if trimOrigin == nil {
                            trimOrigin = segment
                            doc.beginTrim(segment.id, leading: leading)
                            doc.selection = .segment(segment.id)
                        }
                        guard let origin = trimOrigin else { return }
                        let delta = value.translation.width / pps * origin.speed
                        doc.trim(origin.id, leading: leading, to: (leading ? origin.start : origin.end) + delta)
                    }
                    .onEnded { _ in finishTrim() }
            )
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
    }
}

/// The clip's sound, a faint strip of rounded bars along its bottom edge, under the label.
private struct ClipWaveform: View {
    let levels: [Float]

    static let height: CGFloat = 13
    static let pitch: CGFloat = 3
    static let barWidth: CGFloat = 2

    static func barCount(width: CGFloat) -> Int {
        max(0, Int((width + pitch - barWidth) / pitch))
    }

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for (index, level) in levels.enumerated() {
                let height = max(Self.barWidth, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * Self.pitch, y: size.height - height, width: Self.barWidth, height: height)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(path, with: .color(.white.opacity(0.32)))
        }
    }
}

// MARK: - Zooms

private struct ZoomTrack: View {
    @ObservedObject var doc: RecordingDocument
    let pps: CGFloat
    let height: CGFloat

    /// A zoom being drawn on the empty track, in output seconds.
    @State private var draft: ClosedRange<Double>?

    var body: some View {
        let timeline = doc.timeline
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay {
                    if doc.edits.zooms.isEmpty, draft == nil {
                        Text("Click or drag to add zoom on cursor")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let a = clamp(value.startLocation.x / pps), b = clamp(value.location.x / pps)
                            draft = min(a, b)...max(a, b)
                        }
                        .onEnded { _ in
                            defer { draft = nil }
                            guard let draft else { return }
                            // A click makes a two-second zoom.
                            let range = draft.upperBound - draft.lowerBound < 0.2
                                ? draft.lowerBound...min(draft.lowerBound + 2, doc.duration)
                                : draft
                            doc.addZoom(output: range)
                        }
                )

            if let draft {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.47, green: 0.40, blue: 0.98).opacity(0.45))
                    .frame(width: max((draft.upperBound - draft.lowerBound) * pps, 2), height: height)
                    .offset(x: draft.lowerBound * pps)
                    .allowsHitTesting(false)
            }

            ForEach(doc.edits.zooms) { zoom in
                let start = timeline.outputTime(atSource: zoom.start)
                let end = timeline.outputTime(atSource: zoom.end)
                if end - start > 0.01 {
                    ZoomBlock(doc: doc, zoom: zoom, pps: pps, outputStart: start, outputEnd: end)
                        .frame(width: max((end - start) * pps - 3, 8), height: height)
                        .offset(x: start * pps + 1.5)
                }
            }
        }
    }

    private func clamp(_ t: Double) -> Double {
        min(max(t, 0), doc.duration)
    }
}

private struct ZoomBlock: View {
    @ObservedObject var doc: RecordingDocument
    let zoom: ZoomSegment
    let pps: CGFloat
    let outputStart: Double
    let outputEnd: Double

    private struct Origin {
        var start: Double
        var end: Double
        var outputStart: Double
        var outputEnd: Double
    }

    @State private var origin: Origin?
    @GestureState private var isDragging = false

    private var isSelected: Bool { doc.selection == .zoom(zoom.id) }

    private func finishDrag() {
        guard origin != nil else { return }
        origin = nil
        doc.endInteraction()
    }

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(RecordingTheme.zoom)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Color.black.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                )
                .overlay {
                    if geo.size.width > 64 {
                        HStack(spacing: 4) {
                            Image(systemName: zoom.isAuto ? "cursorarrow.click.2" : "plus.magnifyingglass")
                            Text(String(format: "%.1f×", zoom.scale)).monospacedDigit()
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { select() }
                .gesture(drag { origin, dx in
                    let length = origin.outputEnd - origin.outputStart
                    let start = min(max(origin.outputStart + dx, 0), doc.duration - length)
                    doc.setZoom(zoom.id, start: doc.timeline.sourceTime(atOutput: start), end: doc.timeline.sourceTime(atOutput: start + length))
                })
                .overlay(alignment: .leading) {
                    edge.gesture(drag { origin, dx in
                        let start = doc.timeline.sourceTime(atOutput: min(max(origin.outputStart + dx, 0), doc.duration))
                        doc.setZoom(zoom.id, start: min(start, origin.end - 0.3), end: origin.end)
                    })
                }
                .overlay(alignment: .trailing) {
                    edge.gesture(drag { origin, dx in
                        let end = doc.timeline.sourceTime(atOutput: min(max(origin.outputEnd + dx, 0), doc.duration))
                        doc.setZoom(zoom.id, start: origin.start, end: max(end, origin.start + 0.3))
                    })
                }
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { finishDrag() }
        }
    }

    private var edge: some View {
        Color.clear
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func select() {
        doc.selection = .zoom(zoom.id)
        doc.inspector = .zoom
    }

    /// A drag that hands `change` the zoom as it was when the drag began and the distance moved, in seconds.
    private func drag(_ change: @escaping (Origin, Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                if origin == nil {
                    origin = Origin(start: zoom.start, end: zoom.end, outputStart: outputStart, outputEnd: outputEnd)
                    doc.beginInteraction()
                    select()
                }
                guard let origin else { return }
                change(origin, value.translation.width / pps)
            }
            .onEnded { _ in finishDrag() }
    }
}
