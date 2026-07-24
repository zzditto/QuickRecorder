import AVFoundation
import CoreMedia
import XCTest
@testable import RecordingCore

final class AudioSampleBufferFactoryTests: XCTestCase {
    func testPCMBufferUsesProvidedPresentationTime() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let pts = CMTime(seconds: 3, preferredTimescale: 48_000)
        let sample = try XCTUnwrap(AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: pts))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), pts)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 480)
    }
}
