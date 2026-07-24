import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingFinalizerTests: XCTestCase {
    func testOutputModesExposeTheirFinalDestinations() throws {
        let directory = URL(fileURLWithPath: "/tmp")
        let directURL = directory.appendingPathComponent("direct.mov")
        let remuxURL = directory.appendingPathComponent("remux.mov")
        let audioURL = directory.appendingPathComponent("audio.m4a")
        let packageURL = directory.appendingPathComponent("audio.qma")
        let outputs: [RecordingSessionOutput] = [
            .videoDirect(outputURL: directURL),
            .videoRemux(
                intermediateURL: directory.appendingPathComponent("intermediate.mov"),
                finalURL: remuxURL
            ),
            .pureAudio(outputURL: audioURL),
            .qmaPackage(
                try XCTUnwrap(RecordingQMAPackageOutput(
                    packageURL: packageURL,
                    info: RecordingQMAPackageInfo(
                        format: "m4a",
                        encoder: "aac",
                        exportMP3: false,
                        sysVol: 1,
                        micVol: 1
                    )
                ))
            )
        ]

        XCTAssertEqual(outputs.map(\.finalURL), [directURL, remuxURL, audioURL, packageURL])
    }

    func testRequestCarriesExplicitOutputAndFinalDuration() {
        let intermediateURL = URL(fileURLWithPath: "/tmp/quick-recorder-intermediate.mov")
        let finalURL = URL(fileURLWithPath: "/tmp/quick-recorder-final.mov")
        let output = RecordingSessionOutput.videoRemux(
            intermediateURL: intermediateURL,
            finalURL: finalURL
        )
        let duration = CMTime(seconds: 42, preferredTimescale: 600)

        let request = RecordingFinalizerRequest(output: output, finalDuration: duration)

        XCTAssertEqual(request.finalDuration, duration)
        guard case let .videoRemux(requestIntermediateURL, requestFinalURL) = request.output else {
            return XCTFail("Expected video remux output")
        }
        XCTAssertEqual(requestIntermediateURL, intermediateURL)
        XCTAssertEqual(requestFinalURL, finalURL)
    }

    func testQMAPackageOutputDerivesAudioURLsInsidePackageFromInfoFormat() throws {
        let packageURL = URL(fileURLWithPath: "/tmp/quick-recorder.qma")
        let info = RecordingQMAPackageInfo(
            format: "m4a",
            encoder: "aac",
            exportMP3: false,
            sysVol: 0.8,
            micVol: 0.6
        )
        let output = RecordingSessionOutput.qmaPackage(
            try XCTUnwrap(RecordingQMAPackageOutput(
                packageURL: packageURL,
                info: info
            ))
        )

        guard case let .qmaPackage(package) = output else {
            return XCTFail("Expected QMA package output")
        }
        XCTAssertEqual(package.packageURL, packageURL)
        XCTAssertEqual(package.systemAudioURL, packageURL.appendingPathComponent("sys.m4a"))
        XCTAssertEqual(package.microphoneAudioURL, packageURL.appendingPathComponent("mic.m4a"))
        XCTAssertEqual(package.info, info)
    }

    func testQMAPackageOutputRejectsUnsafeFormat() {
        let package = RecordingQMAPackageOutput(
            packageURL: URL(fileURLWithPath: "/tmp/quick-recorder.qma"),
            info: RecordingQMAPackageInfo(
                format: "m4a/external",
                encoder: "aac",
                exportMP3: false,
                sysVol: 1,
                micVol: 1
            )
        )

        XCTAssertNil(package)
    }

    func testVideoRemuxUsesFinalDurationNotAssetDuration() {
        let finalizer = RecordingFinalizer()
        let range = finalizer.outputTimeRange(finalDuration: CMTime(seconds: 42, preferredTimescale: 600))
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration.seconds, 42, accuracy: 0.001)
    }

    func testAudioRemuxRangeUsesCompleteSourceRangeWhenItFitsOutput() {
        let outputRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        let sourceRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))

        XCTAssertEqual(
            RecordingRemuxTimeRange.audioSourceTimeRange(sourceRange, within: outputRange),
            sourceRange
        )
    }

    func testAudioRemuxRangeBoundsShortSourceRangeToItsAvailableDuration() {
        let outputRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        let sourceRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))

        XCTAssertEqual(
            RecordingRemuxTimeRange.audioSourceTimeRange(sourceRange, within: outputRange),
            sourceRange
        )
    }

    func testAudioRemuxRangePreservesDelayedSourceStart() {
        let outputRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: 2, preferredTimescale: 600),
            duration: CMTime(seconds: 6, preferredTimescale: 600)
        )

        XCTAssertEqual(
            RecordingRemuxTimeRange.audioSourceTimeRange(sourceRange, within: outputRange),
            CMTimeRange(
                start: CMTime(seconds: 2, preferredTimescale: 600),
                duration: CMTime(seconds: 3, preferredTimescale: 600)
            )
        )
    }

    func testAudioRemuxRangeSkipsSourceWithoutPositiveDurationIntersection() {
        let outputRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: 5, preferredTimescale: 600),
            duration: CMTime(seconds: 2, preferredTimescale: 600)
        )

        XCTAssertNil(RecordingRemuxTimeRange.audioSourceTimeRange(sourceRange, within: outputRange))
    }

    func testVideoRemuxFinalizesWithRangeFromFinalDuration() {
        let remuxer = RecordingVideoRemuxerSpy(result: .success(()))
        let finalizer = RecordingFinalizer(fileManager: .default, remuxer: remuxer)
        let intermediateURL = URL(fileURLWithPath: "/tmp/quick-recorder-intermediate.mov")
        let finalURL = URL(fileURLWithPath: "/tmp/quick-recorder-final.mov")
        let completion = expectation(description: "finalized")

        finalizer.finalize(
            RecordingFinalizerRequest(
                output: .videoRemux(intermediateURL: intermediateURL, finalURL: finalURL),
                finalDuration: CMTime(seconds: 42, preferredTimescale: 600)
            )
        ) { result in
            guard case let .success(output) = result else {
                return XCTFail("Expected successful remux")
            }
            XCTAssertEqual(output.url, finalURL)
            XCTAssertEqual(output.duration.seconds, 42, accuracy: 0.001)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(remuxer.timeRanges.count, 1)
        XCTAssertEqual(remuxer.timeRanges[0].start, .zero)
        XCTAssertEqual(remuxer.timeRanges[0].duration.seconds, 42, accuracy: 0.001)
    }

    func testFailedRemuxPreservesIntermediateFiles() {
        let policy = RecordingFinalizerFilePolicy()
        XCTAssertFalse(policy.shouldDeleteIntermediateFiles(remuxSucceeded: false))
        XCTAssertTrue(policy.shouldDeleteIntermediateFiles(remuxSucceeded: true))
    }

    func testFailedRemuxPreservesIntermediateFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let intermediateURL = directory.appendingPathComponent("recording.intermediate.mov")
        try Data("source".utf8).write(to: intermediateURL)
        let finalizer = RecordingFinalizer(
            fileManager: .default,
            remuxer: RecordingVideoRemuxerSpy(result: .failure(RemuxFailure()))
        )
        let completion = expectation(description: "remux failure")

        finalizer.finalize(
            RecordingFinalizerRequest(
                output: .videoRemux(
                    intermediateURL: intermediateURL,
                    finalURL: directory.appendingPathComponent("recording.mov")
                ),
                finalDuration: CMTime(seconds: 5, preferredTimescale: 600)
            )
        ) { result in
            guard case .failure = result else {
                return XCTFail("Expected remux failure")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: intermediateURL.path))
    }

    func testSuccessfulRemuxDeletesIntermediateFileAfterExport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let intermediateURL = directory.appendingPathComponent("recording.intermediate.mov")
        try Data("source".utf8).write(to: intermediateURL)
        let finalizer = RecordingFinalizer(
            fileManager: .default,
            remuxer: RecordingVideoRemuxerSpy(result: .success(()))
        )
        let completion = expectation(description: "remux success")

        finalizer.finalize(
            RecordingFinalizerRequest(
                output: .videoRemux(
                    intermediateURL: intermediateURL,
                    finalURL: directory.appendingPathComponent("recording.mov")
                ),
                finalDuration: CMTime(seconds: 5, preferredTimescale: 600)
            )
        ) { result in
            guard case .success = result else {
                return XCTFail("Expected remux success")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intermediateURL.path))
    }

    func testQMAPackageWritesInfoAfterBothAudioFilesExist() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("recording.qma")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let info = RecordingQMAPackageInfo(
            format: "m4a",
            encoder: "aac",
            exportMP3: false,
            sysVol: 1,
            micVol: 1
        )
        let package = try XCTUnwrap(
            RecordingQMAPackageOutput(packageURL: packageURL, info: info)
        )
        try Data("system".utf8).write(to: package.systemAudioURL)
        try Data("microphone".utf8).write(to: package.microphoneAudioURL)
        let completion = expectation(description: "QMA finalized")

        RecordingFinalizer().finalize(
            RecordingFinalizerRequest(
                output: .qmaPackage(
                    package
                ),
                finalDuration: CMTime(seconds: 5, preferredTimescale: 600)
            )
        ) { result in
            guard case let .success(output) = result else {
                return XCTFail("Expected successful QMA package")
            }
            XCTAssertEqual(output.url, packageURL)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        let infoData = try Data(contentsOf: packageURL.appendingPathComponent("info.json"))
        XCTAssertEqual(try JSONDecoder().decode(RecordingQMAPackageInfo.self, from: infoData), info)
    }

    func testFailedQMAPackagePreservesExistingPackageFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("recording.qma")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let info = RecordingQMAPackageInfo(
            format: "m4a",
            encoder: "aac",
            exportMP3: false,
            sysVol: 1,
            micVol: 1
        )
        let package = try XCTUnwrap(
            RecordingQMAPackageOutput(packageURL: packageURL, info: info)
        )
        let systemAudioURL = package.systemAudioURL
        let microphoneAudioURL = package.microphoneAudioURL
        try Data("system".utf8).write(to: systemAudioURL)
        let completion = expectation(description: "QMA failure")

        RecordingFinalizer().finalize(
            RecordingFinalizerRequest(
                output: .qmaPackage(
                    package
                ),
                finalDuration: CMTime(seconds: 5, preferredTimescale: 600)
            )
        ) { result in
            guard case .failure = result else {
                return XCTFail("Expected QMA package failure")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneAudioURL.path))
    }

    func testVideoWithoutRemuxReturnsCompletedOutput() {
        let finalizer = RecordingFinalizer()
        let outputURL = URL(fileURLWithPath: "/tmp/quick-recorder-test.mov")
        let request = RecordingFinalizerRequest(
            output: .videoDirect(outputURL: outputURL),
            finalDuration: CMTime(seconds: 5, preferredTimescale: 600)
        )
        let completion = expectation(description: "finalized")

        finalizer.finalize(request) { result in
            guard case let .success(output) = result else {
                return XCTFail("Expected successful output")
            }
            XCTAssertEqual(output.url, outputURL)
            XCTAssertEqual(output.duration.seconds, 5, accuracy: 0.001)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class RecordingVideoRemuxerSpy: RecordingVideoRemuxing {
    let result: Result<Void, Error>
    private(set) var timeRanges: [CMTimeRange] = []

    init(result: Result<Void, Error>) {
        self.result = result
    }

    func remux(
        sourceURL: URL,
        outputURL: URL,
        timeRange: CMTimeRange,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        timeRanges.append(timeRange)
        completion(result)
    }
}

private struct RemuxFailure: Error {}
