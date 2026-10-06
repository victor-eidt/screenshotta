import AVFoundation
import Foundation
import Testing
@testable import ScreenOtter

/// While a clip's edge is dragged, the preview shows the frame at that edge, even where it was cut out before.
@Suite struct RecordingTrimTests {
    @Test func previewFollowsTheLeadingEdgeIntoWhatWasCut() async throws {
        try await withDocument(keeping: 1...3) { doc, clip in
            doc.beginTrim(clip, leading: true)
            doc.trim(clip, leading: true, to: 0.5)
            // The player shows the whole recording, at the clip's new first frame; the playhead is at the clip's start.
            #expect(await eventually { itemDuration(doc) == 4 && abs(doc.player.currentTime().seconds - 0.5) < 0.01 })
            #expect(abs(doc.currentTime) < 0.01)

            doc.endTrim()
            // Back to the cut, still on that frame.
            #expect(await eventually { itemDuration(doc) == 2.5 && abs(doc.player.currentTime().seconds) < 0.01 })
        }
    }

    @Test func previewShowsTheLastFrameKeptByTheTrailingEdge() async throws {
        try await withDocument(keeping: 1...3) { doc, clip in
            doc.beginTrim(clip, leading: false)
            doc.trim(clip, leading: false, to: 2)
            #expect(await eventually { itemDuration(doc) == 4 && abs(doc.player.currentTime().seconds - 2) < 0.01 })
            // The playhead sits at the end of the shortened clip.
            #expect(abs(doc.currentTime - 1) < 0.01)

            doc.endTrim()
            #expect(await eventually { itemDuration(doc) == 1 && abs(doc.player.currentTime().seconds - 1) < 0.01 })
        }
    }

    private func itemDuration(_ doc: RecordingDocument) -> Double? {
        doc.player.currentItem.map { ($0.duration.seconds * 100).rounded() / 100 }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A 4 s recording (a frame every 0.1 s) of which `kept` is the one clip, opened in the editor.
    private func withDocument(keeping kept: ClosedRange<Double>, _ body: (RecordingDocument, UUID) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = RecordingProject(folder: folder)
        try await TestVideo.write(to: project.videoURL, frameTimes: (0..<40).map { Double($0) / 10 }, duration: 4)
        try project.save(RecordingMetadata(
            source: .area, title: "Trim", createdAt: Date(), pointSize: CGSize(width: 64, height: 64), scale: 1, duration: 4
        ))
        let clip = ClipSegment(start: kept.lowerBound, end: kept.upperBound)
        var style = RecordingStyle()
        style.autoZoom = false
        try project.save(RecordingEdits(segments: [clip], zooms: [], style: style))

        let doc = try await RecordingDocument.load(project)
        defer { doc.close() }
        #expect(await eventually { itemDuration(doc) == kept.upperBound - kept.lowerBound })
        try await body(doc, clip.id)
    }
}
