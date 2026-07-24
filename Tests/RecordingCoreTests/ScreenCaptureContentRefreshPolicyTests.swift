import XCTest
@testable import RecordingCore

final class ScreenCaptureContentRefreshPolicyTests: XCTestCase {
    func testAutomaticAccessDeniedCompletesWithoutRetry() {
        XCTAssertEqual(
            ScreenCaptureContentRefreshPolicy.decision(for: .accessDenied, origin: .automatic),
            .complete(status: .accessDenied)
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
