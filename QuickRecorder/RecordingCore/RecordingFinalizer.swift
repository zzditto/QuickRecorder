import AVFoundation
import CoreMedia
import Foundation

public struct RecordingQMAPackageInfo: Codable, Equatable {
    public let format: String
    public let encoder: String
    public let exportMP3: Bool
    public let sysVol: Float
    public let micVol: Float

    public init(
        format: String,
        encoder: String,
        exportMP3: Bool,
        sysVol: Float,
        micVol: Float
    ) {
        self.format = format
        self.encoder = encoder
        self.exportMP3 = exportMP3
        self.sysVol = sysVol
        self.micVol = micVol
    }
}

public struct RecordingQMAPackageOutput: Equatable {
    public let packageURL: URL
    public let info: RecordingQMAPackageInfo

    public init?(packageURL: URL, info: RecordingQMAPackageInfo) {
        guard Self.isSafeFileExtension(info.format) else {
            return nil
        }
        self.packageURL = packageURL
        self.info = info
    }

    public var systemAudioURL: URL {
        packageURL.appendingPathComponent("sys.\(info.format)")
    }

    public var microphoneAudioURL: URL {
        packageURL.appendingPathComponent("mic.\(info.format)")
    }

    private static func isSafeFileExtension(_ format: String) -> Bool {
        !format.isEmpty && !format.contains("/") && !format.contains("\\")
    }
}

public enum RecordingSessionOutput: Equatable {
    case videoDirect(outputURL: URL)
    case videoRemux(intermediateURL: URL, finalURL: URL)
    case pureAudio(outputURL: URL)
    case qmaPackage(RecordingQMAPackageOutput)

    public var finalURL: URL {
        switch self {
        case let .videoDirect(outputURL), let .pureAudio(outputURL):
            return outputURL
        case let .videoRemux(_, finalURL):
            return finalURL
        case let .qmaPackage(package):
            return package.packageURL
        }
    }

    var writerOutputURLs: [URL] {
        switch self {
        case let .videoDirect(outputURL), let .pureAudio(outputURL):
            return [outputURL]
        case let .videoRemux(intermediateURL, _):
            return [intermediateURL]
        case let .qmaPackage(package):
            return [package.systemAudioURL, package.microphoneAudioURL]
        }
    }
}

public enum RecordingSessionWriters {
    case single(RecordingWriterConfiguration)
    case qma(
        systemAudio: RecordingWriterConfiguration,
        microphoneAudio: RecordingWriterConfiguration
    )

    var configurations: [RecordingWriterConfiguration] {
        switch self {
        case let .single(configuration):
            return [configuration]
        case let .qma(systemAudio, microphoneAudio):
            return [systemAudio, microphoneAudio]
        }
    }
}

public protocol RecordingFinalizing {
    func finalize(
        _ request: RecordingFinalizerRequest,
        completion: @escaping (Result<RecordingOutput, Error>) -> Void
    )
}

public struct RecordingFinalizerRequest {
    public let output: RecordingSessionOutput
    public let finalDuration: CMTime

    public init(output: RecordingSessionOutput, finalDuration: CMTime) {
        self.output = output
        self.finalDuration = finalDuration
    }
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
    case missingVideoTrack
    case unsupportedVideoOutput(URL)
    case couldNotCreateExportSession
    case exportFailed(Error?)
    case missingQMAAudioFile(URL)
    case packageWriteFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "The recording has no video track to remux."
        case let .unsupportedVideoOutput(url):
            return "Unsupported video output type for \(url.lastPathComponent)."
        case .couldNotCreateExportSession:
            return "Could not create the video export session."
        case let .exportFailed(error):
            return error?.localizedDescription ?? "The video export failed."
        case let .missingQMAAudioFile(url):
            return "The QMA audio file is missing: \(url.lastPathComponent)."
        case let .packageWriteFailed(error):
            return "Could not write the QMA package: \(error.localizedDescription)"
        }
    }
}

