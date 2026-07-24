import AVFoundation
import CoreMedia
import Foundation

public struct RecordingSessionConfiguration {
    public let writerConfiguration: RecordingWriterConfiguration
    public let finalizerMode: RecordingFinalizerMode

    public init(
        writerConfiguration: RecordingWriterConfiguration,
        finalizerMode: RecordingFinalizerMode
    ) {
        self.writerConfiguration = writerConfiguration
        self.finalizerMode = finalizerMode
    }
}

public final class RecordingSession {
    private enum State {
        case idle
        case recording
        case paused
        case stopping
        case stopped
    }

    private let configuration: RecordingSessionConfiguration
    private let finalizer: RecordingFinalizing
    private let writer: RecordingWriter
    private let sessionQueue = DispatchQueue(label: "QuickRecorder.RecordingSession")
    private var state: State = .idle
    private var timeline = RecordingTimeline()
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoPresentationTime: CMTime?
    private var aecClock: AECAudioClock?
    private var rejectedSamples = 0

    public init(configuration: RecordingSessionConfiguration, finalizer: RecordingFinalizing) {
        self.configuration = configuration
        self.finalizer = finalizer
        do {
            writer = try RecordingWriter(configuration: configuration.writerConfiguration)
        } catch {
            preconditionFailure("Unable to create recording writer: \(error)")
        }
    }

    init(configuration: RecordingSessionConfiguration, finalizer: RecordingFinalizing, writer: RecordingWriter) {
        self.configuration = configuration
        self.finalizer = finalizer
        self.writer = writer
    }

    public var rejectedSampleCount: Int {
        sessionQueue.sync { rejectedSamples }
    }

    public func start() throws {
        try sessionQueue.sync {
            guard case .idle = state else {
                throw RecordingSessionError.invalidStart
            }
            try writer.start()
            _ = timeline.presentationTime(for: .zero)
            state = .recording
        }
    }

    public func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        sessionQueue.async {
            guard self.acceptsSamples else { return self.rejectSample() }
            self.append(sampleBuffer, as: .video)
        }
    }

    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        sessionQueue.async {
            guard self.acceptsSamples else { return self.rejectSample() }
            self.append(sampleBuffer, as: .systemAudio)
        }
    }

    public func appendDefaultMicBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        sessionQueue.async {
            guard self.acceptsSamples else { return self.rejectSample() }
            guard time.isSampleTimeValid, time.sampleRate > 0 else { return self.rejectSample() }
            let sourceTime = CMTime(value: time.sampleTime, timescale: CMTimeScale(time.sampleRate))
            self.append(buffer, sourceTime: sourceTime)
        }
    }

    public func appendAECMicBuffer(_ buffer: AVAudioPCMBuffer) {
        sessionQueue.async {
            guard self.acceptsSamples else { return self.rejectSample() }
            guard buffer.format.sampleRate > 0 else { return self.rejectSample() }
            if self.aecClock == nil {
                self.aecClock = AECAudioClock(
                    sampleRate: buffer.format.sampleRate,
                    startTime: self.timeline.sourceStartTime ?? .zero
                )
            }
            guard var aecClock = self.aecClock else { return self.rejectSample() }
            let sourceTime = aecClock.nextSourceTime(frameLength: buffer.frameLength)
            self.aecClock = aecClock
            self.append(buffer, sourceTime: sourceTime)
        }
    }

    public func appendExternalMic(_ sampleBuffer: CMSampleBuffer) {
        sessionQueue.async {
            guard self.acceptsSamples else { return self.rejectSample() }
            self.append(sampleBuffer, as: .mic)
        }
    }

    public func pause(at sourceTime: CMTime) {
        sessionQueue.async {
            guard case .recording = self.state else { return }
            self.timeline.pause(at: sourceTime)
            self.state = .paused
        }
    }

    public func resume(at sourceTime: CMTime) {
        sessionQueue.async {
            guard case .paused = self.state else { return }
            self.timeline.resume(at: sourceTime)
            self.state = .recording
        }
    }

    public func stop(at sourceTime: CMTime, completion: @escaping (Result<RecordingOutput, Error>) -> Void) {
        sessionQueue.async {
            guard self.state == .recording || self.state == .paused else {
                DispatchQueue.main.async { completion(.failure(RecordingSessionError.invalidStop)) }
                return
            }
            if self.state == .paused {
                self.timeline.resume(at: sourceTime)
            }
            self.state = .stopping
            let finalDuration = self.timeline.finalDuration(at: sourceTime)
            let tailVideoSample = self.tailVideoSample(at: finalDuration)

            self.writer.finish(finalDuration: finalDuration, tailVideoSample: tailVideoSample) { result in
                self.sessionQueue.async {
                    guard case .success = result else {
                        self.state = .stopped
                        if case let .failure(error) = result {
                            self.complete(.failure(error), using: completion)
                        }
                        return
                    }
                    self.state = .stopped
                    let request = RecordingFinalizerRequest(
                        sourceURL: self.configuration.writerConfiguration.outputURL,
                        outputURL: self.configuration.writerConfiguration.outputURL,
                        finalDuration: finalDuration,
                        mode: self.configuration.finalizerMode
                    )
                    self.finalizer.finalize(request) { result in
                        self.complete(result, using: completion)
                    }
                }
            }
        }
    }

    private var acceptsSamples: Bool {
        state == .recording
    }

    private func append(_ sampleBuffer: CMSampleBuffer, as media: Media) {
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationTime = timeline.presentationTime(for: sourceTime)
        guard let retimedSample = RecordingSampleRetimer.copy(sampleBuffer, presentationTime: presentationTime) else {
            rejectSample()
            return
        }
        switch media {
        case .video:
            lastVideoSample = retimedSample
            lastVideoPresentationTime = presentationTime
            writer.appendVideo(retimedSample)
        case .systemAudio:
            writer.appendSystemAudio(retimedSample)
        case .mic:
            writer.appendMic(retimedSample)
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, sourceTime: CMTime) {
        let presentationTime = timeline.presentationTime(for: sourceTime)
        guard let sampleBuffer = AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: presentationTime) else {
            rejectSample()
            return
        }
        writer.appendMic(sampleBuffer)
    }

    private func tailVideoSample(at finalDuration: CMTime) -> CMSampleBuffer? {
        guard let lastVideoSample, let lastVideoPresentationTime,
              CMTimeCompare(lastVideoPresentationTime, finalDuration) < 0 else {
            return nil
        }
        return RecordingSampleRetimer.copy(lastVideoSample, presentationTime: finalDuration)
    }

    private func rejectSample() {
        rejectedSamples += 1
    }

    private func complete(
        _ result: Result<RecordingOutput, Error>,
        using completion: @escaping (Result<RecordingOutput, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

private enum Media {
    case video
    case systemAudio
    case mic
}

private enum RecordingSessionError: Error {
    case invalidStart
    case invalidStop
}
