import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ScreenOtter

@Suite struct WebcamLayoutTests {
    private let canvas = CGSize(width: 1920, height: 1080)

    private func style(_ corner: WebcamCorner, size: WebcamSize = .medium, shape: WebcamShape = .circle) -> WebcamStyle {
        var style = WebcamStyle()
        style.shape = shape
        style.size = size
        style.x = corner.position.x
        style.y = corner.position.y
        return style
    }

    @Test func cornersSitOnTheMargins() {
        let margin = (WebcamLayout.margin * 1080).rounded()
        let topLeft = WebcamLayout.frame(style(.topLeft), canvas: canvas)
        #expect(topLeft.minX == margin && topLeft.minY == margin)
        let bottomRight = WebcamLayout.frame(style(.bottomRight), canvas: canvas)
        #expect(bottomRight.maxX == canvas.width - margin && bottomRight.maxY == canvas.height - margin)
        let topRight = WebcamLayout.frame(style(.topRight), canvas: canvas)
        #expect(topRight.maxX == canvas.width - margin && topRight.minY == margin)
    }

    @Test func sizeFollowsTheShorterSideAndTheShapesAspect() {
        for size in WebcamSize.allCases {
            let circle = WebcamLayout.frame(style(.bottomRight, size: size), canvas: canvas)
            #expect(circle.height == (size.fraction * 1080).rounded())
            #expect(circle.width == circle.height)
            // A vertical video sizes from its width: the bubble is the same size either way.
            let vertical = WebcamLayout.frame(style(.bottomRight, size: size), canvas: CGSize(width: 1080, height: 1920))
            #expect(vertical.size == circle.size)
        }
        let pebble = WebcamLayout.frame(style(.bottomRight, shape: .pebble), canvas: canvas)
        #expect(abs(pebble.width / pebble.height - WebcamShape.pebble.aspect) < 0.01)
        #expect(WebcamSize.small.fraction < WebcamSize.medium.fraction && WebcamSize.medium.fraction < WebcamSize.large.fraction)
    }

    @Test func aTinyCanvasStillFitsTheBubble() {
        let tiny = CGSize(width: 120, height: 40)
        let frame = WebcamLayout.frame(style(.bottomRight, size: .large, shape: .pebble), canvas: tiny)
        #expect(CGRect(origin: .zero, size: tiny).contains(frame))
    }

    @Test func draggingRoundTripsThroughThePosition() {
        var moved = style(.topLeft)
        let target = CGPoint(x: 700, y: 300)
        let position = WebcamLayout.position(origin: target, style: moved, canvas: canvas)
        moved.x = position.x
        moved.y = position.y
        let frame = WebcamLayout.frame(moved, canvas: canvas)
        #expect(abs(frame.minX - target.x) <= 1 && abs(frame.minY - target.y) <= 1)
    }

    @Test func draggingPastTheEdgeStopsAtTheMargin() {
        let position = WebcamLayout.position(origin: CGPoint(x: -500, y: 5000), style: style(.topLeft), canvas: canvas)
        #expect(position.x == 0 && position.y == 1)
    }

    @Test func dropsNearACornerSnapIntoIt() {
        #expect(WebcamLayout.snapped((0.95, 0.97)) == (1, 1))
        #expect(WebcamLayout.snapped((0.04, 0.93)) == (0, 1))
        let free = WebcamLayout.snapped((0.5, 0.95))
        #expect(free.x == 0.5 && free.y == 0.95)
        #expect(WebcamLayout.corner(of: style(.bottomLeft)) == .bottomLeft)
        var between = style(.bottomLeft)
        between.x = 0.4
        #expect(WebcamLayout.corner(of: between) == nil)
    }

