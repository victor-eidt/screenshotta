import Foundation

/// Where a recorded sound came from. Each source is its own file in the draft, so it can be edited on its own.
/// Cases are in display order: microphone first, it's the voice of the video.
nonisolated enum AudioSource: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case microphone
    case system

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .system: "System Audio"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .system: "speaker.wave.2.fill"
        }
    }

    /// The file it is recorded to, inside the draft folder.
    var fileName: String {
        switch self {
        case .microphone: "microphone.m4a"
        case .system: "system-audio.m4a"
        }
    }
}

/// An audio file recorded with the video. Its time zero is the first video frame, the same origin
/// the pointer track uses, so source seconds mean the same moment in all of them.
nonisolated struct RecordedAudioTrack: Codable, Equatable, Sendable {
    var source: AudioSource
    /// File name inside the draft folder.
    var file: String
    /// The microphone's name, for the editor.
    var deviceName: String?
}

/// How loud one track plays in the edited video.
nonisolated struct AudioTrackMix: Codable, Equatable, Sendable {
    /// 0...1.
    var volume: Double = 1
    var isMuted = false

    /// What the video hears: muted is silent.
    var effectiveVolume: Double { isMuted ? 0 : min(max(volume, 0), 1) }

    /// Voice first: next to a microphone, app sounds start quieter so they don't cover the narration.
    static func initial(for source: AudioSource, alongside sources: [AudioSource]) -> AudioTrackMix {
        switch source {
        case .microphone: AudioTrackMix(volume: 1)
        case .system: AudioTrackMix(volume: sources.contains(.microphone) ? 0.5 : 1)
        }
    }
}

nonisolated extension RecordingEdits {
    /// The mix of `source`, or its initial mix if it was never changed.
    func audioMix(for source: AudioSource, alongside sources: [AudioSource]) -> AudioTrackMix {
        audio?[source] ?? .initial(for: source, alongside: sources)
    }
}

// MARK: - Time mapping

/// Lays a recorded file out on the edited video: which part of it plays where, and how fast. The video and
/// every audio file are cut from the same pieces, so sound and picture can't drift apart.
nonisolated enum ClipTimeMapping {
    struct Piece: Equatable, Sendable {
        /// Seconds in the file (which are also recording seconds).
        var fileStart: Double
        var fileEnd: Double
        /// Where it starts in the final video.
        var outputStart: Double
        var speed: Double

        var outputDuration: Double { (fileEnd - fileStart) / speed }
    }

    /// The pieces of a file `fileDuration` long that play in the cut made of `segments`: clips are clamped
    /// to the video and slivers are dropped. For the video itself, `fileDuration` is `videoDuration`.
    static func pieces(segments: [ClipSegment], videoDuration: Double, fileDuration: Double) -> [Piece] {
        var pieces: [Piece] = []
        var output = 0.0
        for segment in segments {
            let start = min(segment.start, videoDuration)
            let end = min(segment.end, videoDuration)
            guard end - start > RecordingComposition.minimumClip, segment.speed > 0 else { continue }
            let fileStart = max(start, 0)
            let fileEnd = min(end, fileDuration)
            if fileEnd - fileStart > 0.001 {
                pieces.append(Piece(
                    fileStart: fileStart, fileEnd: fileEnd,
                    outputStart: output + (fileStart - start) / segment.speed,
                    speed: segment.speed
                ))
            }
            output += (end - start) / segment.speed
        }
        return pieces
    }
}

// MARK: - Capture alignment

/// Keeps a recorded audio file on the video's clock. Sound may start late, pause (system audio sends nothing
/// while the Mac is silent) or drift from the screen's clock: gaps are filled with silence and overlaps are
/// dropped, so frame N of the file is always N / rate seconds after the first video frame.
nonisolated enum AudioFrameAlignment {
    struct Plan: Equatable, Sendable {
        /// Silent frames to write before the buffer.
        var silence: Int64 = 0
        /// Frames to drop from the start of the buffer.
        var skip: Int64 = 0
    }

    /// `written` frames are in the file; the next buffer of `count` frames belongs at frame `incoming`.
    /// Differences within `tolerance` are left alone, so clock jitter doesn't chop the sound.
    static func plan(written: Int64, incoming: Int64, count: Int64, tolerance: Int64) -> Plan {
        let gap = incoming - written
        if gap > tolerance { return Plan(silence: gap) }
        if gap < -tolerance { return Plan(skip: min(-gap, count)) }
        return Plan()
    }
}

// MARK: - Waveform

/// The loudness of a track over time, coarse enough to draw: one peak per bucket, in recording seconds.
nonisolated struct AudioWaveform: Equatable, Sendable {
    static let bucketsPerSecond = 50.0

    /// Linear peaks, 0...1.
    var peaks: [Float]

    var duration: Double { Double(peaks.count) / Self.bucketsPerSecond }

    /// Several tracks as the mix hears them: per bucket, the loudest track at its volume.
    static func mixed(_ tracks: [(waveform: AudioWaveform, volume: Double)]) -> AudioWaveform {
        let audible = tracks.filter { $0.volume > 0 }
        let count = audible.map(\.waveform.peaks.count).max() ?? 0
        var peaks = [Float](repeating: 0, count: count)
        for (waveform, volume) in audible {
            for (index, peak) in waveform.peaks.enumerated() {
                peaks[index] = max(peaks[index], peak * Float(volume))
            }
        }
        return AudioWaveform(peaks: peaks)
    }

    /// `count` display levels (0...1) across `start...end` recording seconds: the loudest bucket under each.
    func levels(from start: Double, to end: Double, count: Int) -> [Float] {
        guard count > 0, end > start else { return [] }
        let step = (end - start) / Double(count)
        return (0..<count).map { index in
            // The epsilon keeps rounding noise from pulling in a neighbouring bucket.
            let from = Int(((start + Double(index) * step) * Self.bucketsPerSecond + 1e-6).rounded(.down))
            let to = max(from + 1, Int(((start + Double(index + 1) * step) * Self.bucketsPerSecond - 1e-6).rounded(.up)))
            let lower = max(from, 0), upper = min(to, peaks.count)
            guard lower < upper else { return 0 }
            return Self.displayLevel(peaks[lower..<upper].max() ?? 0)
        }
    }

    /// Peaks on a decibel scale, so speech reads as speech and not as a few spikes. -48 dB and below is flat.
    static func displayLevel(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return min(max((decibels + 48) / 48, 0), 1)
    }
}
