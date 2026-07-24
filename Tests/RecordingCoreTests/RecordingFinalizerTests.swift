import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingFinalizerTests: XCTestCase {
    func testVideoRemuxUsesFinalDurationNotAssetDuration() {
        let finalizer = RecordingFinalizer()
        let range = finalizer.outputTimeRange(finalDuration: CMTime(seconds: 42, preferredTimescale: 600))
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration.seconds, 42, accuracy: 0.001)
    }

    func testFailedRemuxPreservesIntermediateFiles() {
        let policy = RecordingFinalizerFilePolicy()
        XCTAssertFalse(policy.shouldDeleteIntermediateFiles(remuxSucceeded: false))
        XCTAssertTrue(policy.shouldDeleteIntermediateFiles(remuxSucceeded: true))
    }

    func testVideoWithoutRemuxReturnsCompletedOutput() {
        let finalizer = RecordingFinalizer()
        let outputURL = URL(fileURLWithPath: "/tmp/quick-recorder-test.mov")
        let request = RecordingFinalizerRequest(
            sourceURL: outputURL,
            outputURL: outputURL,
            finalDuration: CMTime(seconds: 5, preferredTimescale: 600),
            mode: .videoWithoutRemux
        )
        let completion = expectation(description: "finalized")

        finalizer.finalize(request) { result in
            guard case let .success(output) = result else {
                return XCTFail("Expected successful output")
            }
            XCTAssertEqual(output.url, outputURL)
            XCTAssertEqual(output.duration.seconds, 5, accuracy: 0.001)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
    }
}
