import Foundation

/// The kind of file an export writes.
nonisolated enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case mp4, gif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: "MP4"
        case .gif: "GIF"
        }
    }

    var fileExtension: String { rawValue }
}

/// MP4 sizes, by the output's long side.
nonisolated enum ExportSize: Int, Codable, CaseIterable, Identifiable, Sendable {
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

/// How big the exported frames are.
nonisolated enum ExportResolution: Equatable, Hashable, Codable, Sendable {
    /// At most this many pixels on the long side. Never larger than the recording itself.
    case longSide(Int)
    /// At most this many pixels wide, the height following the canvas. Never larger than the recording itself.
    case width(Int)
    /// Exactly this size, as platforms ask for: the canvas is scaled to fit (up, if it must) and its
    /// background fills whatever the aspect ratio leaves over.
    case exact(width: Int, height: Int)

    /// The output size for a canvas of `canvas` pixels (the recording at its own resolution, padding included).
    /// Sides are even, as video encoders want.
    func pixelSize(canvas: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return CGSize(width: 2, height: 2) }
        let k: CGFloat
        switch self {
        case let .longSide(side): k = min(1, CGFloat(side) / max(canvas.width, canvas.height))
        case let .width(width): k = min(1, CGFloat(width) / canvas.width)
        case let .exact(width, height): return CGSize(width: Self.even(CGFloat(width)), height: Self.even(CGFloat(height)))
        }
        return CGSize(width: Self.even(canvas.width * k), height: Self.even(canvas.height * k))
    }

    private static func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
}

/// Everything that decides the exported file, besides the edits.
nonisolated struct ExportSettings: Equatable, Hashable, Codable, Sendable {
    var format: ExportFormat
    var resolution: ExportResolution
    var fps: Int
}

// MARK: - Templates

/// A one-click target: the canvas, size, format and frame rate a platform wants. Platforms are named,
/// never drawn with their logos: each gets a plain SF Symbol.
nonisolated struct ExportTemplate: Identifiable, Equatable, Sendable {
    /// One way to export for the platform (LinkedIn takes square and portrait, YouTube 1080p and 4K).
    struct Variant: Identifiable, Hashable, Sendable {
        let id: String
        /// Short, for the picker when a template has more than one.
        let label: String
        /// The canvas the template sets, or nil to keep the one chosen in the editor.
        let aspect: RecordingAspect?
        let settings: ExportSettings
    }

    /// Stable: remembered between launches.
    let id: String
    let title: String
    /// The specs at a glance, under the title.
    let summary: String
    /// Where the export is meant to go, for the tooltip.
    let detail: String
    let symbol: String
    let variants: [Variant]

    func variant(_ id: String?) -> Variant {
        variants.first { $0.id == id } ?? variants[0]
    }

    static let all: [ExportTemplate] = [
        ExportTemplate(
            id: "x", title: "X / Twitter", summary: "16:9 · 1080p", detail: "A 16:9 video for posts on X.", symbol: "at",
            variants: [mp4("1080p", .wide, 1920, 1080, fps: 60)]
        ),
        ExportTemplate(
            id: "linkedin", title: "LinkedIn", summary: "1:1 or 4:5", detail: "Square or 4:5 portrait, the shapes that fill the LinkedIn feed.", symbol: "briefcase",
            variants: [mp4("Square", .square, 1080, 1080, fps: 30, label: "Square 1:1"), mp4("Portrait", .portrait, 1080, 1350, fps: 30, label: "Portrait 4:5")]
        ),
        ExportTemplate(
            id: "vertical", title: "Reels & TikTok", summary: "9:16 · 1080p", detail: "Full-screen 9:16 for Instagram Reels, Stories, TikTok and Shorts.", symbol: "iphone",
            variants: [mp4("1080p", .vertical, 1080, 1920, fps: 30)]
        ),
        ExportTemplate(
            id: "youtube", title: "YouTube", summary: "1080p or 4K", detail: "16:9 in Full HD or 4K.", symbol: "play.rectangle",
            variants: [mp4("1080p", .wide, 1920, 1080, fps: 60), mp4("4K", .wide, 3840, 2160, fps: 60)]
        ),
        ExportTemplate(
            id: "producthunt", title: "Product Hunt", summary: "GIF · 1270 × 760", detail: "A GIF at the size of the Product Hunt gallery, 1270 × 760.", symbol: "cat",
            variants: [Variant(
                id: "gallery", label: "Gallery", aspect: .wide,
                settings: ExportSettings(format: .gif, resolution: .exact(width: 1270, height: 760), fps: 15)
            )]
        ),
        ExportTemplate(
            id: "dribbble", title: "Dribbble", summary: "4:3 · 1600 × 1200", detail: "A 4:3 shot at 1600 × 1200.", symbol: "basketball",
            variants: [mp4("Shot", .standard, 1600, 1200, fps: 30)]
        ),
        ExportTemplate(
            id: "readme", title: "README GIF", summary: "GIF · 800 px wide", detail: "A light GIF for a README or docs page: 800 px wide, 15 fps.",
            symbol: "chevron.left.forwardslash.chevron.right",
            variants: [Variant(id: "gif", label: "GIF", aspect: nil, settings: ExportSettings(format: .gif, resolution: .width(800), fps: 15))]
        ),
    ]

    static func template(_ id: String?) -> ExportTemplate? {
        all.first { $0.id == id }
    }

    private static func mp4(_ id: String, _ aspect: RecordingAspect, _ width: Int, _ height: Int, fps: Int, label: String? = nil) -> Variant {
        Variant(
            id: id.lowercased(), label: label ?? id, aspect: aspect,
            settings: ExportSettings(format: .mp4, resolution: .exact(width: width, height: height), fps: fps)
        )
    }
}