    @Test func zoomProgressEasesInEarlyAndHolds() {
        #expect(WebcamLayout.zoomProgress(scale: 1) == 0)
        #expect(WebcamLayout.zoomProgress(scale: 0.9) == 0)
        #expect(WebcamLayout.zoomProgress(scale: 1.35) == 1)
        #expect(WebcamLayout.zoomProgress(scale: 3) == 1)
        let steps = stride(from: 1.0, through: 1.4, by: 0.02).map { WebcamLayout.zoomProgress(scale: $0) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func shrinkingTucksTheBubbleIntoItsCorner() {
        let resting = style(.bottomRight)
        let rest = WebcamLayout.frame(resting, canvas: canvas)
        let zoomed = WebcamLayout.presentation(resting, canvas: canvas, zoomScale: 2)
        #expect(zoomed.opacity == 1)
        #expect(abs(zoomed.frame.width - rest.width * WebcamLayout.shrunkScale) < 0.001)
        // The outer corner stays put.
        #expect(abs(zoomed.frame.maxX - rest.maxX) < 0.001 && abs(zoomed.frame.maxY - rest.maxY) < 0.001)

        let topLeft = style(.topLeft)
        let shrunk = WebcamLayout.presentation(topLeft, canvas: canvas, zoomScale: 2).frame
        let topLeftRest = WebcamLayout.frame(topLeft, canvas: canvas)
        #expect(abs(shrunk.minX - topLeftRest.minX) < 0.001 && abs(shrunk.minY - topLeftRest.minY) < 0.001)
    }

    @Test func hideFadesOutAndKeepStaysPut() {
        var hidden = style(.bottomRight)
        hidden.duringZoom = .hide
        #expect(WebcamLayout.presentation(hidden, canvas: canvas, zoomScale: 2).opacity == 0)
        #expect(WebcamLayout.presentation(hidden, canvas: canvas, zoomScale: 1).opacity == 1)

        var kept = style(.bottomRight)
        kept.duringZoom = .keep
        let zoomed = WebcamLayout.presentation(kept, canvas: canvas, zoomScale: 2)
        #expect(zoomed.frame == WebcamLayout.frame(kept, canvas: canvas) && zoomed.opacity == 1)
    }

    @Test func cameraFramesFillTheBubbleCenteredAndCropped() {
        let fill = WebcamLayout.fill(source: CGSize(width: 1280, height: 720), into: CGSize(width: 300, height: 300))
        #expect(abs(fill.scale - 300.0 / 720) < 1e-9)
        #expect(abs(fill.crop.minY) < 1e-9)
        #expect(abs(fill.crop.midX - 1280 * fill.scale / 2) < 1e-9)
        #expect(fill.crop.size == CGSize(width: 300, height: 300))
    }
}

@Suite struct WebcamShapeTests {
    private let rect = CGRect(x: 10, y: 20, width: 300, height: 300)

    private func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    @Test(arguments: WebcamShape.allCases)
    func everyShapeFillsItsRect(_ shape: WebcamShape) {
        let frame = CGRect(x: 10, y: 20, width: 300 * shape.aspect, height: 300)
        let outline = shape.outline(in: frame)
        let box = bounds(outline)
        #expect(abs(box.minX - frame.minX) < 0.5 && abs(box.maxX - frame.maxX) < 0.5)
        #expect(abs(box.minY - frame.minY) < 0.5 && abs(box.maxY - frame.maxY) < 0.5)
        #expect(shape.path(in: frame).contains(CGPoint(x: frame.midX, y: frame.midY)))
        #expect(!shape.path(in: frame).contains(CGPoint(x: frame.minX + 1, y: frame.minY + 1)))
    }

    /// Fine enough to read as a curve: neighbouring segments never turn more than a couple of degrees.
    @Test(arguments: WebcamShape.allCases)
    func outlinesHaveNoVisibleFacets(_ shape: WebcamShape) {
        let points = shape.outline(in: rect)
        var largest = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count], c = points[(i + 2) % points.count]
            let d1 = atan2(Double(b.y - a.y), Double(b.x - a.x))
            let d2 = atan2(Double(c.y - b.y), Double(c.x - b.x))
            guard hypot(b.x - a.x, b.y - a.y) > 1e-6, hypot(c.x - b.x, c.y - b.y) > 1e-6 else { continue }
            var turn = abs(d2 - d1)
            if turn > .pi { turn = 2 * .pi - turn }
            largest = max(largest, turn)
        }
        #expect(largest * 180 / .pi < 2.5)
    }

