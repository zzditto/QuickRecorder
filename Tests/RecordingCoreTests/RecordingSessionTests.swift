import AVFoundation
import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingSessionTests: XCTestCase {
    func testStopDurationIncludesTimeAfterLastFrame() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 10, preferredTimescale: 600))
        _ = timeline.presentationTime(for: CMTime(seconds: 20, preferredTimescale: 600))
        XCTAssertEqual(timeline.finalDuration(at: CMTime(seconds: 70, preferredTimescale: 600)).seconds, 60, accuracy: 0.001)
    }

    func testPauseResumeRemovesDuration() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.pause(at: CMTime(seconds: 20, preferredTimescale: 600))
        timeline.resume(at: CMTime(seconds: 35, preferredTimescale: 600))
        XCTAssertEqual(timeline.finalDuration(at: CMTime(seconds: 50, preferredTimescale: 600)).seconds, 25, accuracy: 0.001)
    }

    func testStopCallsFinalizerAfterWriterFinishWithoutSamples() throws {
        let finalizer = RecordingFinalizerSpy()
        let writer = RecordingWriter(adapter: RecordingWriterTestAdapter())
        let session = RecordingSession(configuration: .test(), finalizer: finalizer, writer: writer)
        try session.start()
        let completion = expectation(description: "stopped")

        session.stop(at: CMTime(seconds: 3, preferredTimescale: 600)) { result in
            guard case .success = result else {
                return XCTFail("Expected successful stop")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(finalizer.requests.count, 1)
        XCTAssertEqual(finalizer.requests[0].finalDuration, .zero)
    }

    func testStopUsesFirstSampleAsTimelineStart() throws {
        let finalizer = RecordingFinalizerSpy()
        let writer = RecordingWriter(adapter: RecordingWriterTestAdapter())
        let session = RecordingSession(configuration: .test(), finalizer: finalizer, writer: writer)
        try session.start()
        let completion = expectation(description: "stopped")

        session.appendSystemAudio(try makeAudioSample(at: CMTime(seconds: 10, preferredTimescale: 48_000)))
        session.stop(at: CMTime(seconds: 70, preferredTimescale: 600)) { result in
            guard case .success = result else {
                return XCTFail("Expected successful stop")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(finalizer.requests.count, 1)
        XCTAssertEqual(finalizer.requests[0].finalDuration.seconds, 60, accuracy: 0.001)
    }

    func testStartWrapsWriterFailure() {
        let finalizer = RecordingFinalizerSpy()
        let writer = RecordingWriter(adapter: FailingStartRecordingWriterAdapter())
        let session = RecordingSession(configuration: .test(), finalizer: finalizer, writer: writer)

        XCTAssertThrowsError(try session.start()) { error in
            guard case RecordingSessionError.writerStartFailed = error else {
                return XCTFail("Expected writer start failure, got \(error)")
            }
        }
    }

    func testAppendAfterStopIsRejected() throws {
        let finalizer = RecordingFinalizerSpy()
        let writer = RecordingWriter(adapter: RecordingWriterTestAdapter())
        let session = RecordingSession(configuration: .test(), finalizer: finalizer, writer: writer)
        try session.start()
        let completion = expectation(description: "stopped")
        session.stop(at: CMTime(seconds: 1, preferredTimescale: 600)) { _ in completion.fulfill() }
        wait(for: [completion], timeout: 1)

        session.appendSystemAudio(try makeAudioSample(at: CMTime(seconds: 2, preferredTimescale: 48_000)))

        XCTAssertEqual(session.rejectedSampleCount, 1)
    }

    private func makeAudioSample(at presentationTime: CMTime) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        return try XCTUnwrap(AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: presentationTime))
    }
}

private final class RecordingFinalizerSpy: RecordingFinalizing {
    private(set) var requests: [RecordingFinalizerRequest] = []

    func finalize(_ request: RecordingFinalizerRequest, completion: @escaping (Result<RecordingOutput, Error>) -> Void) {
        requests.append(request)
        completion(.success(RecordingOutput(url: request.outputURL, duration: request.finalDuration)))
    }
}

private final class FailingStartRecordingWriterAdapter: RecordingWriterAdapting {
    var isReadyForVideo: Bool { false }
    var isReadyForSystemAudio: Bool { false }
    var isReadyForMic: Bool { false }

    func startWriting() throws {
        throw StartFailure()
    }

    func startSession(at time: CMTime) {}
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool { false }
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) -> Bool { false }
    func appendMic(_ sampleBuffer: CMSampleBuffer) -> Bool { false }
    func endSession(at time: CMTime) {}
    func markVideoFinished() {}
    func markSystemAudioFinished() {}
    func markMicFinished() {}
    func finishWriting(completion: @escaping (Error?) -> Void) {}

    private struct StartFailure: Error {}
}

private extension RecordingSessionConfiguration {
    static func test() -> RecordingSessionConfiguration {
        RecordingSessionConfiguration(
            writerConfiguration: RecordingWriterConfiguration(
                outputURL: URL(fileURLWithPath: "/tmp/session.mov"),
                fileType: .mov,
                videoOutputSettings: nil,
                systemAudioOutputSettings: nil,
                micOutputSettings: nil
            ),
            finalizerMode: .videoWithoutRemux
        )
    }
}