/// The hand-picked settings, for when no template fits. Each format keeps its own size and frame rate,
/// so switching between them doesn't lose either.
nonisolated struct CustomExport: Codable, Equatable, Sendable {
    static let videoFrameRates = [30, 60]
    static let gifFrameRates = [10, 15, 24]
    /// GIF long sides, in pixels.
    static let gifSizes = [480, 640, 800, 1080]

    var format: ExportFormat = .mp4
    var videoSize: ExportSize = .fullHD
    var videoFPS = 60
    var gifSize = 800
    var gifFPS = 15

    /// "MP4 · 1080p · 60 fps", "GIF · 800 px · 15 fps".
    var summary: String {
        switch format {
        case .mp4: "MP4 · \(videoSize.title) · \(videoFPS) fps"
        case .gif: "GIF · \(gifSize) px · \(gifFPS) fps"
        }
    }

    var settings: ExportSettings {
        switch format {
        case .mp4: ExportSettings(format: .mp4, resolution: .longSide(videoSize.rawValue), fps: videoFPS)
        case .gif: ExportSettings(format: .gif, resolution: .longSide(gifSize), fps: gifFPS)
        }
    }

    init() {}

    // Field by field, falling back to the default for anything missing or no longer offered.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CustomExport()
        format = (try? c.decode(ExportFormat.self, forKey: .format)) ?? d.format
        videoSize = (try? c.decode(ExportSize.self, forKey: .videoSize)) ?? d.videoSize
        videoFPS = (try? c.decode(Int.self, forKey: .videoFPS)).flatMap { Self.videoFrameRates.contains($0) ? $0 : nil } ?? d.videoFPS
        gifSize = (try? c.decode(Int.self, forKey: .gifSize)).flatMap { Self.gifSizes.contains($0) ? $0 : nil } ?? d.gifSize
        gifFPS = (try? c.decode(Int.self, forKey: .gifFPS)).flatMap { Self.gifFrameRates.contains($0) ? $0 : nil } ?? d.gifFPS
    }

    private enum CodingKeys: String, CodingKey {
        case format, videoSize, videoFPS, gifSize, gifFPS
    }
}

