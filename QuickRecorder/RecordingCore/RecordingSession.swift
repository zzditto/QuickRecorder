import AVFoundation
import CoreMedia
import Foundation

public struct RecordingSessionConfiguration {
    public let writers: RecordingSessionWriters
    public let output: RecordingSessionOutput

    public init(
        writers: RecordingSessionWriters,
        output: RecordingSessionOutput
    ) {
        precondition(
            writers.configurations.map(\.outputURL) == output.writerOutputURLs,
            "Writer destinations must match the recording output."
        )
        self.writers = writers
        self.output = output
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
    private let writers: [RecordingWriter]
    private let writerCreationError: Error?
    private let sourceClock: RecordingSourceClock
    private let sessionQueue = DispatchQueue(label: "QuickRecorder.RecordingSession")
    private var state: State = .idle
    private var timeline = RecordingTimeline()
    private var displayStartSourceTime: CMTime?
    private var displayPauseStartSourceTime: CMTime?
    private var displayAccumulatedPauseDuration: CMTime = .zero
    private var displayStopSourceTime: CMTime?
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoPresentationTime: CMTime?
    private var aecClock: AECAudioClock?
    private var aecSegmentStartSourceTime: CMTime?
    private var rejectedSamples = 0

    public init(configuration: RecordingSessionConfiguration, finalizer: RecordingFinalizing) {
        self.configuration = configuration
        self.finalizer = finalizer
        self.sourceClock = HostTimeRecordingSourceClock()
        do {
            if case let .qmaPackage(package) = configuration.output {
                try FileManager.default.createDirectory(
                    at: package.packageURL,
                    withIntermediateDirectories: true
                )
            }
            writers = try configuration.writers.configurations.map(RecordingWriter.init(configuration:))
            writerCreationError = nil
        } catch {
            writers = []
            writerCreationError = error
        }
    }

    convenience init(
        configuration: RecordingSessionConfiguration,
        finalizer: RecordingFinalizing,
        writer: RecordingWriter,
        sourceClock: RecordingSourceClock = HostTimeRecordingSourceClock()
    ) {
        self.init(
            configuration: configuration,
            finalizer: finalizer,
            writers: [writer],
            sourceClock: sourceClock
        )
    }

    init(
        configuration: RecordingSessionConfiguration,
        finalizer: RecordingFinalizing,
        writers: [RecordingWriter],
        sourceClock: RecordingSourceClock = HostTimeRecordingSourceClock()
    ) {
        self.configuration = configuration
        self.finalizer = finalizer
        self.writers = writers
        self.writerCreationError = nil
        self.sourceClock = sourceClock
    }

    init(
        configuration: RecordingSessionConfiguration,
        finalizer: RecordingFinalizing,
        writerCreationError: Error,
        sourceClock: RecordingSourceClock = HostTimeRecordingSourceClock()
    ) {
        self.configuration = configuration
        self.finalizer = finalizer
        self.writers = []
        self.writerCreationError = writerCreationError
        self.sourceClock = sourceClock
    }

    public var rejectedSampleCount: Int {
        sessionQueue.sync { rejectedSamples }
    }

    public var elapsedDisplayTime: TimeInterval {
        sessionQueue.sync {
            displayElapsedTime(at: sourceClock.currentSourceTime()).seconds
        }
    }

    public func start() throws {
        try sessionQueue.sync {
            guard case .idle = state else {
                throw RecordingSessionError.invalidStart
            }
            if let writerCreationError {
                throw RecordingSessionError.writerCreationFailed(writerCreationError)
            }
            guard !writers.isEmpty else {
                throw RecordingSessionError.writerCreationFailed(RecordingSessionError.writerUnavailable)
            }
            var startedWriters: [RecordingWriter] = []
            do {
                for writer in writers {
                    try writer.start()
                    startedWriters.append(writer)
                }
            } catch {
                startedWriters.forEach { $0.cancel() }
                throw RecordingSessionError.writerStartFailed(error)
            }
            state = .recording
            displayStartSourceTime = sourceClock.currentSourceTime()
            displayStopSourceTime = nil
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
            guard time.isHostTimeValid,
                  let sourceTime = self.sourceClock.sourceTime(forHostTime: time.hostTime) else {
                return self.rejectSample()
            }
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
                    startTime: self.aecSegmentStartSourceTime
                        ?? self.timeline.sourceStartTime
                        ?? self.sourceClock.currentSourceTime()
                )
                self.aecSegmentStartSourceTime = nil
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

    public func pause() {
        sessionQueue.async {
            self.pauseLocked(at: self.sourceClock.currentSourceTime())
        }
    }

    func pause(at sourceTime: CMTime) {
        sessionQueue.async {
            self.pauseLocked(at: sourceTime)
        }
    }

    public func resume() {
        sessionQueue.async {
            self.resumeLocked(at: self.sourceClock.currentSourceTime())
        }
    }

    func resume(at sourceTime: CMTime) {
        sessionQueue.async {
            self.resumeLocked(at: sourceTime)
        }
    }

    public func stop(completion: @escaping (Result<RecordingOutput, Error>) -> Void) {
        sessionQueue.async {
            self.stopLocked(at: self.sourceClock.currentSourceTime(), completion: completion)
        }
    }

    func stop(at sourceTime: CMTime, completion: @escaping (Result<RecordingOutput, Error>) -> Void) {
        sessionQueue.async {
            self.stopLocked(at: sourceTime, completion: completion)
        }
    }

    private var acceptsSamples: Bool {
        state == .recording
    }

    private func pauseLocked(at sourceTime: CMTime) {
        guard case .recording = state else { return }
        timeline.pause(at: sourceTime)
        displayPauseStartSourceTime = sourceTime
        state = .paused
    }

    private func resumeLocked(at sourceTime: CMTime) {
        guard case .paused = state else { return }
        timeline.resume(at: sourceTime)
        if let displayPauseStartSourceTime {
            displayAccumulatedPauseDuration = CMTimeAdd(
                displayAccumulatedPauseDuration,
                CMTimeMaximum(.zero, CMTimeSubtract(sourceTime, displayPauseStartSourceTime))
            )
            self.displayPauseStartSourceTime = nil
        }
        aecClock = nil
        aecSegmentStartSourceTime = sourceTime
        state = .recording
    }

    private func displayElapsedTime(at sourceTime: CMTime) -> CMTime {
        guard let displayStartSourceTime else { return .zero }
        let endTime = displayStopSourceTime ?? displayPauseStartSourceTime ?? sourceTime
        let elapsed = CMTimeSubtract(endTime, displayStartSourceTime)
        return CMTimeMaximum(.zero, CMTimeSubtract(elapsed, displayAccumulatedPauseDuration))
    }

    private func stopLocked(
        at sourceTime: CMTime,
        completion: @escaping (Result<RecordingOutput, Error>) -> Void
    ) {
        guard state == .recording || state == .paused else {
            DispatchQueue.main.async { completion(.failure(RecordingSessionError.invalidStop)) }
            return
        }
        if state == .paused {
            resumeLocked(at: sourceTime)
        }
        displayStopSourceTime = sourceTime
        state = .stopping
        let finalDuration = timeline.finalDuration(at: sourceTime)
        let tailVideoSample = tailVideoSample(at: finalDuration)

        guard !writers.isEmpty else {
            state = .stopped
            complete(
                .failure(RecordingSessionError.writerCreationFailed(RecordingSessionError.writerUnavailable)),
                using: completion
            )
            return
        }
        let writerCompletionGroup = DispatchGroup()
        var writerError: Error?
        for writer in writers {
            writerCompletionGroup.enter()
            writer.finish(finalDuration: finalDuration, tailVideoSample: tailVideoSample) { result in
                self.sessionQueue.async {
                    if case let .failure(error) = result, writerError == nil {
                        writerError = error
                    }
                    writerCompletionGroup.leave()
                }
            }
        }
        writerCompletionGroup.notify(queue: sessionQueue) {
            self.state = .stopped
            if let writerError {
                self.complete(.failure(writerError), using: completion)
                return
            }
            let request = RecordingFinalizerRequest(
                output: self.configuration.output,
                finalDuration: finalDuration
            )
            self.finalizer.finalize(request) { result in
                self.complete(result, using: completion)
            }
        }
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
            writers.forEach { $0.appendVideo(retimedSample) }
        case .systemAudio:
            writers.forEach { $0.appendSystemAudio(retimedSample) }
        case .mic:
            writers.forEach { $0.appendMic(retimedSample) }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, sourceTime: CMTime) {
        let presentationTime = timeline.presentationTime(for: sourceTime)
        guard let sampleBuffer = AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: presentationTime) else {
            rejectSample()
            return
        }
        writers.forEach { $0.appendMic(sampleBuffer) }
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

public enum RecordingSessionError: Error {
    case writerCreationFailed(Error)
    case writerStartFailed(Error)
    case invalidStart
    case invalidStop
    case writerUnavailable
}
