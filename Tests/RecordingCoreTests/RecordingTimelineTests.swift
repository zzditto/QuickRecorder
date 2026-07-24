import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingTimelineTests: XCTestCase {
    func testAnyFirstSampleStartsTimelineAtZero() {
        var timeline = RecordingTimeline()
        let mapped = timeline.presentationTime(for: CMTime(seconds: 20, preferredTimescale: 600))
        XCTAssertEqual(mapped, .zero)
        XCTAssertEqual(timeline.sourceStartTime?.seconds ?? -1, 20, accuracy: 0.001)
    }

    func testPauseDurationIsRemovedFromAllTracks() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.pause(at: CMTime(seconds: 13, preferredTimescale: 600))
        timeline.resume(at: CMTime(seconds: 18, preferredTimescale: 600))
        let video = timeline.presentationTime(for: CMTime(seconds: 20, preferredTimescale: 600))
        let audio = timeline.presentationTime(for: CMTime(seconds: 21, preferredTimescale: 600))
        XCTAssertEqual(video.seconds, 5, accuracy: 0.001)
        XCTAssertEqual(audio.seconds, 6, accuracy: 0.001)
    }

    func testFinalDurationUsesStopSourceTime() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 100, preferredTimescale: 600))
        _ = timeline.presentationTime(for: CMTime(seconds: 120, preferredTimescale: 600))
        let final = timeline.finalDuration(at: CMTime(seconds: 180, preferredTimescale: 600))
        XCTAssertEqual(final.seconds, 80, accuracy: 0.001)
    }

    func testPresentationTimeIsMonotonic() {
        var timeline = RecordingTimeline()
        let first = timeline.presentationTime(for: CMTime(seconds: 5, preferredTimescale: 600))
        let second = timeline.presentationTime(for: CMTime(seconds: 4, preferredTimescale: 600))
        XCTAssertEqual(first, .zero)
        XCTAssertEqual(second, .zero)
    }
}