    /// Continuous corners leave the straight edge gradually, where a circular arc of the same size bends
    /// at once: near the joint the squircle stays much closer to the edge.
    @Test func squircleCornersFlowOutOfTheEdges() {
        let points = WebcamShape.squircle.outline(in: rect)
        let extent = rect.width * 0.3
        let joint = rect.maxX - extent
        let near = points.filter { $0.y < rect.midY && $0.x > joint + extent * 0.05 && $0.x < joint + extent * 0.3 }
        #expect(!near.isEmpty)
        for p in near {
            let dx = p.x - joint
            let arc = extent - (extent * extent - dx * dx).squareRoot()
            #expect(p.y - rect.minY < arc * 0.3)
        }
        // Still a real corner: well inside the square's own corner.
        #expect(!WebcamShape.squircle.path(in: rect).contains(CGPoint(x: rect.maxX - 3, y: rect.minY + 3)))
    }

    @Test func circleAndSquircleAreSymmetricThePebbleIsNot() {
        func mirrored(_ shape: WebcamShape) -> Bool {
            let path = shape.path(in: rect)
            let probes = stride(from: 0.0, to: 2 * .pi, by: .pi / 18).map { t in
                CGPoint(x: rect.midX + 0.49 * rect.width * CGFloat(cos(t)), y: rect.midY + 0.49 * rect.height * CGFloat(sin(t)))
            }
            return probes.allSatisfy { p in
                path.contains(p) == path.contains(CGPoint(x: 2 * rect.midX - p.x, y: p.y))
            }
        }
        #expect(mirrored(.circle))
        #expect(mirrored(.squircle))
        #expect(!mirrored(.pebble))
    }

    @Test func maskEdgesAreAntiAliased() throws {
        let art = try #require(WebcamArt.art(shape: .squircle, size: CGSize(width: 200, height: 200), border: true, shadow: true))
        #expect(art.mask.width == 200 && art.mask.height == 200)
        #expect(art.ring != nil && art.shadow != nil)
        // Along a row through the corner region, alpha steps through in-between values, not 0 then 255.
        let alphas = alphaRow(of: art.mask, y: 12)
        #expect(alphas.first == 0)
        #expect(alphas[100] == 255)
        #expect(alphas.contains { $0 > 10 && $0 < 245 })
    }

    private func alphaRow(of image: CGImage, y: Int) -> [UInt8] {
        let width = image.width
        var bytes = [UInt8](repeating: 0, count: width * 4)
        let ctx = CGContext(
            data: &bytes, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: -(image.height - 1 - y), width: width, height: image.height))
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }
}

@Suite struct WebcamTimeMappingTests {
    @Test func aCameraThatStartedEarlyIsTrimmedToTheScreen() {
        // The camera rolled 0.3 s before the first screen frame.
        let pieces = ClipTimeMapping.pieces(segments: [ClipSegment(start: 0, end: 10)], videoDuration: 10, fileDuration: 10.4, fileOffset: -0.3)
        #expect(pieces.count == 1)
        #expect(abs(pieces[0].fileStart - 0.3) < 1e-9 && abs(pieces[0].fileEnd - 10.3) < 1e-9)
        #expect(pieces[0].outputStart == 0)
    }

    @Test func aCameraThatStartedLateLeavesTheStartEmpty() {
        let pieces = ClipTimeMapping.pieces(segments: [ClipSegment(start: 0, end: 10)], videoDuration: 10, fileDuration: 9.8, fileOffset: 0.2)
        #expect(pieces.count == 1)
        #expect(pieces[0].fileStart == 0)
        #expect(abs(pieces[0].outputStart - 0.2) < 1e-9)
        #expect(abs(pieces[0].fileEnd - 9.8) < 1e-9)
    }

