import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingWriterOrderTests: XCTestCase {
    func testFinishOrderIsTailThenEndThenMarkThenFinish() {
        let adapter = RecordingWriterTestAdapter()
        let writer = RecordingWriter(adapter: adapter)

        writer.finish(
            finalDuration: CMTime(seconds: 12, preferredTimescale: 600),
            tailVideoSample: nil
        ) { _ in }
        adapter.drainQueue()

        XCTAssertEqual(adapter.events, [
            "endSession:12.0",
            "markVideoFinished",
            "markSystemAudioFinished",
            "markMicFinished",
            "finishWriting"
        ])
    }
}