/// What the export sheet has selected: a template (and its variant), or the custom settings.
/// Remembered between recordings, like the last style.
nonisolated struct ExportChoice: Codable, Equatable, Sendable {
    /// The selected template, or nil for Custom.
    var templateID: String?
    /// The variant picked for each template that has several.
    var variants: [String: String] = [:]
    var custom = CustomExport()

    var template: ExportTemplate? { ExportTemplate.template(templateID) }

    var variant: ExportTemplate.Variant? {
        template.map { $0.variant(variants[$0.id]) }
    }

    var settings: ExportSettings {
        variant?.settings ?? custom.settings
    }

    /// A short name for the file, so exports for different places don't overwrite each other's names.
    var fileSuffix: String? {
        template?.title.replacingOccurrences(of: " / ", with: " ")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A template that no longer exists falls back to Custom.
        templateID = (try? c.decode(String.self, forKey: .templateID)).flatMap { ExportTemplate.template($0)?.id }
        variants = (try? c.decode([String: String].self, forKey: .variants)) ?? [:]
        custom = (try? c.decode(CustomExport.self, forKey: .custom)) ?? CustomExport()
    }

    private enum CodingKeys: String, CodingKey {
        case templateID, variants, custom
    }

    private static let defaultsKey = "exportChoice"

    static func saved(in defaults: UserDefaults = .standard) -> ExportChoice {
        guard let data = defaults.data(forKey: defaultsKey),
              let choice = try? JSONDecoder().decode(ExportChoice.self, from: data)
        else { return ExportChoice() }
        return choice
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - GIF

/// GIF frame timing. Delays are whole hundredths of a second; rounding each frame's start rather than each
/// delay keeps the total exact (15 fps alternates 7, 7, 6 instead of drifting).
nonisolated enum GIFTiming {
    /// Browsers stretch shorter delays to a tenth of a second, so none goes under this.
    static let minimumDelay = 2

    /// Hundredths of a second between a frame shown at `start` and the next at `end` (seconds).
    static func delay(from start: Double, to end: Double) -> Int {
        max(minimumDelay, Int((end * 100).rounded()) - Int((start * 100).rounded()))
    }
}

/// A rough GIF size, shown before exporting. Each frame only stores the pixels that changed (see
/// `GIFWriter`), so the size depends far more on how much moves than on how long the video is. Measured on
/// exports: a still moment (the pointer, typing, the keys pill) costs a few percent of a whole frame,
/// a zoom easing in or out close to half of one per frame, and a zoom that's settled hardly more than a
/// still moment, until the view pans after the pointer. The camera bubble redraws its own area every frame.
nonisolated enum GIFEstimate {
    /// Bytes per pixel of a whole dithered frame of UI and text on a gradient (about 0.12 measured on a plain
    /// app window; a little more for denser screens). Photos and busy pages cost more, empty ones less.
    static let fullFrameDensity = 0.16
    /// Of a whole frame, per frame: a still moment, a zoom easing in or out, and a settled zoom.
    static let stillShare = 0.04
    static let zoomMovingShare = 0.42
    static let zoomHeldShare = 0.1
    /// Bytes per pixel of the camera's picture, which changes every frame and dithers like a photo.
    static let webcamDensity = 0.7

    /// `zoom`: seconds of the edited video spent easing in or out of a zoom, and settled in one.
    /// `webcamShare`: the part of the frame the camera bubble covers (0 without one).
    static func bytes(size: CGSize, duration: Double, fps: Int, zoom: ZoomTime = ZoomTime(), webcamShare: Double = 0) -> Int {
        let pixels = Double(size.width * size.height)
        let full = pixels * fullFrameDensity
        let rate = Double(max(fps, 1))
        let frames = max(1, (duration * rate).rounded(.up))
        let moving = min(zoom.moving * rate, frames)
        let held = min(zoom.held * rate, frames - moving)
        let still = frames - moving - held
        let changes = full * (still * stillShare + moving * zoomMovingShare + held * zoomHeldShare)
        let webcam = frames * pixels * min(max(webcamShare, 0), 1) * webcamDensity
        return Int(full + changes + webcam) + 1024
    }

    /// Seconds of the edited video (over the kept clips, at their speeds).
    struct ZoomTime: Equatable {
        var moving = 0.0
        var held = 0.0
    }

    /// How long the edited video spends easing into or out of zooms, and settled in them. Zooms close
    /// enough together are merged, as the camera bridges them without zooming out.
    static func zoomTime(
        zooms: [ZoomSegment], segments: [ClipSegment],
        zoomIn: Double = MotionTrack.zoomInDuration, zoomOut: Double = MotionTrack.zoomOutDuration
    ) -> ZoomTime {
        var ranges: [(start: Double, end: Double)] = []
        for zoom in zooms.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, zoom.start <= last.end + zoomOut {
                ranges[ranges.count - 1].end = max(last.end, zoom.end)
            } else {
                ranges.append((zoom.start, zoom.end))
            }
        }
        func kept(_ start: Double, _ end: Double) -> Double {
            guard end > start else { return 0 }
            return segments.reduce(0) { total, segment in
                guard segment.speed > 0 else { return total }
                return total + max(0, min(segment.end, end) - max(segment.start, start)) / segment.speed
            }
        }
        var time = ZoomTime()
        for range in ranges {
            let settled = min(range.start + zoomIn, range.end)
            time.moving += kept(range.start, settled) + kept(range.end, range.end + zoomOut)
            time.held += kept(settled, range.end)
        }
        return time
    }

    /// Size at which GitHub, and many other sites, stop accepting an image.
    static let largeBytes = 10_000_000

    /// "About 3.4 MB": one decimal under 10 MB, whole megabytes above, never "0".
    static func label(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb < 0.1 { return "under 0.1 MB" }
        if mb < 10 { return String(format: "about %.1f MB", mb) }
        return "about \(Int(mb.rounded())) MB"
    }
}
