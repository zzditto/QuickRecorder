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

    func testFirstSelectorLoadUsesUserInitiatedOrigin() {
        XCTAssertEqual(
            ScreenCaptureSelectionSessionCoordinator.firstLoadRequest.origin,
            .userInitiated
        )
    }

    func testStartingNewSelectionRejectsOldCompletion() {
        let coordinator = ScreenCaptureSelectionSessionCoordinator()

        let oldSession = coordinator.beginSession()
        let currentSession = coordinator.beginSession()

        XCTAssertFalse(coordinator.isCurrent(oldSession))
        XCTAssertTrue(coordinator.isCurrent(currentSession))
    }

    func testInvalidatingSelectionRejectsItsCompletion() {
        let coordinator = ScreenCaptureSelectionSessionCoordinator()
        let session = coordinator.beginSession()

        coordinator.invalidateCurrentSession()

        XCTAssertFalse(coordinator.isCurrent(session))
    }

    func testPermissionPromptGateRejectsConcurrentPromptUntilReleased() {
        let gate = ScreenCapturePermissionPromptGate()

        XCTAssertTrue(gate.acquire())
        XCTAssertFalse(gate.acquire())
        gate.release()
        XCTAssertTrue(gate.acquire())
    }
}
