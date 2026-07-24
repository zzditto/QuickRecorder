import AVFoundation
import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingWriterStateTests: XCTestCase {
    func testStateMachineAcceptsSamplesOnlyAfterStarting() {
        var state = RecordingWriterStateMachine()
        XCTAssertFalse(state.acceptsSamples)
        state.start()
        XCTAssertTrue(state.acceptsSamples)
        state.beginStopping()
        XCTAssertFalse(state.acceptsSamples)
        state.finish()
        XCTAssertFalse(state.acceptsSamples)
    }

    func testAppendBeforeStartIsDroppedWithoutStartingSession() throws {
        let adapter = RecordingWriterTestAdapter()
        let writer = RecordingWriter(adapter: adapter)
        let sample = try makeSampleBuffer()
        let completion = expectation(description: "finish")

        writer.appendVideo(sample)
        try writer.start()
        writer.appendVideo(sample)
        writer.finish(finalDuration: .zero, tailVideoSample: nil) { result in
            guard case let .success(summary) = result else {
                return XCTFail("Expected successful finish")
            }
            XCTAssertEqual(summary.droppedVideoSampleCount, 1)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(adapter.events.filter { $0 == "startSession:0.0" }.count, 1)
    }

    func testFinishBeforeStartCompletesWithFailure() {
        let adapter = RecordingWriterTestAdapter()
        let writer = RecordingWriter(adapter: adapter)
        let completion = expectation(description: "finish failure")

        writer.finish(finalDuration: .zero, tailVideoSample: nil) { result in
            guard case .failure = result else {
                return XCTFail("Expected finish failure before start")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertTrue(adapter.events.isEmpty)
    }

    func testSecondFinishCompletesWithFailure() throws {
        let adapter = RecordingWriterTestAdapter()
        let writer = RecordingWriter(adapter: adapter)
        let firstCompletion = expectation(description: "first finish")
        let secondCompletion = expectation(description: "second finish failure")

        try writer.start()
        writer.finish(finalDuration: .zero, tailVideoSample: nil) { result in
            guard case .success = result else {
                return XCTFail("Expected first finish to succeed")
            }
            firstCompletion.fulfill()
        }
        writer.finish(finalDuration: .zero, tailVideoSample: nil) { result in
            guard case .failure = result else {
                return XCTFail("Expected second finish failure")
            }
            secondCompletion.fulfill()
        }

        wait(for: [firstCompletion, secondCompletion], timeout: 1)
    }

    private func makeSampleBuffer() throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        return try XCTUnwrap(AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: .zero))
    }
}
