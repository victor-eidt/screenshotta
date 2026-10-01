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

/// Builds the edited video: the kept clips back to back at their speeds, drawn through the renderer.
nonisolated enum RecordingComposition {
    private static let timescale: CMTimeScale = 6000

    static func make(track: AVAssetTrack, trackDuration: Double, segments: [ClipSegment]) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingCompositionError.noVideo
        }
        var cursor = CMTime.zero
        for segment in segments {
            let start = CMTime(seconds: min(segment.start, trackDuration), preferredTimescale: timescale)
            let end = CMTime(seconds: min(segment.end, trackDuration), preferredTimescale: timescale)
            let range = CMTimeRange(start: start, end: end)
            guard range.duration.seconds > 0.01 else { continue }
            try video.insertTimeRange(range, of: track, at: cursor)
            let scaled = CMTime(seconds: range.duration.seconds / segment.speed, preferredTimescale: timescale)
            if segment.speed != 1 {
                video.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
            }
            cursor = cursor + scaled
        }
        return composition
    }

    static func videoComposition(for asset: AVAsset, renderer: RecordingRenderer, renderSize: CGSize) async throws -> AVVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: handler(renderer))
        composition.renderSize = renderSize
        // A steady 60 fps even where the screen (and so the recording) stood still: the pointer and camera keep moving.
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        return composition
    }

    private static func handler(_ renderer: RecordingRenderer) -> @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void {
        { request in
            let image = renderer.render(source: request.sourceImage, outputTime: request.compositionTime.seconds, renderSize: request.renderSize)
            request.finish(with: image, context: RecordingRenderer.context)
        }
    }

    /// Writes an H.264 MP4. `progress` is called from a background task.
    static func export(
        _ asset: AVAsset,
        videoComposition: AVVideoComposition,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingCompositionError.exportFailed
        }
        session.videoComposition = videoComposition
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
