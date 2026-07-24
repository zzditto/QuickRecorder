import AVFoundation
import CoreMedia
import Foundation

public struct RecordingWriterConfiguration {
    public let outputURL: URL
    public let fileType: AVFileType
    public let videoOutputSettings: [String: Any]?
    public let systemAudioOutputSettings: [String: Any]?
    public let micOutputSettings: [String: Any]?

    public var writesVideo: Bool { videoOutputSettings != nil }
    public var writesSystemAudio: Bool { systemAudioOutputSettings != nil }
    public var writesMicrophoneAudio: Bool { micOutputSettings != nil }

    public init(
        outputURL: URL,
        fileType: AVFileType,
        videoOutputSettings: [String: Any]? = nil,
        systemAudioOutputSettings: [String: Any]? = nil,
        micOutputSettings: [String: Any]? = nil
    ) {
        self.outputURL = outputURL
        self.fileType = fileType
        self.videoOutputSettings = videoOutputSettings
        self.systemAudioOutputSettings = systemAudioOutputSettings
        self.micOutputSettings = micOutputSettings
    }
}

public struct RecordingWriterSummary {
    public let droppedVideoSampleCount: Int
    public let droppedSystemAudioSampleCount: Int
    public let droppedMicSampleCount: Int

    init(droppedVideoSampleCount: Int, droppedSystemAudioSampleCount: Int, droppedMicSampleCount: Int) {
        self.droppedVideoSampleCount = droppedVideoSampleCount
        self.droppedSystemAudioSampleCount = droppedSystemAudioSampleCount
        self.droppedMicSampleCount = droppedMicSampleCount
    }
}

struct RecordingWriterStateMachine {
    private enum State {
        case idle
        case acceptingSamples
        case stopping
        case finished
    }

    private var state: State = .idle

    var canStart: Bool {
        if case .idle = state {
            return true
        }
        return false
    }

    var acceptsSamples: Bool {
        if case .acceptingSamples = state {
            return true
        }
        return false
    }

    var canCancel: Bool {
        switch state {
        case .acceptingSamples, .stopping:
            return true
        case .idle, .finished:
            return false
        }
    }

    mutating func beginStopping() {
        guard acceptsSamples else { return }
        state = .stopping
    }

    mutating func start() {
        guard canStart else { return }
        state = .acceptingSamples
    }

    mutating func finish() {
        state = .finished
    }

    mutating func cancel() {
        guard canCancel else { return }
        state = .finished
    }
}

protocol RecordingWriterAdapting: AnyObject {
    var isReadyForVideo: Bool { get }
    var isReadyForSystemAudio: Bool { get }
    var isReadyForMic: Bool { get }
    func startWriting() throws
    func startSession(at time: CMTime)
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) -> Bool
    func appendMic(_ sampleBuffer: CMSampleBuffer) -> Bool
    func endSession(at time: CMTime)
    func markVideoFinished()
    func markSystemAudioFinished()
    func markMicFinished()
    func finishWriting(completion: @escaping (Error?) -> Void)
    func cancelWriting()
}

final class AVAssetWriterAdapter: RecordingWriterAdapting {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let systemAudioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?

    convenience init(configuration: RecordingWriterConfiguration) throws {
        let writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: configuration.fileType)
        self.init(writer: writer, configuration: configuration)
    }

    init(writer: AVAssetWriter, configuration: RecordingWriterConfiguration) {
        self.writer = writer
        videoInput = Self.makeInput(mediaType: .video, settings: configuration.videoOutputSettings, writer: writer)
        systemAudioInput = Self.makeInput(mediaType: .audio, settings: configuration.systemAudioOutputSettings, writer: writer)
        micInput = Self.makeInput(mediaType: .audio, settings: configuration.micOutputSettings, writer: writer)
    }

    var isReadyForVideo: Bool { videoInput?.isReadyForMoreMediaData ?? false }
    var isReadyForSystemAudio: Bool { systemAudioInput?.isReadyForMoreMediaData ?? false }
    var isReadyForMic: Bool { micInput?.isReadyForMoreMediaData ?? false }

    func startWriting() throws {
        guard writer.startWriting() else {
            throw writer.error ?? RecordingWriterError.failedToStart
        }
    }

    func startSession(at time: CMTime) {
        writer.startSession(atSourceTime: time)
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        videoInput?.append(sampleBuffer) ?? false
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        systemAudioInput?.append(sampleBuffer) ?? false
    }

    func appendMic(_ sampleBuffer: CMSampleBuffer) -> Bool {
        micInput?.append(sampleBuffer) ?? false
    }

    func endSession(at time: CMTime) {
        writer.endSession(atSourceTime: time)
    }

    func markVideoFinished() {
        videoInput?.markAsFinished()
    }

    func markSystemAudioFinished() {
        systemAudioInput?.markAsFinished()
    }

    func markMicFinished() {
        micInput?.markAsFinished()
    }

    func finishWriting(completion: @escaping (Error?) -> Void) {
        writer.finishWriting {
            completion(self.writer.error)
        }
    }

    func cancelWriting() {
        writer.cancelWriting()
    }

    private static func makeInput(
        mediaType: AVMediaType,
        settings: [String: Any]?,
        writer: AVAssetWriter
    ) -> AVAssetWriterInput? {
        guard let settings else { return nil }
        let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }
}

