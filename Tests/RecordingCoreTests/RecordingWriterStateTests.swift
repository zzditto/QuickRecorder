import XCTest
@testable import RecordingCore

final class RecordingWriterStateTests: XCTestCase {
    func testStateMachineRejectsSamplesAfterStopping() {
        var state = RecordingWriterStateMachine()
        XCTAssertTrue(state.acceptsSamples)
        state.beginStopping()
        XCTAssertFalse(state.acceptsSamples)
        state.finish()
        XCTAssertFalse(state.acceptsSamples)
    }
}
