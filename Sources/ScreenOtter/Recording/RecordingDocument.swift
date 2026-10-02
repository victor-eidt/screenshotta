import AppKit
import AVFoundation
import Combine

enum RecordingInspectorTab: String, CaseIterable, Identifiable {
    case background, cursor, zoom, clip, audio, webcam, keystrokes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: "Background"
        case .cursor: "Cursor"
        case .zoom: "Zoom"
        case .clip: "Clip"
        case .audio: "Audio"
        case .webcam: "Camera"
        case .keystrokes: "Keystrokes"
        }
    }

    var symbol: String {
        switch self {
        case .background: "photo"
        case .cursor: "cursorarrow"
        case .zoom: "plus.magnifyingglass"
        case .clip: "film"
        case .audio: "waveform"
        case .webcam: "person.crop.square"
        case .keystrokes: "keyboard"
        }
    }
}

enum ExportSize: Int, CaseIterable, Identifiable {
    case hd = 1280, fullHD = 1920, quadHD = 2560, ultraHD = 3840

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hd: "720p"
        case .fullHD: "1080p"
        case .quadHD: "1440p"
        case .ultraHD: "4K"
        }
    }
}

enum ExportState: Equatable {
    case idle
    case exporting(Double)
    case done(URL)
    case failed(String)
}

/// One recording open in the editor: its edits with undo, and the player that previews them.
final class RecordingDocument: ObservableObject {
    enum Selection: Equatable {
        case segment(UUID)
        case zoom(UUID)
    }

    let project: RecordingProject
    @Published private(set) var metadata: RecordingMetadata
    let cursor: CursorRecording
    /// The keys pressed while recording, when it was made with keystrokes on.
    let keystrokes: KeystrokeRecording?
    let wallpaper: CGImage?
    let player = AVPlayer()

    @Published private(set) var edits: RecordingEdits
    @Published var selection: Selection?
    @Published var inspector: RecordingInspectorTab = .background
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var timelineZoom: Double = 1
    @Published var exportSize: ExportSize = .fullHD
    @Published private(set) var export: ExportState = .idle
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Each audio track's loudness, filled in shortly after opening.
    @Published private(set) var waveforms: [AudioSource: AudioWaveform] = [:]

    private(set) var timeline: ClipTimeline
    /// Kept alive on purpose: a track only weakly references its asset, and once the asset is gone
    /// every new cut fails to build.
    private let sourceAsset: AVURLAsset
    private let sourceTrack: AVAssetTrack
    private let trackDuration: Double
    private let sourceSize: CGSize
    /// The draft's audio files, loaded (the assets are kept alive for the same reason as `sourceAsset`).
    private let sourceAudio: [SourceAudio]
    private let audioAssets: [AVURLAsset]
    /// The recorded audio tracks that could be loaded, in a fixed order.
    let audioTracks: [RecordedAudioTrack]
    /// The draft's camera file, loaded, and its asset kept alive like `sourceAsset`.
    private let sourceWebcam: SourceWebcam?
    private let webcamAsset: AVURLAsset?
    private let renderer: RecordingRenderer
    /// The cut last built, and the cut the player is showing (they differ while a new item is on its way).
    private var composition: (segments: [ClipSegment], edited: EditedComposition)?
    private var mixedWaveform: (key: [Double], waveform: AudioWaveform?)?
    private var playerSegments: [ClipSegment]?
    private var customBackground: (path: String, image: CGImage?)?
    private let firstFrame: CGImage?
    private var chromeColors: (trim: Double, bar: CGColor, fill: CGColor)?
    private var motionKey: String?
    private var motion = MotionTrack.empty

    private var undoStack: [RecordingEdits] = []
    private var redoStack: [RecordingEdits] = []
    private(set) var isInteracting = false
    private var refreshGeneration = 0
    private var pendingSeek: Double?
    private var isSeeking = false
    private var saveTask: Task<Void, Never>?
    private var observers: [Any] = []
    private var statusObservation: NSKeyValueObservation?

