import AVFoundation
import CoreImage

/// The one instruction of an edited video: draw every frame through the renderer, from the screen track and,
/// when there is one, the webcam track. Carries the cut it was made for, so the pointer and camera match
/// the frames being drawn.
nonisolated final class RecordingCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// The pointer and camera move even while the recording stands still: every frame is drawn.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let videoTrackID: CMPersistentTrackID
    let webcamTrackID: CMPersistentTrackID?
    let renderer: RecordingRenderer
    let timeline: ClipTimeline

    init(timeRange: CMTimeRange, videoTrackID: CMPersistentTrackID, webcamTrackID: CMPersistentTrackID?, renderer: RecordingRenderer, timeline: ClipTimeline) {
        self.timeRange = timeRange
        self.videoTrackID = videoTrackID
        self.webcamTrackID = webcamTrackID
        self.renderer = renderer
        self.timeline = timeline
        requiredSourceTrackIDs = ([videoTrackID] + (webcamTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// Composes frames with Core Image: the screen and webcam frames go through `RecordingRenderer`.
/// Created by AVFoundation, which calls it from its own queues.
nonisolated final class RecordingCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Frames are drawn in sRGB, the space the screen is captured in, and tagged so (Rec. 709 primaries with
    /// the sRGB curve): colors come out exactly as they did through Core Image's own filtering handler.
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? RecordingCompositionInstruction,
              let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: RecordingCompositionError.exportFailed)
            return
        }
        let renderer = instruction.renderer
        let source = request.sourceFrame(byTrackID: instruction.videoTrackID).map { CIImage(cvPixelBuffer: $0) }
            ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderer.currentScene.sourceSize))
        let webcam = instruction.webcamTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map { CIImage(cvPixelBuffer: $0) }
        let size = request.renderContext.size
        let image = renderer.render(
            source: source, webcam: webcam, outputTime: request.compositionTime.seconds,
            timeline: instruction.timeline, renderSize: size
        )
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        RecordingRenderer.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}