public final class RecordingWriter {
    private let adapter: RecordingWriterAdapting
    private let writerQueue = DispatchQueue(label: "QuickRecorder.RecordingWriter")
    private var state = RecordingWriterStateMachine()
    private var hasStartedSession = false
    private var droppedVideoSampleCount = 0
    private var droppedSystemAudioSampleCount = 0
    private var droppedMicSampleCount = 0

    public init(configuration: RecordingWriterConfiguration) throws {
        adapter = try AVAssetWriterAdapter(configuration: configuration)
    }

    init(adapter: RecordingWriterAdapting) {
        self.adapter = adapter
    }

    public func start() throws {
        try writerQueue.sync {
            guard state.canStart else {
                throw RecordingWriterError.invalidStart
            }
            try adapter.startWriting()
            adapter.startSession(at: .zero)
            hasStartedSession = true
            state.start()
        }
    }

    public func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async {
            guard self.state.acceptsSamples else {
                self.droppedVideoSampleCount += 1
                return
            }
            self.startSessionIfNeeded()
            guard self.adapter.isReadyForVideo, self.adapter.appendVideo(sampleBuffer) else {
                self.droppedVideoSampleCount += 1
                return
            }
        }
    }

    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async {
            guard self.state.acceptsSamples else {
                self.droppedSystemAudioSampleCount += 1
                return
            }
            self.startSessionIfNeeded()
            guard self.adapter.isReadyForSystemAudio, self.adapter.appendSystemAudio(sampleBuffer) else {
                self.droppedSystemAudioSampleCount += 1
                return
            }
        }
    }

    public func appendMic(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async {
            guard self.state.acceptsSamples else {
                self.droppedMicSampleCount += 1
                return
            }
            self.startSessionIfNeeded()
            guard self.adapter.isReadyForMic, self.adapter.appendMic(sampleBuffer) else {
                self.droppedMicSampleCount += 1
                return
            }
        }
    }

    public func finish(
        finalDuration: CMTime,
        tailVideoSample: CMSampleBuffer?,
        completion: @escaping (Result<RecordingWriterSummary, Error>) -> Void
    ) {
        writerQueue.sync {
            guard self.state.acceptsSamples else {
                self.complete(.failure(RecordingWriterError.invalidFinish), using: completion)
                return
            }
            self.state.beginStopping()
            if let tailVideoSample {
                self.startSessionIfNeeded()
                if !self.adapter.isReadyForVideo || !self.adapter.appendVideo(tailVideoSample) {
                    self.droppedVideoSampleCount += 1
                }
            }
            self.adapter.endSession(at: finalDuration)
            self.adapter.markVideoFinished()
            self.adapter.markSystemAudioFinished()
            self.adapter.markMicFinished()
            self.adapter.finishWriting { error in
                self.writerQueue.async {
                    self.state.finish()
                    let result: Result<RecordingWriterSummary, Error>
                    if let error {
                        result = .failure(error)
                    } else {
                        result = .success(self.makeSummary())
                    }
                    self.complete(result, using: completion)
                }
            }
        }
    }

    func cancel() {
        writerQueue.sync {
            guard state.canCancel else { return }
            state.cancel()
            adapter.cancelWriting()
        }
    }

    private func startSessionIfNeeded() {
        guard !hasStartedSession else { return }
        adapter.startSession(at: .zero)
        hasStartedSession = true
    }

    private func makeSummary() -> RecordingWriterSummary {
        RecordingWriterSummary(
            droppedVideoSampleCount: droppedVideoSampleCount,
            droppedSystemAudioSampleCount: droppedSystemAudioSampleCount,
            droppedMicSampleCount: droppedMicSampleCount
        )
    }

    private func complete(
        _ result: Result<RecordingWriterSummary, Error>,
        using completion: @escaping (Result<RecordingWriterSummary, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

private enum RecordingWriterError: Error {
    case failedToStart
    case invalidStart
    case invalidFinish
}
