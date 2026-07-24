import CoreMedia
import XCTest
@testable import RecordingCore

final class AECAudioClockTests: XCTestCase {
    func testClockAdvancesByFrameLengthOverSampleRate() {
        var clock = AECAudioClock(sampleRate: 48_000, startTime: .zero)
        let first = clock.nextSourceTime(frameLength: 480)
        let second = clock.nextSourceTime(frameLength: 480)
        XCTAssertEqual(first.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(second.seconds, 0.01, accuracy: 0.001)
    }

    func testClockKeepsContinuousFramesFromSessionSourceTime() {
        var clock = AECAudioClock(
            sampleRate: 48_000,
            startTime: CMTime(seconds: 42, preferredTimescale: 1_000_000_000)
        )

        let first = clock.nextSourceTime(frameLength: 480)
        let second = clock.nextSourceTime(frameLength: 960)

        XCTAssertEqual(first.seconds, 42, accuracy: 0.001)
        XCTAssertEqual(second.seconds, 42.01, accuracy: 0.001)
    }
}
