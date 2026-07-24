import XCTest
@testable import RecordingCore

final class ScreenCaptureContentRefreshPolicyTests: XCTestCase {
    func testAutomaticAccessDeniedCompletesWithoutRetry() {
        XCTAssertEqual(
            ScreenCaptureContentRefreshPolicy.decision(for: .accessDenied, origin: .automatic),
            .complete(status: .accessDenied)
        )
    }

    func testAutomaticRefreshRequestDoesNotShowPermissionGuideWhenDenied() {
        let request = ScreenCaptureContentRefreshRequest.automatic

        XCTAssertEqual(request.origin, .automatic)
        XCTAssertFalse(request.onScreenWindowsOnly)
        XCTAssertEqual(
            ScreenCaptureContentRefreshPolicy.decision(for: .accessDenied, origin: request.origin),
            .complete(status: .accessDenied)
        )
    }

    func testWindowSelectionRequestUsesUserInitiatedOnScreenContentAndShowsGuideWhenDenied() {
        let request = ScreenCaptureContentRefreshRequest.windowSelection

        XCTAssertEqual(request.origin, .userInitiated)
        XCTAssertTrue(request.onScreenWindowsOnly)
        XCTAssertEqual(
            ScreenCaptureContentRefreshPolicy.decision(for: .accessDenied, origin: request.origin),
            .showPermissionGuide(status: .accessDenied)
        )
    }

    func testUserInitiatedAccessDeniedShowsOnePermissionGuide() {
        XCTAssertEqual(
            ScreenCaptureContentRefreshPolicy.decision(for: .accessDenied, origin: .userInitiated),
            .showPermissionGuide(status: .accessDenied)
        )
    }

    func testPermissionPromptGateRejectsConcurrentPromptUntilReleased() {
        let gate = ScreenCapturePermissionPromptGate()

        XCTAssertTrue(gate.acquire())
        XCTAssertFalse(gate.acquire())
        gate.release()
        XCTAssertTrue(gate.acquire())
    }
}
