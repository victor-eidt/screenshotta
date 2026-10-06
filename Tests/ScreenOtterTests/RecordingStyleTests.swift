import Foundation
import Testing
@testable import ScreenOtter

@Suite struct RecordingStyleTests {
    @Test func olderStylesHaveAnAutoBarColor() throws {
        let old = #"{"minimalWindowFrame": true, "padding": 0.1}"#
        let style = try JSONDecoder().decode(RecordingStyle.self, from: Data(old.utf8))
        #expect(style.windowBarColor == nil)
        #expect(style.minimalWindowFrame)
    }

    @Test func keepsAChosenBarColor() throws {
        var style = RecordingStyle()
        style.windowBarColor = 0xECECEC
        let decoded = try JSONDecoder().decode(RecordingStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded.windowBarColor == 0xECECEC)
    }
}
