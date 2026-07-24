import AVFoundation
import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingWriterOrderTests: XCTestCase {
    func testFinishOrderIsTailThenEndThenMarkThenFinish() throws {
        let adapter = RecordingWriterTestAdapter()
        let writer = RecordingWriter(adapter: adapter)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let tailVideoSample = try XCTUnwrap(
            AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: .zero)
        )

        try writer.start()
        writer.finish(
            finalDuration: CMTime(seconds: 12, preferredTimescale: 600),
            tailVideoSample: tailVideoSample
        ) { _ in }
        adapter.drainQueue()

        XCTAssertEqual(adapter.events, [
            "startWriting",
            "startSession:0.0",
            "appendVideo",
            "endSession:12.0",
            "markVideoFinished",
            "markSystemAudioFinished",
            "markMicFinished",
            "finishWriting"
        ])
    }
}