    /// Preview frames are rendered at most this wide (or tall); export renders at full size.
    private static let previewLongSide: CGFloat = 1920

    static func load(_ project: RecordingProject) async throws -> RecordingDocument {
        guard let metadata = project.loadMetadata() else { throw CocoaError(.fileReadCorruptFile) }
        let asset = AVURLAsset(url: project.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingCompositionError.noVideo }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let cursor = project.loadCursor()
        let keystrokes = project.loadKeystrokes()
        var edits = project.loadEdits() ?? .initial(duration: duration, clicks: cursor.clicks, style: .lastUsed)
        let wallpaper = CGImageSourceCreateWithURL(project.wallpaperURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }

        // Audio files that are missing or unreadable are skipped: the video still opens.
        var audio: [(track: RecordedAudioTrack, asset: AVURLAsset, source: SourceAudio)] = []
        let recordedTracks = AudioSource.allCases.compactMap { source in metadata.audioTracks.first { $0.source == source } }
        for recorded in recordedTracks {
            let audioAsset = AVURLAsset(url: project.url(of: recorded))
            guard let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first,
                  let audioDuration = try? await audioAsset.load(.duration).seconds
            else { continue }
            audio.append((recorded, audioAsset, SourceAudio(source: recorded.source, track: audioTrack, duration: audioDuration)))
        }

        // Likewise the camera: without its file the video opens without the bubble.
        var webcam: (asset: AVURLAsset, source: SourceWebcam)?
        if let recorded = metadata.webcam {
            let webcamAsset = AVURLAsset(url: project.url(of: recorded))
            if let webcamTrack = try? await webcamAsset.loadTracks(withMediaType: .video).first,
               let webcamDuration = try? await webcamAsset.load(.duration).seconds {
                webcam = (webcamAsset, SourceWebcam(track: webcamTrack, duration: webcamDuration, offset: recorded.offset))
            }
        }

        // Window recordings get a minimal title bar: the first frame shows how tall the app's own top bar is,
        // and what color sits under it.
        var firstFrame: CGImage?
        if metadata.source == .window {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            firstFrame = try? await generator.image(at: .zero).image
            if edits.windowTopTrim == nil {
                let center = firstFrame.flatMap { TrafficLights.closeButtonCenter(in: $0, scale: metadata.scale) }
                // The lights sit in the middle of the bar they belong to.
                edits.windowTopTrim = center.map { ($0.y / metadata.scale * 2).rounded() } ?? 0
            }
        }
        return RecordingDocument(
            project: project, metadata: metadata, cursor: cursor, keystrokes: keystrokes, edits: edits, asset: asset, track: track,
            trackDuration: duration, sourceSize: size, wallpaper: wallpaper, firstFrame: firstFrame,
            audio: audio, webcam: webcam
        )
    }

    private init(
        project: RecordingProject, metadata: RecordingMetadata, cursor: CursorRecording, keystrokes: KeystrokeRecording?, edits: RecordingEdits,
        asset: AVURLAsset, track: AVAssetTrack, trackDuration: Double, sourceSize: CGSize, wallpaper: CGImage?, firstFrame: CGImage?,
        audio: [(track: RecordedAudioTrack, asset: AVURLAsset, source: SourceAudio)],
        webcam: (asset: AVURLAsset, source: SourceWebcam)?
    ) {
        self.firstFrame = firstFrame
        self.project = project
        self.metadata = metadata
        self.cursor = cursor
        self.keystrokes = keystrokes
        self.edits = edits
        self.wallpaper = wallpaper
        sourceAsset = asset
        sourceTrack = track
        self.trackDuration = trackDuration
        self.sourceSize = sourceSize
        audioTracks = audio.map(\.track)
        audioAssets = audio.map(\.asset)
        sourceAudio = audio.map(\.source)
        webcamAsset = webcam?.asset
        sourceWebcam = webcam?.source
        timeline = ClipTimeline(edits.segments)
        renderer = RecordingRenderer(scene: RenderScene(
            style: edits.style, motion: .empty, pointSize: metadata.pointSize,
            sourceSize: sourceSize, wallpaper: wallpaper, customBackground: nil
        ))
        player.actionAtItemEnd = .pause
        observePlayer()
        refresh()
        loadWaveforms()
    }

