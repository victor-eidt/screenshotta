import AppKit
import AVFoundation

/// The Mac's cameras, and permission to use them.
enum Webcams {
    struct Device: Identifiable, Hashable {
        /// `AVCaptureDevice.uniqueID`.
        let id: String
        let name: String
    }

    static func all() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen camera, or the system's default when it's nil or no longer connected.
    nonisolated static func device(id: String?) -> AVCaptureDevice? {
        id.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
    }

    /// The camera that records, among `devices`: the saved one while it's connected, else the default.
    static func recording(saved: String?, systemDefault: String?, in devices: [Device]) -> Device? {
        devices.first { $0.id == saved } ?? devices.first { $0.id == systemDefault } ?? devices.first
    }

    static func recording(saved: String?, in devices: [Device]) -> Device? {
        recording(saved: saved, systemDefault: device(id: nil)?.uniqueID, in: devices)
    }

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Asks the first time; afterwards answers with what the user decided.
    static func requestAccess() async -> Bool {
        switch authorization {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Recording

/// Records the camera to a movie of its own while the screen records. Frames are stamped with the host
/// clock (the one screen frames use), and the movie's time zero is its first frame: the draft stores where
/// that falls on the screen's timeline, so the editor can line the two up.
nonisolated final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Shared with the live preview.
    let session = AVCaptureSession()
    var url: URL { file.url }

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.victor.screenotter.webcam")
    /// Only touched on `queue`.
    private let file: WebcamFileWriter
    private var isWriting = false

    init(deviceID: String?, url: URL) throws {
        file = WebcamFileWriter(url: url)
        super.init()
        guard let device = Webcams.device(id: deviceID) else { throw CocoaError(.featureUnsupported) }
        let deviceInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addInput(deviceInput)
        session.addOutput(output)
        // 720p is plenty for a bubble, even in a 4K export, and keeps the file small.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Blocks until the camera runs; call off the main thread.
    func start() { session.startRunning() }

    /// From now on, frames go to the file (before, they only feed the preview).
    func beginWriting() {
        queue.async { self.isWriting = true }
    }

    /// Stops the camera and closes the file. Returns the host time of its first frame, or nil when nothing
    /// was recorded.
    func finish() async -> Double? {
        session.stopRunning()
        let finishing: WebcamFileWriter = await withCheckedContinuation { continuation in
            queue.async { [self] in
                isWriting = false
                continuation.resume(returning: file)
            }
        }
        return await finishing.finish()
    }

    /// Stops without keeping anything.
    func cancel() {
        session.stopRunning()
        queue.async { [self] in
            isWriting = false
            file.cancel()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isWriting, let pixels = sampleBuffer.imageBuffer else { return }
        var time = sampleBuffer.presentationTimeStamp
        if let clock = session.synchronizationClock {
            time = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
        }
        file.append(pixels, at: time)
    }
}

/// Writes camera frames to an H.264 movie whose time zero is the first frame.
/// Not thread-safe: use it from one queue (the recorder's), then `finish` once.
nonisolated final class WebcamFileWriter: @unchecked Sendable {
    let url: URL

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// Time of the first frame, in the clock the frames came with.
    private(set) var firstTime: CMTime?
    private var lastTime = CMTime.invalid
    private var failed = false
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    /// Adds a frame; frames that aren't later than the last one are dropped. The file opens with the first
    /// frame, at its size.
    func append(_ pixels: CVPixelBuffer, at time: CMTime) {
        guard !failed, !finished, time.isValid else { return }
        if writer == nil {
            do {
                try open(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), at: time)
            } catch {
                NSLog("ScreenOtter: could not record the camera: \(error)")
                failed = true
                return
            }
        }
        guard let input, let adaptor, input.isReadyForMoreMediaData, !lastTime.isValid || time > lastTime else { return }
        if adaptor.append(pixels, withPresentationTime: time) {
            lastTime = time
        } else if writer?.status == .failed {
            NSLog("ScreenOtter: could not record the camera: \(writer?.error as Any)")
            failed = true
        }
    }

    /// Closes the file. Returns the first frame's time in seconds, or nil (and no file) when nothing was recorded.
    func finish() async -> Double? {
        finished = true
        guard let writer, let input, let firstTime, !failed, writer.status == .writing else {
            cancel()
            return nil
        }
        input.markAsFinished()
        // The last frame shows for one frame's time, not zero.
        writer.endSession(atSourceTime: lastTime + CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return firstTime.seconds
    }

    func cancel() {
        finished = true
        if writer?.status == .writing { writer?.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    private func open(width: Int, height: Int, at time: CMTime) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(max(width * height * 6, 2_000_000), 12_000_000),
                AVVideoExpectedSourceFrameRateKey: 30,
                // Frequent keyframes and no reordering keep scrubbing in the editor quick.
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        firstTime = time
    }
}

/// The camera to record, decided when recording starts.
struct WebcamCaptureOptions {
    var deviceID: String
    var name: String

    /// The camera in Preferences, or nil when it's off, not allowed or not connected (the recording goes on
    /// without it; the options bar and Settings say why).
    static func current() async -> WebcamCaptureOptions? {
        let prefs = Preferences.shared
        guard prefs.recordCamera, await Webcams.requestAccess(), let device = Webcams.device(id: prefs.cameraID) else { return nil }
        return WebcamCaptureOptions(deviceID: device.uniqueID, name: device.localizedName)
    }
}

/// One recording's camera: the recorder and the live bubble that shows what it sees.
final class WebcamSession {
    private let recorder: WebcamRecorder
    private let deviceName: String
    private var preview: WebcamPreviewPanel?

    private init(recorder: WebcamRecorder, deviceName: String) {
        self.recorder = recorder
        self.deviceName = deviceName
    }

    /// Opens the camera and shows its bubble on `screen`. Nil when the camera is off or can't be opened:
    /// the recording goes on without it.
    static func start(writingTo url: URL, on screen: NSScreen?) async -> WebcamSession? {
        guard let options = await WebcamCaptureOptions.current() else { return nil }
        do {
            let recorder = try WebcamRecorder(deviceID: options.deviceID, url: url)
            await Task.detached { recorder.start() }.value
            let session = WebcamSession(recorder: recorder, deviceName: options.name)
            let preview = WebcamPreviewPanel(session: recorder.session, style: RecordingStyle.lastUsed.webcam, screen: screen ?? NSScreen.main)
            preview.present()
            session.preview = preview
            return session
        } catch {
            NSLog("ScreenOtter: could not start the camera: \(error)")
            return nil
        }
    }

    func beginWriting() {
        recorder.beginWriting()
    }

    /// Closes the file. `screenStart` is the host time of the first screen frame.
    func finish(screenStart: Double) async -> RecordedWebcam? {
        dismissPreview()
        let recorder = recorder
        guard let first = await Task.detached(operation: { await recorder.finish() }).value else { return nil }
        return RecordedWebcam(file: recorder.url.lastPathComponent, deviceName: deviceName, offset: first - screenStart)
    }

    func cancel() {
        dismissPreview()
        let recorder = recorder
        Task.detached { recorder.cancel() }
    }

    func dismissPreview() {
        preview?.dismiss()
        preview = nil
    }
}

// MARK: - Live preview

/// Where the live bubble sits on screen while recording: placed like the bubble in the video (the same
/// shape, relative size and spot), so what you see is where it ends up.
nonisolated enum WebcamPreviewLayout {
    /// Space between the bubble and the edges of the screen's visible area, in points.
    static let margin: CGFloat = 28

    /// The bubble's height on screen for each size, in points.
    static func height(_ size: WebcamSize) -> CGFloat {
        switch size {
        case .small: 120
        case .medium: 148
        case .large: 180
        }
    }

    /// The bubble on a screen whose visible area is `visible`, in AppKit coordinates (origin at the bottom):
    /// positioned across the room between the margins as `style.x` and `style.y` place it in the video.
    static func bubble(_ style: WebcamStyle, visible: CGRect) -> CGRect {
        let height = height(style.size)
        let width = (height * style.shape.aspect).rounded()
        let roomX = max(visible.width - margin * 2 - width, 0)
        let roomY = max(visible.height - margin * 2 - height, 0)
        let x = CGFloat(min(max(style.x, 0), 1))
        let y = CGFloat(min(max(style.y, 0), 1))
        return CGRect(
            x: (visible.minX + margin + roomX * x).rounded(),
            // The style counts y from the top.
            y: (visible.maxY - margin - height - roomY * y).rounded(),
            width: width,
            height: height
        )
    }
}

/// A small floating bubble with the camera's live picture while recording, in the bubble's own shape, size
/// and spot. ScreenOtter's panels are left out of the recording, so it never shows up twice. Drag it anywhere.
final class WebcamPreviewPanel: NSPanel {
    init(session: AVCaptureSession, style: WebcamStyle, screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let bubble = WebcamPreviewLayout.bubble(style, visible: visible)
        let room = WebcamArt.shadowPadding(forHeight: bubble.height)
        super.init(contentRect: bubble.insetBy(dx: -room, dy: -room), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let video = AVCaptureVideoPreviewLayer(session: session)
        video.videoGravity = .resizeAspectFill
        video.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        if let connection = video.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = style.mirror
        }
        contentView = WebcamPreviewView(bubble: Self.bubbleLayer(
            content: video, style: style, frame: CGRect(origin: CGPoint(x: room, y: room), size: bubble.size)
        ))
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }

    func present() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { self.orderOut(nil) }
        }
    }

    /// `content` cut to the bubble's shape at `frame`, with the ring and shadow the export draws (from the
    /// same `WebcamArt` measures), each only when the style has it.
    static func bubbleLayer(content: CALayer, style: WebcamStyle, frame: CGRect) -> CALayer {
        let bounds = CGRect(origin: .zero, size: frame.size)
        // Shapes are drawn top-left; layers count from the bottom.
        var flip = CGAffineTransform(translationX: 0, y: frame.height).scaledBy(x: 1, y: -1)
        let outline = style.shape.path(in: bounds).copy(using: &flip)

        let container = CALayer()
        container.frame = frame
        if style.shadow {
            for shadow in WebcamArt.shadows(forHeight: frame.height) {
                let layer = CALayer()
                layer.frame = bounds
                layer.shadowPath = outline
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = Float(shadow.alpha)
                // Core Animation's radius blurs about twice as wide as Core Graphics' blur.
                layer.shadowRadius = shadow.blur / 2
                layer.shadowOffset = CGSize(width: 0, height: -shadow.offset)
                container.addSublayer(layer)
            }
        }

        content.frame = bounds
        let mask = CAShapeLayer()
        mask.path = outline
        content.mask = mask
        container.addSublayer(content)

        if style.border {
            let ring = CAShapeLayer()
            ring.path = outline
            ring.fillColor = nil
            ring.strokeColor = NSColor.white.withAlphaComponent(WebcamArt.ringAlpha).cgColor
            // Twice as wide, half of it clipped away: the ring sits inside the edge, as in the export.
            ring.lineWidth = WebcamArt.ringWidth(forHeight: frame.height) * 2
            ring.mask = { let m = CAShapeLayer(); m.path = outline; return m }()
            container.addSublayer(ring)
        }
        return container
    }
}

private final class WebcamPreviewView: NSView {
    init(bubble: CALayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(bubble)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
}
