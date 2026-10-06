import AVFoundation
import ScreenCaptureKit
import VideoToolbox

nonisolated enum RecordingError: LocalizedError {
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noFrames: "Nothing was recorded."
        }
    }
}

/// Streams the screen with ScreenCaptureKit into a HEVC movie. The pointer is left out:
/// the editor draws its own, so it can be smoothed, resized and followed by the camera.
/// System audio and the microphone go to files of their own, on the video's clock.
nonisolated final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Result {
        /// Host time of the first frame, in seconds. Pointer samples are measured from it.
        var startHostTime: Double
        var duration: Double
        var audio: [RecordedAudioTrack]
    }

    /// Called on a background queue when the stream stops by itself (the window closed, permission revoked).
    var onFailure: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.victor.screenotter.recorder")
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var firstTime: CMTime?
    private var startHostTime: Double?
    private var lastTime = CMTime.zero
    private var audioWriters: [AudioSource: AudioTrackWriter] = [:]
    /// macOS 14 records the microphone outside ScreenCaptureKit.
    private var microphoneCapture: MicrophoneCapture?

    /// `audioURL` gives the file each audio source is written to.
    init(
        filter: SCContentFilter, configuration: SCStreamConfiguration, outputURL: URL, alpha: Bool,
        audio: AudioCaptureOptions, audioURL: (AudioSource) -> URL
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let pixels = configuration.width * configuration.height
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: min(max(pixels * 6, 8_000_000), 120_000_000),
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if alpha {
            compression[kVTCompressionPropertyKey_AlphaChannelMode as String] = kVTAlphaChannelMode_PremultipliedAlpha
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
        if audio.systemAudio {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            audioWriters[.system] = AudioTrackWriter(source: .system, url: audioURL(.system))
        }
        var microphoneThroughStream = false
        if let microphone = audio.microphone {
            let writer = AudioTrackWriter(source: .microphone, url: audioURL(.microphone), deviceName: microphone.name)
            if #available(macOS 15, *) {
                configuration.captureMicrophone = true
                configuration.microphoneCaptureDeviceID = microphone.deviceID
                microphoneThroughStream = true
                audioWriters[.microphone] = writer
            } else {
                // The recording goes on without the microphone if it can't be opened.
                do {
                    microphoneCapture = try MicrophoneCapture(deviceID: microphone.deviceID, queue: queue) { [weak self] buffer, hostTime in
                        self?.appendAudio(buffer, source: .microphone, hostTime: hostTime)
                    }
                    audioWriters[.microphone] = writer
                } catch {
                    NSLog("ScreenOtter: could not start the microphone: \(error)")
                }
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if #available(macOS 15, *), microphoneThroughStream {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
    }

    static func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Video encoders want even dimensions.
        config.width = max(2, width / 2 * 2)
        config.height = max(2, height / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 8
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.captureResolution = .best
        return config
    }

    func start() async throws {
        if let microphoneCapture {
            await Task.detached { microphoneCapture.start() }.value
        }
        do {
            try await stream?.startCapture()
        } catch {
            microphoneCapture?.stop()
            throw error
        }
    }

    func stop() async throws -> Result {
        try? await stream?.stopCapture()
        // Read before the microphone stops: that can take a moment on macOS 14, and the video would hold its last frame for it.
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        if let microphoneCapture {
            await Task.detached { microphoneCapture.stop() }.value
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let audio = AudioSource.allCases.compactMap { audioWriters[$0]?.finish() }
                guard let firstTime, let startHostTime else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecordingError.noFrames)
                    return
                }
                input.markAsFinished()
                // Hold the last frame until the moment recording stopped (the screen may have been still).
                let elapsed = CMTime(seconds: end.seconds - startHostTime, preferredTimescale: 1_000_000_000)
                let endTime = CMTimeMaximum(lastTime, firstTime + elapsed)
                writer.endSession(atSourceTime: endTime)
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: Result(startHostTime: startHostTime, duration: (endTime - firstTime).seconds, audio: audio))
                    } else {
                        continuation.resume(throwing: writer.error ?? RecordingError.noFrames)
                    }
                }
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            appendAudio(sampleBuffer, source: .system, hostTime: sampleBuffer.presentationTimeStamp.seconds)
            return
        }
        if #available(macOS 15, *), type == .microphone {
            appendAudio(sampleBuffer, source: .microphone, hostTime: sampleBuffer.presentationTimeStamp.seconds)
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete
        else { return }

        let time = sampleBuffer.presentationTimeStamp
        if firstTime == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            firstTime = time
            // Frame times are host times; if they ever aren't, fall back to when the frame arrived.
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            startHostTime = abs(time.seconds - now) < 1 ? time.seconds : now
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            lastTime = time
        }
    }

    /// Sound before the first video frame is dropped: the files start where the video does.
    private func appendAudio(_ sampleBuffer: CMSampleBuffer, source: AudioSource, hostTime: Double) {
        guard let startHostTime, let writer = audioWriters[source] else { return }
        // Buffer times are host times; if they ever aren't, fall back to when the buffer arrived.
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let start = abs(hostTime - now) < 2 ? hostTime : now - sampleBuffer.duration.seconds
        writer.append(sampleBuffer, at: start - startHostTime)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }
}
