import CoreMedia
import Foundation
@testable import RecordingCore

final class RecordingWriterTestAdapter: RecordingWriterAdapting {
    private let queue = DispatchQueue(label: "QuickRecorder.RecordingWriterTestAdapter")
    private(set) var events: [String] = []

    var isReadyForVideo: Bool { true }
    var isReadyForSystemAudio: Bool { true }
    var isReadyForMic: Bool { true }

    func startWriting() throws {
        record("startWriting")
    }

    func startSession(at time: CMTime) {
        record("startSession:\(time.seconds)")
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        record("appendVideo")
        return true
    }
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) -> Bool { true }
    func appendMic(_ sampleBuffer: CMSampleBuffer) -> Bool { true }

    func endSession(at time: CMTime) {
        record("endSession:\(time.seconds)")
    }

    func markVideoFinished() {
        record("markVideoFinished")
    }

    func markSystemAudioFinished() {
        record("markSystemAudioFinished")
    }

    func markMicFinished() {
        record("markMicFinished")
    }

    func finishWriting(completion: @escaping (Error?) -> Void) {
        record("finishWriting")
        completion(nil)
    }

    func cancelWriting() {
        record("cancelWriting")
    }

    func drainQueue() {
        queue.sync {}
    }

    private func record(_ event: String) {
        queue.sync {
            events.append(event)
        }
    }
}
