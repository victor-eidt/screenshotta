import AppKit
import AVFoundation

/// The Mac's microphones, and permission to use them.
enum Microphones {
    struct Device: Identifiable, Hashable {
        /// `AVCaptureDevice.uniqueID`, which is also what ScreenCaptureKit takes.
        let id: String
        let name: String
    }

    static func all() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen microphone, or the system's input when it's nil or no longer plugged in.
    nonisolated static func device(id: String?) -> AVCaptureDevice? {
        id.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
    }

    /// The microphone that records, among `devices`, picked the way `device(id:)` picks it for capture:
    /// the saved one while it's plugged in, else the system's input.
    static func recording(saved: String?, systemDefault: String?, in devices: [Device]) -> Device? {
        devices.first { $0.id == saved } ?? devices.first { $0.id == systemDefault } ?? devices.first
    }

    static func recording(saved: String?, in devices: [Device]) -> Device? {
        recording(saved: saved, systemDefault: device(id: nil)?.uniqueID, in: devices)
    }

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Asks the first time; afterwards answers with what the user decided.
    static func requestAccess() async -> Bool {
        switch authorization {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What to record besides the screen, decided when recording starts.
nonisolated struct AudioCaptureOptions: Sendable {
    var systemAudio = false
    /// The microphone to record, or nil for none.
    var microphone: Microphone?

    struct Microphone: Sendable {
        /// nil records the system's default input.
        var deviceID: String?
        var name: String?
    }

    /// The options in Preferences. The microphone is left out when access is denied (the recording goes on
    /// without it; the options bar and Settings say why).
    @MainActor static func current() async -> AudioCaptureOptions {
        let prefs = Preferences.shared
        var options = AudioCaptureOptions(systemAudio: prefs.recordSystemAudio)
        if prefs.recordMicrophone, await Microphones.requestAccess(), let device = Microphones.device(id: prefs.microphoneID) {
            options.microphone = Microphone(deviceID: device.uniqueID, name: device.localizedName)
        }
        return options
    }
}

/// Records the microphone with AVCaptureSession, for macOS 14 where ScreenCaptureKit can't.
/// Buffers are handed over with their time on the host clock, the clock the video frames use.
nonisolated final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let handler: (CMSampleBuffer, Double) -> Void

    /// `handler` runs on `queue` with each buffer and its host time in seconds.
    init(deviceID: String?, queue: DispatchQueue, handler: @escaping (CMSampleBuffer, Double) -> Void) throws {
        self.handler = handler
        super.init()
        guard let device = Microphones.device(id: deviceID) else { throw CocoaError(.featureUnsupported) }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CocoaError(.featureUnsupported)
        }
        session.addInput(input)
        session.addOutput(output)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
    }

    /// Blocks until the session runs; call off the main thread.
    func start() { session.startRunning() }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let host = CMClockGetHostTimeClock()
        var time = sampleBuffer.presentationTimeStamp
        if let clock = session.synchronizationClock {
            time = CMSyncConvertTime(time, from: clock, to: host)
        }
        handler(sampleBuffer, time.seconds)
    }
}
