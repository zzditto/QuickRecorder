import AVFoundation
import CoreMedia
import XCTest
@testable import RecordingCore

final class SampleRetimingTests: XCTestCase {
    func testInvalidSampleReturnsNil() {
        XCTAssertNil(RecordingSampleRetimer.copy(nil, presentationTime: .zero))
    }

    func testAudioSamplePTSIsRetimed() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let original = try XCTUnwrap(AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: .zero))
        let retimed = try XCTUnwrap(RecordingSampleRetimer.copy(original, presentationTime: CMTime(seconds: 7, preferredTimescale: 48_000)))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(retimed).seconds, 7, accuracy: 0.001)
    }
}
