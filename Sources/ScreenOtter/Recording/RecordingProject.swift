import CoreGraphics
import Foundation

/// What was recorded. Written once, when the recording stops.
nonisolated struct RecordingMetadata: Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case area, display, window
    }

    var source: Source
    var title: String
    var createdAt: Date
    /// The recorded content, in points.
    var pointSize: CGSize
    /// Video pixels per point.
    var scale: CGFloat
    var duration: Double
    /// Sound recorded alongside, one file per source. Missing in recordings made before audio existed:
    /// optional, so the synthesized decoding still reads them.
    var audio: [RecordedAudioTrack]?
    /// The camera recorded alongside, if it was on. Missing in older recordings, like `audio`.
    var webcam: RecordedWebcam?

    /// The audio tracks, none when the recording has no sound.
    var audioTracks: [RecordedAudioTrack] { audio ?? [] }
}

/// Pointer positions in points, relative to the recorded content's top-left corner.
/// Times are seconds from the first video frame.
nonisolated struct CursorRecording: Codable, Sendable {
    struct Sample: Codable, Sendable {
        var t: Double
        var x: CGFloat
        var y: CGFloat
    }

    var samples: [Sample] = []
    var clicks: [Sample] = []
}

/// A piece of the recording kept in the final video. Times are in the recording (source seconds).
nonisolated struct ClipSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var speed: Double = 1

    /// Length in the final video.
    var outputDuration: Double { (end - start) / speed }
}

/// A stretch of the recording where the camera zooms in and follows the pointer. Source seconds.
nonisolated struct ZoomSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double
    /// Made by auto zoom (from clicks) rather than by hand. Auto zooms are replaced when auto zoom is redone.
    var isAuto: Bool
}

nonisolated enum RecordingBackground: Codable, Equatable, Hashable, Sendable {
    case wallpaper
    case gradient(Int)
    case color(Int)
    case image(String)
}

nonisolated enum RecordingAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, wide, standard, square, vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .wide: "16:9"
        case .standard: "4:3"
        case .square: "1:1"
        case .vertical: "9:16"
        }
    }

    /// Width over height, or nil to follow the recording.
    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .wide: 16 / 9
        case .standard: 4 / 3
        case .square: 1
        case .vertical: 9 / 16
        }
    }
}

nonisolated enum CursorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case arrow, whiteArrow, dot

    var id: String { rawValue }
}

/// How the recording looks. The last used style becomes the default for the next recording.
nonisolated struct RecordingStyle: Codable, Equatable, Sendable {
    var background: RecordingBackground = .gradient(0)
    var backgroundBlur: Double = 0
    /// Space around the recording, as a fraction of its size.
    var padding: Double = 0.08
    /// Points of the recording.
    var cornerRadius: Double = 12
    var shadow: Double = 0.6
    var aspect: RecordingAspect = .auto
    /// Window recordings: replace the app's own title bar with a thin plain one.
    var minimalWindowFrame = true

    var showCursor = true
    var cursorStyle: CursorStyle = .arrow
    var cursorSize: Double = 1.5
    var smoothCursor = true
    var cursorMotionBlur = true
    var hideIdleCursor = false
    var clickEffect = true

    var autoZoom = true
    var zoomScale: Double = 2

    /// The webcam bubble, for recordings that have one.
    var webcam = WebcamStyle()

    private static let defaultsKey = "recordingStyle"

    static var lastUsed: RecordingStyle {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let style = try? JSONDecoder().decode(RecordingStyle.self, from: data)
        else { return RecordingStyle() }
        return style
    }

    func rememberAsDefault() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // Decoding field by field keeps older edits readable when new options are added.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingStyle()
        background = (try? c.decode(RecordingBackground.self, forKey: .background)) ?? d.background
        backgroundBlur = (try? c.decode(Double.self, forKey: .backgroundBlur)) ?? d.backgroundBlur
        padding = (try? c.decode(Double.self, forKey: .padding)) ?? d.padding
        cornerRadius = (try? c.decode(Double.self, forKey: .cornerRadius)) ?? d.cornerRadius
        shadow = (try? c.decode(Double.self, forKey: .shadow)) ?? d.shadow
        aspect = (try? c.decode(RecordingAspect.self, forKey: .aspect)) ?? d.aspect
        minimalWindowFrame = (try? c.decode(Bool.self, forKey: .minimalWindowFrame)) ?? d.minimalWindowFrame
        showCursor = (try? c.decode(Bool.self, forKey: .showCursor)) ?? d.showCursor
        cursorStyle = (try? c.decode(CursorStyle.self, forKey: .cursorStyle)) ?? d.cursorStyle
        cursorSize = (try? c.decode(Double.self, forKey: .cursorSize)) ?? d.cursorSize
        smoothCursor = (try? c.decode(Bool.self, forKey: .smoothCursor)) ?? d.smoothCursor
        cursorMotionBlur = (try? c.decode(Bool.self, forKey: .cursorMotionBlur)) ?? d.cursorMotionBlur
        hideIdleCursor = (try? c.decode(Bool.self, forKey: .hideIdleCursor)) ?? d.hideIdleCursor
        clickEffect = (try? c.decode(Bool.self, forKey: .clickEffect)) ?? d.clickEffect
        autoZoom = (try? c.decode(Bool.self, forKey: .autoZoom)) ?? d.autoZoom
        zoomScale = (try? c.decode(Double.self, forKey: .zoomScale)) ?? d.zoomScale
        webcam = (try? c.decode(WebcamStyle.self, forKey: .webcam)) ?? d.webcam
    }

    private enum CodingKeys: String, CodingKey {
        case background, backgroundBlur, padding, cornerRadius, shadow, aspect, minimalWindowFrame
        case showCursor, cursorStyle, cursorSize, smoothCursor, cursorMotionBlur, hideIdleCursor, clickEffect
        case autoZoom, zoomScale
        case webcam
    }
}

