import AVFoundation

nonisolated extension AudioWaveform {
    /// Reads a recorded audio file into its waveform. Runs off the main actor; a few seconds of work for an hour of sound.
    @concurrent static func load(_ url: URL) async -> AudioWaveform? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        let rate = 48_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let framesPerBucket = Int(rate / bucketsPerSecond)
        var peaks: [Float] = []
        var current: Float = 0
        var filled = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = buffer.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in data {
                current = max(current, abs(sample))
                filled += 1
                if filled == framesPerBucket {
                    peaks.append(min(current, 1))
                    current = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { peaks.append(min(current, 1)) }
        guard reader.status == .completed else { return nil }
        return AudioWaveform(peaks: peaks)
    }
}
