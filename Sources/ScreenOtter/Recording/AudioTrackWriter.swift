import AVFoundation
import CoreMedia

/// Writes one audio source to an AAC file whose time zero is the first video frame.
/// Not thread-safe: use it from one queue (the recorder's).
nonisolated final class AudioTrackWriter {
    let source: AudioSource
    let url: URL
    let deviceName: String?

    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var failed = false
    /// Set once the file is closed: a buffer that arrives late must not start a new one.
    private var finished = false
    /// Frames in the file so far.
    private(set) var framesWritten: Int64 = 0

    /// Up to this much clock jitter (seconds) is left alone before the writer pads or trims to stay in sync.
    static let tolerance = 0.03
    /// Every file is written at this rate, whatever the device delivers: Apple's AAC encoder only takes
    /// these bit rates at 44.1 and 48 kHz, and headset (16, 24 kHz) or studio (96 kHz) inputs are common.
    static let sampleRate = 48_000.0

    init(source: AudioSource, url: URL, deviceName: String? = nil) {
        self.source = source
        self.url = url
        self.deviceName = deviceName
    }

    /// Adds a buffer that started `time` seconds after the first video frame.
    func append(_ sampleBuffer: CMSampleBuffer, at time: Double) {
        guard !failed, sampleBuffer.isValid, let input = Self.pcmBuffer(from: sampleBuffer) else { return }
        append(input, at: time)
    }

    func append(_ input: AVAudioPCMBuffer, at time: Double) {
        guard !failed, !finished, input.frameLength > 0 else { return }
        do {
            let (file, format) = try open(for: input.format)
            guard let buffer = convert(input, to: format) else { return }
            let rate = format.sampleRate
            let plan = AudioFrameAlignment.plan(
                written: framesWritten,
                incoming: Int64((time * rate).rounded()),
                count: Int64(buffer.frameLength),
                // The first buffer lands exactly; after that, jitter is tolerated.
                tolerance: framesWritten == 0 ? 0 : Int64(Self.tolerance * rate)
            )
            if plan.silence > 0 { try writeSilence(plan.silence, to: file, format: format) }
            if plan.skip >= Int64(buffer.frameLength) { return }
            let kept = plan.skip > 0 ? Self.dropping(Int(plan.skip), from: buffer) : buffer
            try file.write(from: kept)
            framesWritten += Int64(kept.frameLength)
        } catch {
            NSLog("ScreenOtter: could not write \(source.rawValue) audio: \(error)")
            failed = true
        }
    }

    /// Closes the file. Returns the track for the draft, or nil if nothing was recorded.
    func finish() -> RecordedAudioTrack? {
        let wrote = file != nil && framesWritten > 0 && !failed
        finished = true
        // The file is finalized when it's released.
        file = nil
        converter = nil
        guard wrote else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return RecordedAudioTrack(source: source, file: url.lastPathComponent, deviceName: deviceName)
    }

    // MARK: - File

    /// The file is created with the first buffer: its channels (at most two) follow the source, its rate is fixed.
    private func open(for input: AVAudioFormat) throws -> (AVAudioFile, AVAudioFormat) {
        if let file, let format { return (file, format) }
        let channels = min(max(input.channelCount, 1), 2)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: channels) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.file = file
        self.format = format
        return (file, format)
    }

    private func writeSilence(_ frames: Int64, to file: AVAudioFile, format: AVAudioFormat) throws {
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        var left = frames
        while left > 0 {
            let count = AVAudioFrameCount(min(Int64(chunk), left))
            silence.frameLength = count
            for channel in 0..<Int(format.channelCount) {
                silence.floatChannelData?[channel].update(repeating: 0, count: Int(count))
            }
            try file.write(from: silence)
            framesWritten += Int64(count)
            left -= Int64(count)
        }
    }

    // MARK: - Buffers

    /// Converts to the file's processing format when the source differs (another rate, integer samples,
    /// interleaved, more channels).
    private func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// The buffer without its first `count` frames. Buffers here are always deinterleaved float.
    private static func dropping(_ count: Int, from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let remaining = Int(buffer.frameLength) - count
        guard remaining > 0, let source = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(remaining)),
              let destination = output.floatChannelData
        else { return buffer }
        output.frameLength = AVAudioFrameCount(remaining)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + count, count: remaining)
        }
        return output
    }
}
