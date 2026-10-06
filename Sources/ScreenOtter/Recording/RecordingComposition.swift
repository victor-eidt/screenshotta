import AVFoundation

nonisolated enum RecordingCompositionError: LocalizedError {
    case noVideo
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: "The recording has no video."
        case .exportFailed: "The video couldn't be exported."
        }
    }
}

/// The edited recording as one asset, with the composition track each audio source plays on.
nonisolated struct EditedComposition: @unchecked Sendable {
    let asset: AVMutableComposition
    let audioTrackIDs: [AudioSource: CMPersistentTrackID]
    let videoTrackID: CMPersistentTrackID
    /// The camera, cut like the screen, when the recording has one.
    var webcamTrackID: CMPersistentTrackID?
}

/// An audio file of the draft, loaded.
nonisolated struct SourceAudio: @unchecked Sendable {
    let source: AudioSource
    let track: AVAssetTrack
    let duration: Double
}

/// The draft's camera file, loaded.
nonisolated struct SourceWebcam: @unchecked Sendable {
    let track: AVAssetTrack
    let duration: Double
    /// Recording seconds at the file's first frame.
    let offset: Double
}

/// Builds the edited video: the kept clips back to back at their speeds, drawn through the renderer,
/// with each audio file cut the same way.
nonisolated enum RecordingComposition {
    private static let timescale: CMTimeScale = 6000
    private static let videoTrackID: CMPersistentTrackID = 1
    /// An empty track the length of the cut, that the frames are timed by (see `videoComposition`).
    private static let frameTimingTrackID: CMPersistentTrackID = 2
    /// Clips shorter than this (seconds) are left out.
    static let minimumClip = 0.01
    /// Keeps voices at their pitch when a clip is sped up or slowed down.
    static let pitchAlgorithm = AVAudioTimePitchAlgorithm.spectral

    static func make(
        track: AVAssetTrack, trackDuration: Double, segments: [ClipSegment], audio: [SourceAudio] = [], webcam: SourceWebcam? = nil
    ) throws -> EditedComposition {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: videoTrackID),
              let timing = composition.addMutableTrack(withMediaType: .video, preferredTrackID: frameTimingTrackID)
        else {
            throw RecordingCompositionError.noVideo
        }
        try lay(ClipTimeMapping.pieces(segments: segments, videoDuration: trackDuration, fileDuration: trackDuration), of: track, on: video)

        var audioTrackIDs: [AudioSource: CMPersistentTrackID] = [:]
        for source in audio {
            let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: trackDuration, fileDuration: source.duration)
            guard !pieces.isEmpty,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try lay(pieces, of: source.track, on: track)
            audioTrackIDs[source.source] = track.trackID
        }

        // The camera is cut from the same pieces, shifted by when it started, so it stays on the screen's clock.
        var webcamTrackID: CMPersistentTrackID?
        if let webcam {
            let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: trackDuration, fileDuration: webcam.duration, fileOffset: webcam.offset)
            if !pieces.isEmpty, let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try lay(pieces, of: webcam.track, on: track)
                    webcamTrackID = track.trackID
                } catch {
                    // The video still plays without its bubble.
                    composition.removeTrack(track)
                }
            }
        }
        let length = video.timeRange.end
        if length > .zero { timing.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: length)) }
        return EditedComposition(asset: composition, audioTrackIDs: audioTrackIDs, videoTrackID: video.trackID, webcamTrackID: webcamTrackID)
    }

    /// Inserts each piece of `source` at its place in the edited video, at its speed.
    private static func lay(_ pieces: [ClipTimeMapping.Piece], of source: AVAssetTrack, on track: AVMutableCompositionTrack) throws {
        var end = CMTime.zero
        for piece in pieces {
            let at = CMTime(seconds: piece.outputStart, preferredTimescale: timescale)
            // Where a file starts after the clip does (sound that began late), the gap stays empty.
            if at > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
            let range = CMTimeRange(
                start: CMTime(seconds: piece.fileStart, preferredTimescale: timescale),
                end: CMTime(seconds: piece.fileEnd, preferredTimescale: timescale)
            )
            // Pieces follow each other; rounding never leaves a gap or overlap between them.
            let start = max(at, end)
            try track.insertTimeRange(range, of: source, at: start)
            let scaled = CMTime(seconds: piece.outputDuration, preferredTimescale: timescale)
            if piece.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: start, duration: range.duration), toDuration: scaled)
            }
            end = start + scaled
        }
    }

    /// Each source's volume (and mute) applied to its track.
    static func audioMix(_ composition: EditedComposition, volume: (AudioSource) -> Double) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.audioTrackIDs.map { source, trackID in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = trackID
            parameters.audioTimePitchAlgorithm = pitchAlgorithm
            parameters.setVolume(Float(volume(source)), at: .zero)
            return parameters
        }
        return mix
    }

    /// The asset to export: tracks that would only add silence are left out.
    static func exportAsset(_ composition: EditedComposition, volume: (AudioSource) -> Double) -> AVAsset {
        let silent = composition.audioTrackIDs.filter { volume($0.key) <= 0 }.map(\.value)
        guard !silent.isEmpty, let copy = composition.asset.mutableCopy() as? AVMutableComposition else { return composition.asset }
        for trackID in silent {
            if let track = copy.track(withTrackID: trackID) { copy.removeTrack(track) }
        }
        return copy
    }

    /// `timeline` describes the cut in `asset`: frames are drawn with the pointer and camera of exactly that cut.
    /// `composition` names the tracks: the screen, and the webcam when there is one.
    static func videoComposition(
        for asset: AVAsset, composition edited: EditedComposition, timeline: ClipTimeline, renderer: RecordingRenderer, renderSize: CGSize,
        frameRate: Int = 60
    ) async throws -> AVVideoComposition {
        let duration = try await asset.load(.duration)
        // The export asset is a copy of the edited one, with the same track IDs.
        var webcamTrackID: CMPersistentTrackID?
        if let id = edited.webcamTrackID, try await asset.loadTrack(withTrackID: id) != nil { webcamTrackID = id }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = RecordingCompositor.self
        composition.instructions = [RecordingCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            videoTrackID: edited.videoTrackID, webcamTrackID: webcamTrackID, renderer: renderer, timeline: timeline
        )]
        composition.renderSize = renderSize
        // A steady frame rate (60 fps unless an export asks for less) even where the screen (and so the recording)
        // stood still: the pointer and camera keep moving. On its own, frameDuration only caps the rate: frames are
        // drawn when the recording has a new one, and the recording only has one when the screen changed. Over the
        // empty timing track they're drawn at frameDuration.
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
        if try await asset.loadTrack(withTrackID: frameTimingTrackID) != nil {
            composition.sourceTrackIDForFrameTiming = frameTimingTrackID
        }
        return composition
    }

    /// Writes an H.264 MP4, with the sound mixed down to AAC. `progress` is called from a background task.
    static func export(
        _ asset: AVAsset,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix?,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingCompositionError.exportFailed
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.audioTimePitchAlgorithm = pitchAlgorithm
        session.shouldOptimizeForNetworkUse = true

        if #available(macOS 15, *) {
            let monitor = Task {
                for await state in session.states(updateInterval: 0.1) {
                    if case let .exporting(exportProgress) = state { progress(exportProgress.fractionCompleted) }
                }
            }
            defer { monitor.cancel() }
            try await session.export(to: url, as: .mp4)
        } else {
            session.outputURL = url
            session.outputFileType = .mp4
            let monitor = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { monitor.cancel() }
            await session.export()
            if let error = session.error { throw error }
            guard session.status == .completed else { throw RecordingCompositionError.exportFailed }
        }
    }
}