/// Everything the editor changes. Snapshots of this are the undo history.
nonisolated struct RecordingEdits: Codable, Equatable, Sendable {
    var segments: [ClipSegment]
    var zooms: [ZoomSegment]
    var style: RecordingStyle
    /// Window recordings: points of the app's own top bar to cut off for the minimal frame.
    /// Found from the traffic lights when the recording is first opened.
    var windowTopTrim: Double?
    /// Points cut from the left and right edges.
    var cutLeft: Double?
    var cutRight: Double?
    /// Volume and mute per audio source. Missing until a track is first changed.
    var audio: [AudioSource: AudioTrackMix]?
    /// The webcam bubble is turned off in this video. Missing means shown.
    var webcamHidden: Bool?

    static func initial(duration: Double, clicks: [CursorRecording.Sample], style: RecordingStyle) -> RecordingEdits {
        var edits = RecordingEdits(segments: [ClipSegment(start: 0, end: duration)], zooms: [], style: style)
        if style.autoZoom {
            edits.zooms = AutoZoom.segments(clicks: clicks, duration: duration, scale: style.zoomScale, keeping: [])
        }
        return edits
    }
}

/// A recording on disk: a folder with the raw video, the pointer track and the edits.
nonisolated struct RecordingProject: Sendable {
    let folder: URL

    var videoURL: URL { folder.appendingPathComponent("recording.mov") }
    var metadataURL: URL { folder.appendingPathComponent("metadata.json") }
    var cursorURL: URL { folder.appendingPathComponent("cursor.json") }
    var editsURL: URL { folder.appendingPathComponent("edits.json") }
    var wallpaperURL: URL { folder.appendingPathComponent("wallpaper.png") }

    func audioURL(_ source: AudioSource) -> URL { folder.appendingPathComponent(source.fileName) }
    func url(of track: RecordedAudioTrack) -> URL { folder.appendingPathComponent(track.file) }
    var webcamURL: URL { folder.appendingPathComponent(RecordedWebcam.fileName) }
    func url(of webcam: RecordedWebcam) -> URL { folder.appendingPathComponent(webcam.file) }

    static var libraryFolder: URL {
        AppFolders.support.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func create(named name: String) throws -> RecordingProject {
        var folder = libraryFolder.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = libraryFolder.appendingPathComponent("\(name) (\(counter))", isDirectory: true)
            counter += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return RecordingProject(folder: folder)
    }

    /// Finished recordings, most recently edited first.
    static func recent(limit: Int = .max) -> [(project: RecordingProject, metadata: RecordingMetadata)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil)) ?? []
        return folders
            .map(RecordingProject.init(folder:))
            .compactMap { project in project.loadMetadata().map { (project, $0) } }
            .map { ($0.0, $0.1, $0.0.lastEdited(fallback: $0.1.createdAt)) }
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    /// When the edits were last saved, or `fallback` for a recording never edited.
    func lastEdited(fallback: Date) -> Date {
        let modified = (try? editsURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified ?? fallback
    }

    /// A copy of the whole recording, edits included, under a new title.
    func duplicate(title: String) throws -> RecordingProject {
        let copy = try RecordingProject.create(named: title)
        try FileManager.default.removeItem(at: copy.folder)
        try FileManager.default.copyItem(at: folder, to: copy.folder)
        if var metadata = copy.loadMetadata() {
            metadata.title = title
            try copy.save(metadata)
        }
        return copy
    }

    func loadMetadata() -> RecordingMetadata? { Self.read(metadataURL) }
    func loadCursor() -> CursorRecording { Self.read(cursorURL) ?? CursorRecording() }
    func loadEdits() -> RecordingEdits? { Self.read(editsURL) }

    func save(_ metadata: RecordingMetadata) throws { try Self.write(metadata, to: metadataURL) }
    func save(_ cursor: CursorRecording) throws { try Self.write(cursor, to: cursorURL) }
    func save(_ edits: RecordingEdits) throws { try Self.write(edits, to: editsURL) }

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// Maps between time in the final video (output) and time in the recording (source).
nonisolated struct ClipTimeline: Sendable {
    let segments: [ClipSegment]
    /// Where each segment starts in the final video.
    let outputStarts: [Double]
    let duration: Double

    init(_ segments: [ClipSegment]) {
        self.segments = segments
        var starts: [Double] = []
        var t = 0.0
        for segment in segments {
            starts.append(t)
            t += segment.outputDuration
        }
        outputStarts = starts
        duration = t
    }

    func segmentIndex(atOutput t: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        for i in segments.indices.reversed() where t >= outputStarts[i] {
            return i
        }
        return 0
    }

    func sourceTime(atOutput t: Double) -> Double {
        guard let i = segmentIndex(atOutput: t) else { return 0 }
        let segment = segments[i]
        let local = min(max(t - outputStarts[i], 0), segment.outputDuration)
        return segment.start + local * segment.speed
    }

    /// The output time showing `source`, or the nearest kept moment when it was cut out.
    func outputTime(atSource s: Double) -> Double {
        var best = 0.0
        var bestDistance = Double.infinity
        for (i, segment) in segments.enumerated() {
            let clamped = min(max(s, segment.start), segment.end)
            let distance = abs(clamped - s)
            if distance < bestDistance {
                bestDistance = distance
                best = outputStarts[i] + (clamped - segment.start) / segment.speed
            }
            if distance == 0 { break }
        }
        return best
    }

    func speed(atOutput t: Double) -> Double {
        segmentIndex(atOutput: t).map { segments[$0].speed } ?? 1
    }
}