protocol RecordingVideoRemuxing {
    func remux(
        sourceURL: URL,
        outputURL: URL,
        timeRange: CMTimeRange,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

private final class AVFoundationRecordingVideoRemuxer: RecordingVideoRemuxing {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func remux(
        sourceURL: URL,
        outputURL: URL,
        timeRange: CMTimeRange,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()
        guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            completion(.failure(RecordingFinalizerError.missingVideoTrack))
            return
        }
        do {
            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
        } catch {
            completion(.failure(error))
            return
        }

        var audioMixParameters: [AVAudioMixInputParameters] = []
        for sourceAudioTrack in asset.tracks(withMediaType: .audio) {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            do {
                try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            } catch {
                completion(.failure(error))
                return
            }
            audioMixParameters.append(AVMutableAudioMixInputParameters(track: compositionAudioTrack))
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            completion(.failure(RecordingFinalizerError.couldNotCreateExportSession))
            return
        }
        guard let outputFileType = outputFileType(for: outputURL) else {
            completion(.failure(RecordingFinalizerError.unsupportedVideoOutput(outputURL)))
            return
        }

        do {
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
        } catch {
            completion(.failure(error))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.timeRange = timeRange
        if !audioMixParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioMixParameters
            exportSession.audioMix = audioMix
        }
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(.success(()))
            case .failed, .cancelled:
                completion(.failure(RecordingFinalizerError.exportFailed(exportSession.error)))
            default:
                completion(.failure(RecordingFinalizerError.exportFailed(exportSession.error)))
            }
        }
    }

    private func outputFileType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mov":
            return .mov
        case "mp4", "m4v":
            return .mp4
        default:
            return nil
        }
    }
}

public struct RecordingFinalizer: RecordingFinalizing {
    private let remuxer: RecordingVideoRemuxing
    private let fileManager: FileManager

    public init() {
        self.init(fileManager: .default)
    }

    init(fileManager: FileManager, remuxer: RecordingVideoRemuxing? = nil) {
        self.fileManager = fileManager
        self.remuxer = remuxer ?? AVFoundationRecordingVideoRemuxer(fileManager: fileManager)
    }

    public func finalize(
        _ request: RecordingFinalizerRequest,
        completion: @escaping (Result<RecordingOutput, Error>) -> Void
    ) {
        switch request.output {
        case let .videoDirect(outputURL), let .pureAudio(outputURL):
            complete(.success(RecordingOutput(url: outputURL, duration: request.finalDuration)), using: completion)
        case let .videoRemux(intermediateURL, finalURL):
            finalizeVideoRemux(
                intermediateURL: intermediateURL,
                finalURL: finalURL,
                finalDuration: request.finalDuration,
                completion: completion
            )
        case let .qmaPackage(package):
            finalizeQMAPackage(package, finalDuration: request.finalDuration, completion: completion)
        }
    }

    public func outputTimeRange(finalDuration: CMTime) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: finalDuration)
    }

    private func finalizeVideoRemux(
        intermediateURL: URL,
        finalURL: URL,
        finalDuration: CMTime,
        completion: @escaping (Result<RecordingOutput, Error>) -> Void
    ) {
        remuxer.remux(
            sourceURL: intermediateURL,
            outputURL: finalURL,
            timeRange: outputTimeRange(finalDuration: finalDuration)
        ) { result in
            switch result {
            case .success:
                if self.fileManager.fileExists(atPath: intermediateURL.path) {
                    try? self.fileManager.removeItem(at: intermediateURL)
                }
                self.complete(
                    .success(RecordingOutput(url: finalURL, duration: finalDuration)),
                    using: completion
                )
            case let .failure(error):
                self.complete(.failure(error), using: completion)
            }
        }
    }

    private func finalizeQMAPackage(
        _ package: RecordingQMAPackageOutput,
        finalDuration: CMTime,
        completion: @escaping (Result<RecordingOutput, Error>) -> Void
    ) {
        do {
            guard fileManager.fileExists(atPath: package.systemAudioURL.path) else {
                throw RecordingFinalizerError.missingQMAAudioFile(package.systemAudioURL)
            }
            guard fileManager.fileExists(atPath: package.microphoneAudioURL.path) else {
                throw RecordingFinalizerError.missingQMAAudioFile(package.microphoneAudioURL)
            }
            try fileManager.createDirectory(at: package.packageURL, withIntermediateDirectories: true)
            let infoData = try JSONEncoder().encode(package.info)
            try infoData.write(
                to: package.packageURL.appendingPathComponent("info.json"),
                options: .atomic
            )
            complete(
                .success(RecordingOutput(url: package.packageURL, duration: finalDuration)),
                using: completion
            )
        } catch let error as RecordingFinalizerError {
            complete(.failure(error), using: completion)
        } catch {
            complete(.failure(RecordingFinalizerError.packageWriteFailed(error)), using: completion)
        }
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

public struct RecordingFinalizerFilePolicy {
    public init() {}

    public func shouldDeleteIntermediateFiles(remuxSucceeded: Bool) -> Bool {
        remuxSucceeded
    }
}