    var duration: Double { timeline.duration }
    var sourceDuration: Double { trackDuration }

    // MARK: - Player

    private func observePlayer() {
        let interval = CMTime(value: 1, timescale: 30)
        observers.append(player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.pendingSeek == nil, !self.isSeeking else { return }
                self.currentTime = min(max(time.seconds, 0), self.duration)
            }
        })
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    /// Scrubbing: always lands exactly on `time`, dropping intermediate requests while a seek runs.
    func seek(to time: Double) {
        currentTime = min(max(time, 0), duration)
        pendingSeek = currentTime
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard !isSeeking, let target = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.performPendingSeek()
            }
        }
    }

    func step(frames: Int) {
        player.pause()
        seek(to: currentTime + Double(frames) / 60)
    }

    // MARK: - Editing

    /// Applies a change as one undo step, or as part of the current drag.
    func update(_ change: (inout RecordingEdits) -> Void) {
        var new = edits
        change(&new)
        guard new != edits else { return }
        if !isInteracting { checkpoint() }
        apply(new)
    }

    /// For drags and sliders: one undo step for the whole gesture, and the costly rebuild only at the end.
    func beginInteraction() {
        guard !isInteracting else { return }
        checkpoint()
        isInteracting = true
    }

    func endInteraction() {
        guard isInteracting else { return }
        isInteracting = false
        refresh()
    }

    private func checkpoint() {
        undoStack.append(edits)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoState()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edits)
        apply(previous)
        updateUndoState()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edits)
        apply(next)
        updateUndoState()
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func apply(_ new: RecordingEdits) {
        let old = edits
        edits = new
        if new.style != old.style { new.style.rememberAsDefault() }
        let segmentsChanged = new.segments != old.segments
        if segmentsChanged {
            let source = old.segments.isEmpty ? 0 : timeline.sourceTime(atOutput: currentTime)
            timeline = ClipTimeline(new.segments)
            currentTime = min(timeline.outputTime(atSource: source), duration)
        }
        if let selection, !isSelectionValid(selection) { self.selection = nil }
        var withoutAudio = new
        withoutAudio.audio = old.audio
        if withoutAudio == old {
            // Only the volumes changed: the picture stays as it is.
            player.currentItem?.audioMix = currentAudioMix()
        } else {
            refresh()
        }
        scheduleSave()
    }

    private func isSelectionValid(_ selection: Selection) -> Bool {
        switch selection {
        case let .segment(id): edits.segments.contains { $0.id == id }
        case let .zoom(id): edits.zooms.contains { $0.id == id }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        try? project.save(edits)
    }

    // MARK: - Rendering

    private func currentScene() -> RenderScene {
        let style = edits.style
        let frame = recordingFrame
        let geometry = cameraGeometry(frame)
        let key = [
            "\(edits.zooms)", "\(style.smoothCursor)", "\(style.hideIdleCursor)", "\(geometry)",
        ].joined(separator: "|")
        if key != motionKey {
            motionKey = key
            motion = MotionTrack(
                recording: cursor, pointSize: metadata.pointSize, duration: trackDuration,
                zooms: edits.zooms, style: style, geometry: geometry
            )
        }
        return RenderScene(
            style: style, motion: motion, pointSize: metadata.pointSize,
            sourceSize: sourceSize, wallpaper: wallpaper, customBackground: loadCustomBackground(style.background),
            frame: frame, webcam: showsWebcam ? style.webcam : nil,
            keystrokes: showsKeystrokes ? keystrokes.map { KeystrokeOverlay(events: $0.events, style: style.keystrokes) } : nil
        )
    }

    /// How the camera's view maps onto the framed recording.
    private func cameraGeometry(_ frame: RecordingFrame?) -> CameraGeometry {
        let content = frame?.size(of: sourceSize) ?? sourceSize
        let canvas = RecordingRenderer.canvasSize(style: edits.style, sourceSize: content)
        return CameraGeometry(
            viewHalf: CGSize(width: canvas.width / content.width / 2, height: canvas.height / content.height / 2),
            scale: CGSize(width: sourceSize.width / content.width, height: sourceSize.height / content.height),
            offset: CGPoint(x: -(frame?.left ?? 0) / content.width, y: ((frame?.bar ?? 0) - (frame?.top ?? 0)) / content.height),
            aspect: content.height / content.width
        )
    }

    var isWindowRecording: Bool { metadata.source == .window }

    /// The most that can be cut from each side, in points.
    var maximumSideCut: Double { (metadata.pointSize.width * 0.4).rounded() }

    /// The cuts at the edges, plus the minimal title bar for window recordings (its colors come from the first frame).
    private var recordingFrame: RecordingFrame? {
        let scale = metadata.scale
        let left = (min(edits.cutLeft ?? 0, maximumSideCut) * scale).rounded()
        let right = (min(edits.cutRight ?? 0, maximumSideCut) * scale).rounded()
        var frame = RecordingFrame(left: left, right: right, scale: scale)

        if isWindowRecording, edits.style.minimalWindowFrame, let image = firstFrame {
            let trim = edits.windowTopTrim ?? 0
            if chromeColors?.trim != trim {
                let below = Int((trim + 2) * scale)
                let bar = WindowChromeArt.dominantColor(of: image, row: below) ?? CGColor(gray: 0.93, alpha: 1)
                let fill = WindowChromeArt.dominantColor(of: image, row: image.height - Int(4 * scale)) ?? bar
                chromeColors = (trim, bar, fill)
            }
            frame.top = (trim * scale).rounded()
            frame.bar = (RecordingFrame.barHeight * scale).rounded()
            frame.barColor = chromeColors?.bar
            frame.fillColor = chromeColors?.fill
        }
        guard frame.left > 0 || frame.right > 0 || frame.bar > 0 else { return nil }
        return frame
    }

    /// The recording's size as framed (in video pixels).
    private var contentSize: CGSize {
        recordingFrame?.size(of: sourceSize) ?? sourceSize
    }

    private func loadCustomBackground(_ background: RecordingBackground) -> CGImage? {
        guard case let .image(path) = background else { return nil }
        if let cached = customBackground, cached.path == path { return cached.image }
        let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        customBackground = (path, image)
        return image
    }

    var previewSize: CGSize {
        let canvas = RecordingRenderer.canvasSize(style: edits.style, sourceSize: contentSize)
        return RecordingRenderer.outputSize(canvas: canvas, longSide: Self.previewLongSide)
    }

    func exportPixelSize(_ size: ExportSize) -> CGSize {
        let canvas = RecordingRenderer.canvasSize(style: edits.style, sourceSize: contentSize)
        return RecordingRenderer.outputSize(canvas: canvas, longSide: CGFloat(size.rawValue))
    }

    /// Pushes the edits to the renderer and the player. A new video composition makes the player redraw
    /// even while paused; a new cut needs a new player item. While a clip is being dragged the player keeps
    /// the cut it has, and catches up when the drag ends. Each video composition carries the cut it was
    /// made for, so the pointer and camera always match the frames on screen.
    private func refresh() {
        renderer.update(currentScene())
        refreshGeneration += 1
        let generation = refreshGeneration
        let renderSize = previewSize

        let segments = isInteracting ? (playerSegments ?? edits.segments) : edits.segments
        if composition?.segments != segments {
            guard let edited = try? RecordingComposition.make(
                track: sourceTrack, trackDuration: trackDuration, segments: segments, audio: sourceAudio, webcam: sourceWebcam
            ) else { return }
            composition = (segments, edited)
        }
        guard let composition else { return }
        let needsItem = playerSegments != composition.segments || player.currentItem == nil
        Task {
            guard let videoComposition = try? await RecordingComposition.videoComposition(
                for: composition.edited.asset, composition: composition.edited, timeline: ClipTimeline(composition.segments),
                renderer: renderer, renderSize: renderSize
            ), generation == refreshGeneration
            else { return }
            if needsItem {
                let item = AVPlayerItem(asset: composition.edited.asset)
                item.videoComposition = videoComposition
                item.audioMix = currentAudioMix()
                item.audioTimePitchAlgorithm = RecordingComposition.pitchAlgorithm
                player.replaceCurrentItem(with: item)
                playerSegments = composition.segments
            } else {
                player.currentItem?.videoComposition = videoComposition
            }
            if !isPlaying { seek(to: currentTime) }
        }
    }

    // MARK: - Audio

    var audioSources: [AudioSource] { audioTracks.map(\.source) }

    func audioMix(for source: AudioSource) -> AudioTrackMix {
        edits.audioMix(for: source, alongside: audioSources)
    }

    func setAudioMix(_ source: AudioSource, _ change: (inout AudioTrackMix) -> Void) {
        var mix = audioMix(for: source)
        change(&mix)
        update { edits in
            var all = edits.audio ?? [:]
            all[source] = mix
            edits.audio = all
        }
    }

    private func currentAudioMix() -> AVAudioMix? {
        guard let composition else { return nil }
        return RecordingComposition.audioMix(composition.edited) { self.audioMix(for: $0).effectiveVolume }
    }

    /// What the timeline draws: every track at its volume, nil when nothing is audible.
    var audibleWaveform: AudioWaveform? {
        let volumes = audioSources.map { waveforms[$0] == nil ? -1 : audioMix(for: $0).effectiveVolume }
        if let cached = mixedWaveform, cached.key == volumes { return cached.waveform }
        let tracks = audioSources.compactMap { source in waveforms[source].map { ($0, audioMix(for: source).effectiveVolume) } }
        let waveform = tracks.contains { $0.1 > 0 } ? AudioWaveform.mixed(tracks) : nil
        mixedWaveform = (volumes, waveform)
        return waveform
    }

    private func loadWaveforms() {
        for track in audioTracks {
            let url = project.url(of: track)
            Task {
                if let waveform = await AudioWaveform.load(url) { waveforms[track.source] = waveform }
            }
        }
    }

    // MARK: - Webcam

    /// The recording has a camera file that could be loaded.
    var hasWebcam: Bool { sourceWebcam != nil }

    /// The bubble is drawn: there's a camera, and it isn't turned off for this video.
    var showsWebcam: Bool { hasWebcam && edits.webcamHidden != true }

    var webcamDeviceName: String? { metadata.webcam?.deviceName }

    func setWebcamVisible(_ visible: Bool) {
        update { $0.webcamHidden = visible ? nil : true }
    }

    /// The bubble's frame in the preview, in top-left-origin units of `size` (the player's on-screen size),
    /// at rest and at the current moment (smaller while zoomed in). Nil while it isn't drawn, including while
    /// it's faded out for a zoom, so there's nothing invisible to hover or drag.
    func webcamFrame(in size: CGSize) -> (rest: CGRect, now: CGRect)? {
        guard showsWebcam, size.width > 0 else { return nil }
        let canvas = previewSize
        let k = size.width / canvas.width
        let style = edits.style.webcam
        let zoom = motion.camera(at: timeline.sourceTime(atOutput: currentTime)).scale
        let now = WebcamLayout.presentation(style, canvas: canvas, zoomScale: zoom)
        guard WebcamLayout.isGrabbable(opacity: now.opacity) else { return nil }
        let rest = WebcamLayout.frame(style, canvas: canvas)
        func scaled(_ r: CGRect) -> CGRect { CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k) }
        return (scaled(rest), scaled(now.frame))
    }

    /// Moves the bubble so its resting top-left corner is at `origin` (preview units of `size`).
    /// `snap` pulls it into a corner when it's dropped close to one.
    func moveWebcam(origin: CGPoint, in size: CGSize, snap: Bool) {
        guard size.width > 0 else { return }
        let canvas = previewSize
        let k = canvas.width / size.width
        var position = WebcamLayout.position(origin: CGPoint(x: origin.x * k, y: origin.y * k), style: edits.style.webcam, canvas: canvas)
        if snap { position = WebcamLayout.snapped(position) }
        update { $0.style.webcam.x = position.x; $0.style.webcam.y = position.y }
    }

    // MARK: - Keystrokes

    /// The recording was made with keystrokes on (it may still have none, if no shortcut was pressed).
    var hasKeystrokes: Bool { keystrokes != nil }

    /// The pill is drawn: there are keys, and it isn't turned off for this video.
    var showsKeystrokes: Bool { !(keystrokes?.events.isEmpty ?? true) && edits.keystrokesHidden != true }

    func setKeystrokesVisible(_ visible: Bool) {
        update { $0.keystrokesHidden = visible ? nil : true }
    }

    // MARK: - Clips

    /// The selected clip, or else the one under the playhead.
    var activeSegmentIndex: Int? {
        if case let .segment(id) = selection, let index = edits.segments.firstIndex(where: { $0.id == id }) {
            return index
        }
        return timeline.segmentIndex(atOutput: min(currentTime, max(duration - 0.001, 0)))
    }

    func splitAtPlayhead() {
        guard let index = timeline.segmentIndex(atOutput: currentTime) else { return }
        let segment = edits.segments[index]
        let source = timeline.sourceTime(atOutput: currentTime)
        guard source - segment.start > 0.1, segment.end - source > 0.1 else { return }
        update { edits in
            edits.segments[index].end = source
            edits.segments.insert(ClipSegment(start: source, end: segment.end, speed: segment.speed), at: index + 1)
        }
        selection = .segment(edits.segments[index + 1].id)
    }

    func deleteSegment(_ id: UUID) {
        guard edits.segments.count > 1 else { return }
        update { $0.segments.removeAll { $0.id == id } }
    }

    func setSpeed(_ speed: Double, for index: Int) {
        guard edits.segments.indices.contains(index) else { return }
        update { $0.segments[index].speed = speed }
    }

    /// Trims one end of a clip to `time` (source seconds), without overlapping its neighbours.
    func trim(_ id: UUID, leading: Bool, to time: Double) {
        guard let index = edits.segments.firstIndex(where: { $0.id == id }) else { return }
        update { edits in
            var segment = edits.segments[index]
            if leading {
                let lower = index > 0 ? edits.segments[index - 1].end : 0
                segment.start = min(max(time, lower), segment.end - 0.25)
            } else {
                let upper = index + 1 < edits.segments.count ? edits.segments[index + 1].start : trackDuration
                segment.end = max(min(time, upper), segment.start + 0.25)
            }
            edits.segments[index] = segment
        }
    }

    // MARK: - Zooms

    /// Adds a hand-made zoom over `range` (output seconds), shrunk to fit between the zooms around it.
    func addZoom(output range: ClosedRange<Double>) {
        var start = timeline.sourceTime(atOutput: range.lowerBound)
        var end = timeline.sourceTime(atOutput: range.upperBound)
        if let before = edits.zooms.last(where: { $0.start <= start }), before.end > start {
            start = before.end
        }
        if let after = edits.zooms.first(where: { $0.start >= start }), after.start < end {
            end = after.start
        }
        guard end - start >= 0.4 else { return }
        let zoom = ZoomSegment(start: start, end: end, scale: edits.style.zoomScale, isAuto: false)
        update { edits in
            edits.zooms.append(zoom)
            edits.zooms.sort { $0.start < $1.start }
        }
        selection = .zoom(zoom.id)
        inspector = .zoom
    }

    func deleteZoom(_ id: UUID) {
        update { $0.zooms.removeAll { $0.id == id } }
    }

    /// Moves or resizes a zoom to `start`...`end` (source seconds), stopping at its neighbours.
    func setZoom(_ id: UUID, start: Double, end: Double) {
        guard let index = edits.zooms.firstIndex(where: { $0.id == id }) else { return }
        let lower = index > 0 ? edits.zooms[index - 1].end : 0
        let upper = index + 1 < edits.zooms.count ? edits.zooms[index + 1].start : trackDuration
        var start = start, end = end
        let length = end - start
        if start < lower { start = lower; end = max(end, start + min(length, 0.4)) }
        if end > upper { end = upper; start = min(start, end - min(length, 0.4)) }
        guard end - start >= 0.3 else { return }
        update { edits in
            edits.zooms[index].start = start
            edits.zooms[index].end = end
        }
    }

    func setAutoZoom(_ enabled: Bool) {
        update { edits in
            edits.style.autoZoom = enabled
            let manual = edits.zooms.filter { !$0.isAuto }
            edits.zooms = enabled
                ? AutoZoom.segments(clicks: cursor.clicks, duration: trackDuration, scale: edits.style.zoomScale, keeping: manual)
                : manual
        }
    }

    /// The default zoom level, also applied to every auto zoom.
    func setDefaultZoomScale(_ scale: Double) {
        update { edits in
            edits.style.zoomScale = scale
            for index in edits.zooms.indices where edits.zooms[index].isAuto {
                edits.zooms[index].scale = scale
            }
        }
    }

    func deleteSelection() {
        switch selection {
        case let .segment(id): deleteSegment(id)
        case let .zoom(id): deleteZoom(id)
        case nil: break
        }
    }

    // MARK: - Export

    func startExport() {
        guard !isInteracting, let composition, !isExporting else { return }
        player.pause()
        let size = exportPixelSize(exportSize)
        let url = Self.exportURL(named: metadata.title)
        // A frozen copy of the edits: changing things while exporting doesn't affect the file.
        let exportRenderer = RecordingRenderer(scene: renderer.currentScene)
        let volumes = Dictionary(uniqueKeysWithValues: audioSources.map { ($0, audioMix(for: $0).effectiveVolume) })
        let volume: (AudioSource) -> Double = { volumes[$0] ?? 0 }
        let asset = RecordingComposition.exportAsset(composition.edited, volume: volume)
        let audioMix = RecordingComposition.audioMix(composition.edited, volume: volume)
        export = .exporting(0)
        Task {
            do {
                let videoComposition = try await RecordingComposition.videoComposition(
                    for: asset, composition: composition.edited, timeline: ClipTimeline(composition.segments),
                    renderer: exportRenderer, renderSize: size
                )
                try await RecordingComposition.export(asset, videoComposition: videoComposition, audioMix: audioMix, to: url) { progress in
                    Task { @MainActor in
                        guard case .exporting = self.export else { return }
                        self.export = .exporting(progress)
                    }
                }
                export = .done(url)
                if Preferences.shared.copyToClipboard { copyFile(url) }
            } catch {
                export = .failed(error.localizedDescription)
            }
        }
    }

    var isExporting: Bool {
        if case .exporting = export { return true }
        return false
    }

    func resetExport() {
        if !isExporting { export = .idle }
    }

    func copyFile(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private static func exportURL(named name: String) -> URL {
        let folder = Preferences.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(name).appendingPathExtension("mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(counter))").appendingPathExtension("mp4")
            counter += 1
        }
        return url
    }

    /// Called when the draft is renamed from the Drafts window.
    func titleChanged(to title: String) {
        metadata.title = title
    }

    // MARK: - Closing

    func close() {
        player.pause()
        save()
        observers.forEach(player.removeTimeObserver)
        observers.removeAll()
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
    }
}