    @Test func cameraFollowsCutsAndSpeedsOnTheScreensClock() {
        let segments = [ClipSegment(start: 1, end: 4, speed: 2), ClipSegment(start: 6, end: 9)]
        let timeline = ClipTimeline(segments)
        let offset = -0.25
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 10, fileDuration: 11, fileOffset: offset)
        #expect(pieces.count == 2)
        for (piece, start) in zip(pieces, timeline.outputStarts) {
            #expect(abs(piece.outputStart - start) < 1e-9)
            // The camera frame at an output time was taken at the recording moment the screen shows there.
            let t = start + piece.outputDuration / 2
            let fileTime = piece.fileStart + (t - piece.outputStart) * piece.speed
            #expect(abs(fileTime + offset - timeline.sourceTime(atOutput: t)) < 1e-9)
        }
    }

    @Test func clipsOutsideTheCameraAreLeftOut() {
        // The camera only ran from 2 s to 5 s of the recording.
        let segments = [ClipSegment(start: 0, end: 1.5), ClipSegment(start: 3, end: 8)]
        let pieces = ClipTimeMapping.pieces(segments: segments, videoDuration: 8, fileDuration: 3, fileOffset: 2)
        #expect(pieces.count == 1)
        #expect(abs(pieces[0].fileStart - 1) < 1e-9 && abs(pieces[0].fileEnd - 3) < 1e-9)
        #expect(abs(pieces[0].outputStart - 1.5) < 1e-9)
    }
}

@Suite struct WebcamDraftCompatibilityTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func metadataFromBeforeTheCameraStillOpens() throws {
        let json = """
        {"source":"area","title":"Recording 1","createdAt":"2026-09-01T10:00:00Z",
         "pointSize":[800,600],"scale":2,"duration":12.5,
         "audio":[{"source":"microphone","file":"microphone.m4a"}]}
        """
        let metadata = try decode(RecordingMetadata.self, json)
        #expect(metadata.webcam == nil)
        #expect(metadata.audioTracks.count == 1)
    }

    @Test func stylesAndEditsFromBeforeTheCameraGetTheDefaults() throws {
        let json = """
        {"segments":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":0,"end":5,"speed":1}],
         "zooms":[],"style":{"padding":0.12,"autoZoom":false}}
        """
        let edits = try decode(RecordingEdits.self, json)
        #expect(edits.webcamHidden == nil)
        #expect(edits.style.webcam == WebcamStyle())
        #expect(edits.style.padding == 0.12 && edits.style.autoZoom == false)
    }

    @Test func aPartialOrNewerWebcamStyleKeepsWhatItCanRead() throws {
        let style = try decode(WebcamStyle.self, #"{"shape":"pebble","x":0,"size":"huge","y":7,"glow":true}"#)
        #expect(style.shape == .pebble)
        #expect(style.x == 0)
        // Unknown values fall back, out-of-range ones are clamped.
        #expect(style.size == WebcamStyle().size)
        #expect(style.y == 1)
        #expect(style.mirror == WebcamStyle().mirror)
    }

    @Test func webcamRoundTrips() throws {
        var metadata = RecordingMetadata(
            source: .display, title: "Demo", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            pointSize: CGSize(width: 1440, height: 900), scale: 2, duration: 20
        )
        metadata.webcam = RecordedWebcam(file: RecordedWebcam.fileName, deviceName: "FaceTime HD Camera", offset: -0.12)
        var edits = RecordingEdits(segments: [ClipSegment(start: 0, end: 20)], zooms: [], style: RecordingStyle())
        edits.style.webcam.shape = .pebble
        edits.style.webcam.x = 0.25
        edits.style.webcam.duringZoom = .hide
        edits.webcamHidden = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decodedMetadata = try decode(RecordingMetadata.self, String(decoding: try encoder.encode(metadata), as: UTF8.self))
        #expect(decodedMetadata.webcam == metadata.webcam)
        #expect(try JSONDecoder().decode(RecordingEdits.self, from: try encoder.encode(edits)) == edits)
    }
}

@Suite struct WebcamEditorHandleTests {
    /// With "While zoomed in: Hide", the drag handle goes away with the bubble instead of outlining an empty spot.
    @Test func aFadedOutBubbleCannotBeGrabbed() {
        var style = WebcamStyle()
        style.duringZoom = .hide
        let canvas = CGSize(width: 1920, height: 1080)
        #expect(WebcamLayout.isGrabbable(opacity: WebcamLayout.presentation(style, canvas: canvas, zoomScale: 1).opacity))
        #expect(!WebcamLayout.isGrabbable(opacity: WebcamLayout.presentation(style, canvas: canvas, zoomScale: 2).opacity))
        style.duringZoom = .shrink
        #expect(WebcamLayout.isGrabbable(opacity: WebcamLayout.presentation(style, canvas: canvas, zoomScale: 2).opacity))
    }

