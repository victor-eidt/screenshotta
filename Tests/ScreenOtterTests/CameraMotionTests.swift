import CoreGraphics
import Foundation
import Testing
@testable import ScreenOtter

/// The camera while zoomed in: it goes where you click, keeps up with the pointer, or holds on a chosen spot.
@Suite struct CameraMotionTests {
    /// Clicks on one spot, glides over to another between 1.5 and 2 seconds, and clicks there at 2.3.
    private func twoSpots() -> CursorRecording {
        var recording = CursorRecording()
        for i in 0...300 {
            let t = Double(i) / 50
            let f = min(max((t - 1.5) / 0.5, 0), 1)
            recording.samples.append(.init(t: t, x: 300 + 350 * f, y: 350 + 250 * f))
        }
        recording.clicks = [.init(t: 1, x: 300, y: 350), .init(t: 2.3, x: 650, y: 600)]
        return recording
    }

    private func track(_ recording: CursorRecording, zooms: [ZoomSegment]) -> MotionTrack {
        MotionTrack(recording: recording, pointSize: CGSize(width: 1000, height: 1000), duration: 6, zooms: zooms, style: RecordingStyle())
    }

    private func distance(_ camera: CameraState, _ x: Double, _ y: Double) -> Double {
        hypot(camera.x - x, camera.y - y)
    }

    @Test func aSecondClickElsewhereRecentersOnIt() {
        let recording = twoSpots()
        let zooms = AutoZoom.segments(clicks: recording.clicks, duration: 6, scale: 2, keeping: [])
        // Both clicks share one zoom: the camera pans instead of zooming out and back in.
        #expect(zooms.count == 1)
        let motion = track(recording, zooms: zooms)
        #expect(distance(motion.camera(at: 1), 0.3, 0.35) < 0.02)
        #expect(distance(motion.camera(at: 2.3), 0.65, 0.6) < 0.03)
        #expect(distance(motion.camera(at: 3), 0.65, 0.6) < 0.01)
    }

    @Test func keepsUpWithThePointerBetweenClicks() {
        var recording = twoSpots()
        recording.clicks.removeLast()
        let motion = track(recording, zooms: [ZoomSegment(start: 0, end: 4, scale: 2, isAuto: false)])
        // No click at the new spot: the pointer sits close to the middle of the view all the same.
        let camera = motion.camera(at: 3)
        #expect(distance(camera, 0.65, 0.6) < 0.1)
    }

    @Test func aChosenSpotHoldsWhereverThePointerGoes() {
        let recording = twoSpots()
        let zoom = ZoomSegment(start: 0, end: 4, scale: 2, isAuto: false, focus: CGPoint(x: 0.7, y: 0.3))
        let motion = track(recording, zooms: [zoom])
        for t in [1.0, 2.0, 2.3, 3.5] {
            #expect(distance(motion.camera(at: t), 0.7, 0.3) < 0.01)
        }
        // Easing out from there, and back to the full view after.
        #expect(motion.camera(at: 5.5).scale == 1)
    }

    @Test func aChosenSpotSurvivesSaving() throws {
        let zoom = ZoomSegment(start: 1, end: 2, scale: 2, isAuto: false, focus: CGPoint(x: 0.25, y: 0.75))
        let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(zoom))
        #expect(decoded == zoom)
        // Zooms saved before spots existed still open, following the pointer.
        let old = #"{"id":"\#(UUID().uuidString)","start":1,"end":2,"scale":2,"isAuto":true}"#
        #expect(try JSONDecoder().decode(ZoomSegment.self, from: Data(old.utf8)).focus == nil)
    }
}
