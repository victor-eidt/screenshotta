import Testing
@testable import ScreenOtter

@Suite struct ClipSegmentTests {
    @Test func outputDurationAccountsForSpeed() {
        let clip = ClipSegment(start: 2, end: 6, speed: 2)
        #expect(clip.outputDuration == 2)
    }
}
