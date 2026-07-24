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
        XCTAssertFalse(
            coordinator.canHandleMouseEvent(session, listenerSession: session)
        )
    }

    func testQueuedMouseEventFromOldSessionIsRejectedAfterNewSessionStarts() {
        let coordinator = ScreenCaptureSelectionSessionCoordinator()
        let oldSession = coordinator.beginSession()

        let newSession = coordinator.beginSession()

        XCTAssertFalse(
            coordinator.canHandleMouseEvent(oldSession, listenerSession: oldSession)
        )
        XCTAssertFalse(
            coordinator.canHandleMouseEvent(newSession, listenerSession: oldSession)
        )
        XCTAssertTrue(
            coordinator.canHandleMouseEvent(newSession, listenerSession: newSession)
        )
    }

    func testStoppingListenerRejectsQueuedMouseEvent() {
        let coordinator = ScreenCaptureSelectionSessionCoordinator()
        let session = coordinator.beginSession()

        coordinator.stopListening()

        XCTAssertFalse(
            coordinator.canHandleMouseEvent(session, listenerSession: session)
        )
    }

    func testNewSessionCanShowMaskForSameWindowID() {
        let coordinator = ScreenCaptureSelectionSessionCoordinator()
        let oldSession = coordinator.beginSession()

        XCTAssertTrue(
            coordinator.selectTargetWindow(42, for: oldSession, listenerSession: oldSession)
        )

        let newSession = coordinator.beginSession()

        XCTAssertNil(coordinator.targetWindowID)
        XCTAssertTrue(
            coordinator.selectTargetWindow(42, for: newSession, listenerSession: newSession)
        )
    }

    func testOldSessionCompletionAndCloseCannotAffectNewSession() {
        let coordinator = ScreenCaptureSelectionSessionCoordinator()
        let oldSession = coordinator.beginSession()
        XCTAssertTrue(
            coordinator.selectTargetWindow(11, for: oldSession, listenerSession: oldSession)
        )

        let newSession = coordinator.beginSession()
        XCTAssertTrue(
            coordinator.selectTargetWindow(42, for: newSession, listenerSession: newSession)
        )
        XCTAssertFalse(coordinator.canApplySelectionCompletion(for: oldSession))
        XCTAssertFalse(coordinator.clearTargetWindowID(for: oldSession))
        XCTAssertFalse(coordinator.invalidateSession(oldSession))
        XCTAssertEqual(coordinator.targetWindowID, 42)
    }

    func testPermissionPromptGateRejectsConcurrentPromptUntilReleased() {
        let gate = ScreenCapturePermissionPromptGate()

        XCTAssertTrue(gate.acquire())
        XCTAssertFalse(gate.acquire())
        gate.release()
        XCTAssertTrue(gate.acquire())
    }
}
