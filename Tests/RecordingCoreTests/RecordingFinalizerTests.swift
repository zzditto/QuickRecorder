import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingFinalizerTests: XCTestCase {
    func testOutputModesExposeTheirFinalDestinations() {
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
                RecordingQMAPackageOutput(
                    packageURL: packageURL,
                    systemAudioURL: packageURL.appendingPathComponent("sys.m4a"),
                    microphoneAudioURL: packageURL.appendingPathComponent("mic.m4a"),
                    info: RecordingQMAPackageInfo(
                        format: "m4a",
                        encoder: "aac",
                        exportMP3: false,
                        sysVol: 1,
                        micVol: 1
                    )
                )
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

    func testQMAPackageOutputIncludesAudioURLsAndInfo() {
        let packageURL = URL(fileURLWithPath: "/tmp/quick-recorder.qma")
        let systemAudioURL = packageURL.appendingPathComponent("sys.m4a")
        let microphoneAudioURL = packageURL.appendingPathComponent("mic.m4a")
        let info = RecordingQMAPackageInfo(
            format: "m4a",
            encoder: "aac",
            exportMP3: false,
            sysVol: 0.8,
            micVol: 0.6
        )
        let output = RecordingSessionOutput.qmaPackage(
            RecordingQMAPackageOutput(
                packageURL: packageURL,
                systemAudioURL: systemAudioURL,
                microphoneAudioURL: microphoneAudioURL,
                info: info
            )
        )

        guard case let .qmaPackage(package) = output else {
            return XCTFail("Expected QMA package output")
        }
        XCTAssertEqual(package.packageURL, packageURL)
        XCTAssertEqual(package.systemAudioURL, systemAudioURL)
        XCTAssertEqual(package.microphoneAudioURL, microphoneAudioURL)
        XCTAssertEqual(package.info, info)
    }

    func testVideoRemuxUsesFinalDurationNotAssetDuration() {
        let finalizer = RecordingFinalizer()
        let range = finalizer.outputTimeRange(finalDuration: CMTime(seconds: 42, preferredTimescale: 600))
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration.seconds, 42, accuracy: 0.001)
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
        let systemAudioURL = packageURL.appendingPathComponent("sys.m4a")
        let microphoneAudioURL = packageURL.appendingPathComponent("mic.m4a")
        try Data("system".utf8).write(to: systemAudioURL)
        try Data("microphone".utf8).write(to: microphoneAudioURL)
        let info = RecordingQMAPackageInfo(
            format: "m4a",
            encoder: "aac",
            exportMP3: false,
            sysVol: 1,
            micVol: 1
        )
        let completion = expectation(description: "QMA finalized")

        RecordingFinalizer().finalize(
            RecordingFinalizerRequest(
                output: .qmaPackage(
                    RecordingQMAPackageOutput(
                        packageURL: packageURL,
                        systemAudioURL: systemAudioURL,
                        microphoneAudioURL: microphoneAudioURL,
                        info: info
                    )
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
        let systemAudioURL = packageURL.appendingPathComponent("sys.m4a")
        let microphoneAudioURL = packageURL.appendingPathComponent("mic.m4a")
        try Data("system".utf8).write(to: systemAudioURL)
        let completion = expectation(description: "QMA failure")

        RecordingFinalizer().finalize(
            RecordingFinalizerRequest(
                output: .qmaPackage(
                    RecordingQMAPackageOutput(
                        packageURL: packageURL,
                        systemAudioURL: systemAudioURL,
                        microphoneAudioURL: microphoneAudioURL,
                        info: RecordingQMAPackageInfo(
                            format: "m4a",
                            encoder: "aac",
                            exportMP3: false,
                            sysVol: 1,
                            micVol: 1
                        )
                    )
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
