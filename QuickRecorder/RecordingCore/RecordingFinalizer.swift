import CoreMedia
import Foundation

public protocol RecordingFinalizing {
    func finalize(
        _ request: RecordingFinalizerRequest,
        completion: @escaping (Result<RecordingOutput, Error>) -> Void
    )
}

public struct RecordingFinalizerRequest {
    public let sourceURL: URL
    public let outputURL: URL
    public let finalDuration: CMTime
    public let mode: RecordingFinalizerMode

    public init(
        sourceURL: URL,
        outputURL: URL,
        finalDuration: CMTime,
        mode: RecordingFinalizerMode
    ) {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.finalDuration = finalDuration
        self.mode = mode
    }
}

public enum RecordingFinalizerMode {
    case videoWithoutRemux
    case videoWithRemux
    case pureAudioPackage
}

public struct RecordingOutput {
    public let url: URL
    public let duration: CMTime

    public init(url: URL, duration: CMTime) {
        self.url = url
        self.duration = duration
    }
}

public enum RecordingFinalizerError: LocalizedError {
    case remuxRequiresAppIntegration
    case audioPackageRequiresAppIntegration

    public var errorDescription: String? {
        switch self {
        case .remuxRequiresAppIntegration:
            return "Video remuxing is not available for this recording."
        case .audioPackageRequiresAppIntegration:
            return "Audio packaging is not available for this recording."
        }
    }
}

public struct RecordingFinalizer: RecordingFinalizing {
    public init() {}

    public func finalize(
        _ request: RecordingFinalizerRequest,
        completion: @escaping (Result<RecordingOutput, Error>) -> Void
    ) {
        let result: Result<RecordingOutput, Error>
        switch request.mode {
        case .videoWithoutRemux:
            result = .success(RecordingOutput(url: request.outputURL, duration: request.finalDuration))
        case .videoWithRemux:
            result = .failure(RecordingFinalizerError.remuxRequiresAppIntegration)
        case .pureAudioPackage:
            result = .failure(RecordingFinalizerError.audioPackageRequiresAppIntegration)
        }

        DispatchQueue.main.async {
            completion(result)
        }
    }

    public func outputTimeRange(finalDuration: CMTime) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: finalDuration)
    }
}

public struct RecordingFinalizerFilePolicy {
    public init() {}

    public func shouldDeleteIntermediateFiles(remuxSucceeded: Bool) -> Bool {
        remuxSucceeded
    }
}