    @Test func sizePillsHaveSpokenNames() {
        #expect(WebcamSize.allCases.map(\.name) == ["Small", "Medium", "Large"])
    }
}

@Suite struct WebcamPreviewLayoutTests {
    private let visible = CGRect(x: 0, y: 40, width: 1512, height: 920)

    private func style(_ corner: WebcamCorner, size: WebcamSize = .medium, shape: WebcamShape = .squircle) -> WebcamStyle {
        var style = WebcamStyle()
        style.x = corner.position.x
        style.y = corner.position.y
        style.size = size
        style.shape = shape
        return style
    }

    /// The live bubble sits where the bubble will be in the video. AppKit counts y from the bottom.
    @Test func theLiveBubbleSitsInTheStylesCorner() {
        let margin = WebcamPreviewLayout.margin
        let bottomRight = WebcamPreviewLayout.bubble(style(.bottomRight), visible: visible)
        #expect(bottomRight.maxX == visible.maxX - margin && bottomRight.minY == visible.minY + margin)
        let topLeft = WebcamPreviewLayout.bubble(style(.topLeft), visible: visible)
        #expect(topLeft.minX == visible.minX + margin && topLeft.maxY == visible.maxY - margin)
        let topRight = WebcamPreviewLayout.bubble(style(.topRight), visible: visible)
        #expect(topRight.maxX == visible.maxX - margin && topRight.maxY == visible.maxY - margin)
        let bottomLeft = WebcamPreviewLayout.bubble(style(.bottomLeft), visible: visible)
        #expect(bottomLeft.minX == visible.minX + margin && bottomLeft.minY == visible.minY + margin)
    }

    @Test func theLiveBubbleFollowsTheSizeAndShape() {
        let heights = WebcamSize.allCases.map { WebcamPreviewLayout.bubble(style(.bottomRight, size: $0), visible: visible).height }
        #expect(heights == heights.sorted() && Set(heights).count == 3)
        let pebble = WebcamPreviewLayout.bubble(style(.bottomRight, shape: .pebble), visible: visible)
        #expect(abs(pebble.width / pebble.height - WebcamShape.pebble.aspect) < 0.01)
    }

    @Test func aPositionBetweenCornersIsKeptOnScreen() {
        var middle = WebcamStyle()
        middle.x = 0.5
        middle.y = 0.5
        let bubble = WebcamPreviewLayout.bubble(middle, visible: visible)
        #expect(abs(bubble.midX - visible.midX) <= 1 && abs(bubble.midY - visible.midY) <= 1)
    }
}

@Suite struct WebcamChoiceTests {
    private let builtIn = Webcams.Device(id: "built-in", name: "FaceTime HD Camera")
    private let phone = Webcams.Device(id: "phone", name: "iPhone Camera")

    @Test func theSavedCameraRecordsWhileConnected() {
        #expect(Webcams.recording(saved: "built-in", systemDefault: "phone", in: [builtIn, phone]) == builtIn)
    }

    /// The bar and Settings must name the camera capture falls back to, not just the first one listed.
    @Test func aDisconnectedCameraFallsBackToTheSystemDefault() {
        #expect(Webcams.recording(saved: "studio", systemDefault: "phone", in: [builtIn, phone]) == phone)
        #expect(Webcams.recording(saved: nil, systemDefault: "phone", in: [builtIn, phone]) == phone)
        #expect(Webcams.recording(saved: nil, systemDefault: nil, in: [builtIn, phone]) == builtIn)
        #expect(Webcams.recording(saved: nil, systemDefault: nil, in: []) == nil)
    }
}

@Suite struct CursorClickFilterTests {
    /// Dragging the live camera bubble (a panel left out of the capture) mustn't add a click: it would zoom
    /// into and ripple over a spot where viewers see nothing.
    @Test func clicksOnPanelsLeftOutOfTheCaptureAreIgnored() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(!CursorTracker.recordsClick(in: panel))
        #expect(CursorTracker.recordsClick(in: window))
        #expect(CursorTracker.recordsClick(in: nil))
    }
}
