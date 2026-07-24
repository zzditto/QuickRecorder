# 录制稳定性系统修复实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 用单一录制内核完整接管 QuickRecorder 的媒体时间轴、writer 写入、停止、remux 和纯音频后处理，修复 QR-REC-001 至 QR-REC-007，且不保留旧 writer 直写路径。

**架构：** `SCContext` 和 `RecordEngine` 只负责 UI/采集入口转发；`RecordingSession` 拥有串行 session queue 和 timeline；`RecordingWriter` 完整拥有 `AVAssetWriter` 生命周期；`RecordingFinalizer` 完整拥有后处理。所有视频、系统音频、默认麦克风、AEC 麦克风、外接麦克风都进入同一 session。

**技术栈：** Swift 5、Foundation、CoreMedia、AVFoundation、ScreenCaptureKit、SwiftPM/XCTest、Xcode macOS app build。

---

## 文件结构

- 创建：`Package.swift`
- 创建：`QuickRecorder/RecordingCore/RecordingTimeline.swift`
- 创建：`QuickRecorder/RecordingCore/SampleRetiming.swift`
- 创建：`QuickRecorder/RecordingCore/AudioSampleBufferFactory.swift`
- 创建：`QuickRecorder/RecordingCore/AECAudioClock.swift`
- 创建：`QuickRecorder/RecordingCore/RecordingWriter.swift`
- 创建：`QuickRecorder/RecordingCore/RecordingFinalizer.swift`
- 创建：`QuickRecorder/RecordingCore/RecordingSession.swift`
- 创建：`Tests/RecordingCoreTests/RecordingTimelineTests.swift`
- 创建：`Tests/RecordingCoreTests/SampleRetimingTests.swift`
- 创建：`Tests/RecordingCoreTests/AudioSampleBufferFactoryTests.swift`
- 创建：`Tests/RecordingCoreTests/AECAudioClockTests.swift`
- 创建：`Tests/RecordingCoreTests/RecordingWriterStateTests.swift`
- 创建：`Tests/RecordingCoreTests/RecordingWriterOrderTests.swift`
- 创建：`Tests/RecordingCoreTests/RecordingFinalizerTests.swift`
- 创建：`Tests/RecordingCoreTests/RecordingSessionTests.swift`
- 修改：`QuickRecorder.xcodeproj/project.pbxproj`
- 修改：`QuickRecorder/SCContext.swift`
- 修改：`QuickRecorder/RecordEngine.swift`
- 修改：`QuickRecorder/ViewModel/StatusBar.swift`
- 修改：`docs/recording-issues.md`

## 执行约束和阶段门禁

本计划采用分阶段切换，但最终结果必须是单一录制内核；不得新增第二套 writer 路径、不得设置过渡兼容层、不得把旧路径作为长期 fallback 保留。

### 每个任务都必须遵守

- 不允许新增 `SCContext.vW`、`SCContext.vwInput`、`SCContext.awInput`、`SCContext.micInput`、`SCContext.lastPTS`、`SCContext.timeOffset`、`SCContext.isResume` 的新引用或新依赖。
- 不允许新增 `RecordingWriter` 以外的 `AVAssetWriterInput.append` 调用。
- 不允许新增录制停止路径中的 `DispatchGroup.wait()`。
- 不允许新增 `CMTime(value: 1, timescale: 0)`。
- 不允许新增 `asSampleBuffer!`。
- 每个任务完成后必须运行该任务指定验证命令。

### 任务 1 至任务 9 的中间态允许项

- 任务 1 至任务 9 只建立、补齐和验证新的 `RecordingCore`，尚未切断 app 内旧录制路径；这些任务可以与仓库中已有的旧 `SCContext` writer/timing 状态共存。
- 中间态允许项只适用于任务开始前已经存在的旧代码。任何任务都不得扩大旧路径、不得新增对旧状态的调用、不得让新核心依赖旧状态。
- 审查任务 1 至任务 9 时，应检查本任务 diff 是否新增旧路径使用，而不是要求全仓库已经清除历史旧状态。

### 任务 10 起的切换门禁

- 任务 10 必须切断 app 旧 writer 状态并接入 `RecordingSession`；从任务 10 完成后开始，全仓库不得再存在 `SCContext.vW`、`SCContext.vwInput`、`SCContext.awInput`、`SCContext.micInput`、`SCContext.lastPTS`、`SCContext.timeOffset`、`SCContext.isResume`。
- 任务 10 完成后，录制路径中的所有 `AVAssetWriterInput.append`、`markAsFinished`、`finishWriting`、`endSession` 都只能由 `RecordingWriter` 管理。
- 任务 11 和任务 12 的 `rg` 验证必须对最终不变量清零；如果仍有旧状态或旧 writer 直写路径，任务不得通过。

### 最终不变量

- 不存在 `SCContext.vW`、`SCContext.vwInput`、`SCContext.awInput`、`SCContext.micInput`、`SCContext.lastPTS`、`SCContext.timeOffset`、`SCContext.isResume`。
- 不存在 `CMTime(value: 1, timescale: 0)`。
- 不存在 `asSampleBuffer!`。
- 不存在录制路径直接调用 `AVAssetWriterInput.append`，除 `RecordingWriter` 内部。
- 不存在录制停止路径使用 `DispatchGroup.wait()` 阻塞 UI。

## 任务 1：建立 RecordingCore 测试入口

**文件：**
- 创建：`Package.swift`
- 创建：`QuickRecorder/RecordingCore/RecordingTimeline.swift`
- 创建：`Tests/RecordingCoreTests/RecordingTimelineTests.swift`

- [ ] **步骤 1：创建 SwiftPM package**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickRecorderRecordingCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "RecordingCore", targets: ["RecordingCore"])
    ],
    targets: [
        .target(name: "RecordingCore", path: "QuickRecorder/RecordingCore"),
        .testTarget(name: "RecordingCoreTests", dependencies: ["RecordingCore"], path: "Tests/RecordingCoreTests")
    ]
)
```

- [ ] **步骤 2：创建最小核心文件**

```swift
import CoreMedia
import Foundation

public struct RecordingTimeline {
    public init() {}
}
```

- [ ] **步骤 3：创建编译测试**

```swift
import XCTest
@testable import RecordingCore

final class RecordingTimelineTests: XCTestCase {
    func testPackageCompiles() {
        _ = RecordingTimeline()
    }
}
```

- [ ] **步骤 4：验证**

运行：`rtk swift test`

预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add Package.swift QuickRecorder/RecordingCore/RecordingTimeline.swift Tests/RecordingCoreTests/RecordingTimelineTests.swift
git commit -m "test: add recording core harness"
```

## 任务 2：实现完整 RecordingTimeline

**文件：**
- 修改：`QuickRecorder/RecordingCore/RecordingTimeline.swift`
- 修改：`Tests/RecordingCoreTests/RecordingTimelineTests.swift`

- [ ] **步骤 1：写失败测试**

```swift
import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingTimelineTests: XCTestCase {
    func testAnyFirstSampleStartsTimelineAtZero() {
        var timeline = RecordingTimeline()
        let mapped = timeline.presentationTime(for: CMTime(seconds: 20, preferredTimescale: 600))
        XCTAssertEqual(mapped, .zero)
        XCTAssertEqual(timeline.sourceStartTime?.seconds, 20, accuracy: 0.001)
    }

    func testPauseDurationIsRemovedFromAllTracks() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.pause(at: CMTime(seconds: 13, preferredTimescale: 600))
        timeline.resume(at: CMTime(seconds: 18, preferredTimescale: 600))
        let video = timeline.presentationTime(for: CMTime(seconds: 20, preferredTimescale: 600))
        let audio = timeline.presentationTime(for: CMTime(seconds: 21, preferredTimescale: 600))
        XCTAssertEqual(video.seconds, 5, accuracy: 0.001)
        XCTAssertEqual(audio.seconds, 6, accuracy: 0.001)
    }

    func testFinalDurationUsesStopSourceTime() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 100, preferredTimescale: 600))
        _ = timeline.presentationTime(for: CMTime(seconds: 120, preferredTimescale: 600))
        let final = timeline.finalDuration(at: CMTime(seconds: 180, preferredTimescale: 600))
        XCTAssertEqual(final.seconds, 80, accuracy: 0.001)
    }

    func testPresentationTimeIsMonotonic() {
        var timeline = RecordingTimeline()
        let first = timeline.presentationTime(for: CMTime(seconds: 5, preferredTimescale: 600))
        let second = timeline.presentationTime(for: CMTime(seconds: 4, preferredTimescale: 600))
        XCTAssertEqual(first, .zero)
        XCTAssertEqual(second, .zero)
    }
}
```

- [ ] **步骤 2：验证失败**

运行：`rtk swift test --filter RecordingTimelineTests`

预期：FAIL，缺少 `presentationTime`。

- [ ] **步骤 3：实现 timeline**

```swift
import CoreMedia
import Foundation

public struct RecordingTimeline {
    public private(set) var sourceStartTime: CMTime?
    public private(set) var accumulatedPauseDuration: CMTime = .zero
    public private(set) var lastPresentationTime: CMTime = .zero
    private var pauseStartSourceTime: CMTime?

    public init() {}

    public var isPaused: Bool { pauseStartSourceTime != nil }

    public mutating func presentationTime(for sourceTime: CMTime) -> CMTime {
        if sourceStartTime == nil {
            sourceStartTime = sourceTime
        }
        guard let start = sourceStartTime else { return .zero }
        let relative = CMTimeSubtract(sourceTime, start)
        let mapped = CMTimeMaximum(.zero, CMTimeSubtract(relative, accumulatedPauseDuration))
        lastPresentationTime = CMTimeMaximum(lastPresentationTime, mapped)
        return lastPresentationTime
    }

    public mutating func pause(at sourceTime: CMTime) {
        guard pauseStartSourceTime == nil else { return }
        pauseStartSourceTime = sourceTime
    }

    public mutating func resume(at sourceTime: CMTime) {
        guard let pauseStart = pauseStartSourceTime else { return }
        accumulatedPauseDuration = CMTimeAdd(
            accumulatedPauseDuration,
            CMTimeMaximum(.zero, CMTimeSubtract(sourceTime, pauseStart))
        )
        pauseStartSourceTime = nil
    }

    public mutating func finalDuration(at sourceTime: CMTime) -> CMTime {
        presentationTime(for: sourceTime)
    }
}
```

- [ ] **步骤 4：验证通过**

运行：`rtk swift test --filter RecordingTimelineTests`

预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add QuickRecorder/RecordingCore/RecordingTimeline.swift Tests/RecordingCoreTests/RecordingTimelineTests.swift
git commit -m "feat: add recording timeline"
```

## 任务 3：实现 SampleRetiming、AudioSampleBufferFactory、AECAudioClock

**文件：**
- 创建：`QuickRecorder/RecordingCore/SampleRetiming.swift`
- 创建：`QuickRecorder/RecordingCore/AudioSampleBufferFactory.swift`
- 创建：`QuickRecorder/RecordingCore/AECAudioClock.swift`
- 创建：`Tests/RecordingCoreTests/SampleRetimingTests.swift`
- 创建：`Tests/RecordingCoreTests/AudioSampleBufferFactoryTests.swift`
- 创建：`Tests/RecordingCoreTests/AECAudioClockTests.swift`

- [ ] **步骤 1：写测试**

`AudioSampleBufferFactoryTests.swift`：

```swift
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
```

`AECAudioClockTests.swift`：

```swift
import CoreMedia
import XCTest
@testable import RecordingCore

final class AECAudioClockTests: XCTestCase {
    func testClockAdvancesByFrameLengthOverSampleRate() {
        var clock = AECAudioClock(sampleRate: 48_000, startTime: .zero)
        let first = clock.nextSourceTime(frameLength: 480)
        let second = clock.nextSourceTime(frameLength: 480)
        XCTAssertEqual(first.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(second.seconds, 0.01, accuracy: 0.001)
    }
}
```

`SampleRetimingTests.swift`：

```swift
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
```

- [ ] **步骤 2：验证失败**

运行：`rtk swift test --filter AudioSampleBufferFactoryTests && rtk swift test --filter AECAudioClockTests && rtk swift test --filter SampleRetimingTests`

预期：FAIL，缺少类型。

- [ ] **步骤 3：实现三个工具**

`AECAudioClock.swift`：

```swift
import CoreMedia
import Foundation

public struct AECAudioClock {
    private let sampleRate: Double
    private var nextTime: CMTime

    public init(sampleRate: Double, startTime: CMTime) {
        self.sampleRate = sampleRate
        self.nextTime = startTime
    }

    public mutating func nextSourceTime(frameLength: AVAudioFrameCount) -> CMTime {
        let current = nextTime
        let step = CMTime(seconds: Double(frameLength) / sampleRate, preferredTimescale: 1_000_000_000)
        nextTime = CMTimeAdd(nextTime, step)
        return current
    }
}
```

`SampleRetiming.swift` and `AudioSampleBufferFactory.swift` must implement the tested APIs exactly:

```swift
public enum RecordingSampleRetimer {
    public static func copy(_ sampleBuffer: CMSampleBuffer?, presentationTime: CMTime) -> CMSampleBuffer?
}

public enum AudioSampleBufferFactory {
    public static func makeSampleBuffer(from buffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer?
}
```

Implementation requirements:

- Preserve format description.
- Preserve sample count.
- Return nil on CoreMedia errors.
- Never force unwrap.

- [ ] **步骤 4：验证通过**

运行：`rtk swift test`

预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add QuickRecorder/RecordingCore Tests/RecordingCoreTests
git commit -m "feat: add recording sample timing utilities"
```

## 任务 4：实现完整 RecordingWriter

**文件：**
- 创建：`QuickRecorder/RecordingCore/RecordingWriter.swift`
- 创建：`Tests/RecordingCoreTests/RecordingWriterStateTests.swift`
- 创建：`Tests/RecordingCoreTests/RecordingWriterOrderTests.swift`

- [ ] **步骤 1：写状态机测试**

```swift
import XCTest
@testable import RecordingCore

final class RecordingWriterStateTests: XCTestCase {
    func testStateMachineRejectsSamplesAfterStopping() {
        var state = RecordingWriterStateMachine()
        XCTAssertTrue(state.acceptsSamples)
        state.beginStopping()
        XCTAssertFalse(state.acceptsSamples)
        state.finish()
        XCTAssertFalse(state.acceptsSamples)
    }
}
```

- [ ] **步骤 2：写 finish 顺序测试**

`RecordingWriterOrderTests.swift` must use a test adapter instead of real files:

```swift
import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingWriterOrderTests: XCTestCase {
    func testFinishOrderIsTailThenEndThenMarkThenFinish() {
        let adapter = RecordingWriterTestAdapter()
        let writer = RecordingWriter(adapter: adapter)

        writer.finish(finalDuration: CMTime(seconds: 12, preferredTimescale: 600), tailVideoSample: nil) { _ in }
        adapter.drainQueue()

        XCTAssertEqual(adapter.events, [
            "endSession:12.0",
            "markVideoFinished",
            "markSystemAudioFinished",
            "markMicFinished",
            "finishWriting"
        ])
    }
}
```

This requires `RecordingWriter` to depend on an internal adapter protocol. Production uses `AVAssetWriterAdapter`; tests use `RecordingWriterTestAdapter`.

- [ ] **步骤 3：验证失败**

运行：`rtk swift test --filter RecordingWriterStateTests`

运行：`rtk swift test --filter RecordingWriterOrderTests`

预期：FAIL，缺少 `RecordingWriterStateMachine`、`RecordingWriterTestAdapter` 或 adapter initializer。

- [ ] **步骤 4：实现 writer**

`RecordingWriter` must:

- Build `AVAssetWriter` and all inputs from a configuration object via `AVAssetWriterAdapter`.
- Expose an internal `init(adapter:)` for tests.
- Call `startWriting()` inside `start()`.
- Start session exactly once at `.zero` before first append.
- Append all media on its private writer queue.
- Track dropped video/system audio/mic counts.
- Finish with `tailVideoSample -> endSession -> markFinished -> finishWriting`.
- Return completion asynchronously.
- Never expose raw writer/input.

Required public shape:

```swift
public final class RecordingWriter {
    public init(configuration: RecordingWriterConfiguration) throws
    init(adapter: RecordingWriterAdapting)
    public func start() throws
    public func appendVideo(_ sampleBuffer: CMSampleBuffer)
    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer)
    public func appendMic(_ sampleBuffer: CMSampleBuffer)
    public func finish(finalDuration: CMTime, tailVideoSample: CMSampleBuffer?, completion: @escaping (Result<RecordingWriterSummary, Error>) -> Void)
}
```

Required internal adapter shape:

```swift
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
}
```

- [ ] **步骤 5：验证**

运行：`rtk swift test`

预期：PASS。

- [ ] **步骤 6：Commit**

```bash
git add QuickRecorder/RecordingCore/RecordingWriter.swift Tests/RecordingCoreTests/RecordingWriterStateTests.swift Tests/RecordingCoreTests/RecordingWriterOrderTests.swift
git commit -m "feat: add recording writer"
```

## 任务 5：实现完整 RecordingFinalizer

**文件：**
- 创建：`QuickRecorder/RecordingCore/RecordingFinalizer.swift`
- 创建：`Tests/RecordingCoreTests/RecordingFinalizerTests.swift`

- [ ] **步骤 1：写 finalizer 测试**

```swift
import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingFinalizerTests: XCTestCase {
    func testVideoRemuxUsesFinalDurationNotAssetDuration() {
        let finalizer = RecordingFinalizer()
        let range = finalizer.outputTimeRange(finalDuration: CMTime(seconds: 42, preferredTimescale: 600))
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration.seconds, 42, accuracy: 0.001)
    }

    func testFailedRemuxPreservesIntermediateFiles() {
        let policy = RecordingFinalizerFilePolicy()
        XCTAssertFalse(policy.shouldDeleteIntermediateFiles(remuxSucceeded: false))
        XCTAssertTrue(policy.shouldDeleteIntermediateFiles(remuxSucceeded: true))
    }

    func testVideoWithoutRemuxReturnsCompletedOutput() {
        let finalizer = RecordingFinalizer()
        let outputURL = URL(fileURLWithPath: "/tmp/quick-recorder-test.mov")
        let request = RecordingFinalizerRequest(
            sourceURL: outputURL,
            outputURL: outputURL,
            finalDuration: CMTime(seconds: 5, preferredTimescale: 600),
            mode: .videoWithoutRemux
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
}
```

- [ ] **步骤 2：验证失败**

运行：`rtk swift test --filter RecordingFinalizerTests`

预期：FAIL，缺少 `RecordingFinalizer`、`RecordingFinalizerRequest`、`RecordingOutput` 或 `RecordingFinalizerFilePolicy`。

- [ ] **步骤 3：实现 finalizer 接口**

Required public shape:

```swift
public protocol RecordingFinalizing {
    func finalize(_ request: RecordingFinalizerRequest, completion: @escaping (Result<RecordingOutput, Error>) -> Void)
}

public struct RecordingFinalizerRequest {
    public let sourceURL: URL
    public let outputURL: URL
    public let finalDuration: CMTime
    public let mode: RecordingFinalizerMode
}

public enum RecordingFinalizerMode {
    case videoWithoutRemux
    case videoWithRemux
    case pureAudioPackage
}

public struct RecordingOutput {
    public let url: URL
    public let duration: CMTime
}

public struct RecordingFinalizer: RecordingFinalizing {
    public init()
    public func finalize(_ request: RecordingFinalizerRequest, completion: @escaping (Result<RecordingOutput, Error>) -> Void)
    public func outputTimeRange(finalDuration: CMTime) -> CMTimeRange
}

public struct RecordingFinalizerFilePolicy {
    public init()
    public func shouldDeleteIntermediateFiles(remuxSucceeded: Bool) -> Bool
}
```

Implementation requirements:

- For video without remux: return completed output after writer finish.
- For video remux: use `finalDuration`, never `asset.duration` as the controlling duration.
- For pure audio qma: expose a mode and request shape that can wait for system audio close and mic writer finish when app integration supplies those inputs.
- Delete intermediate files only after final export success.
- Preserve source/intermediate files on failure.
- Return user-displayable error categories.

- [ ] **步骤 4：验证**

运行：`rtk swift test`

预期：PASS.

- [ ] **步骤 5：Commit**

```bash
git add QuickRecorder/RecordingCore/RecordingFinalizer.swift Tests/RecordingCoreTests/RecordingFinalizerTests.swift
git commit -m "feat: add recording finalizer"
```

## 任务 6：实现完整 RecordingSession

**文件：**
- 创建：`QuickRecorder/RecordingCore/RecordingSession.swift`
- 创建：`Tests/RecordingCoreTests/RecordingSessionTests.swift`

- [ ] **步骤 1：写 session 行为测试**

```swift
import AVFoundation
import CoreMedia
import XCTest
@testable import RecordingCore

final class RecordingSessionTests: XCTestCase {
    func testStopDurationIncludesTimeAfterLastFrame() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 10, preferredTimescale: 600))
        _ = timeline.presentationTime(for: CMTime(seconds: 20, preferredTimescale: 600))
        XCTAssertEqual(timeline.finalDuration(at: CMTime(seconds: 70, preferredTimescale: 600)).seconds, 60, accuracy: 0.001)
    }

    func testPauseResumeRemovesDuration() {
        var timeline = RecordingTimeline()
        _ = timeline.presentationTime(for: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.pause(at: CMTime(seconds: 20, preferredTimescale: 600))
        timeline.resume(at: CMTime(seconds: 35, preferredTimescale: 600))
        XCTAssertEqual(timeline.finalDuration(at: CMTime(seconds: 50, preferredTimescale: 600)).seconds, 25, accuracy: 0.001)
    }

    func testStopCallsFinalizerAfterWriterFinish() throws {
        let finalizer = RecordingFinalizerSpy()
        let writer = RecordingWriter(adapter: RecordingWriterTestAdapter())
        let session = RecordingSession(configuration: .test(), finalizer: finalizer, writer: writer)
        try session.start()
        let completion = expectation(description: "stopped")

        session.stop(at: CMTime(seconds: 3, preferredTimescale: 600)) { result in
            guard case .success = result else {
                return XCTFail("Expected successful stop")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(finalizer.requests.count, 1)
        XCTAssertEqual(finalizer.requests[0].finalDuration.seconds, 3, accuracy: 0.001)
    }

    func testAppendAfterStopIsRejected() throws {
        let finalizer = RecordingFinalizerSpy()
        let writer = RecordingWriter(adapter: RecordingWriterTestAdapter())
        let session = RecordingSession(configuration: .test(), finalizer: finalizer, writer: writer)
        try session.start()
        let completion = expectation(description: "stopped")
        session.stop(at: CMTime(seconds: 1, preferredTimescale: 600)) { _ in completion.fulfill() }
        wait(for: [completion], timeout: 1)

        session.appendSystemAudio(try makeAudioSample(at: CMTime(seconds: 2, preferredTimescale: 48_000)))

        XCTAssertEqual(session.rejectedSampleCount, 1)
    }

    private func makeAudioSample(at presentationTime: CMTime) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        return try XCTUnwrap(AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: presentationTime))
    }
}

private final class RecordingFinalizerSpy: RecordingFinalizing {
    private(set) var requests: [RecordingFinalizerRequest] = []

    func finalize(_ request: RecordingFinalizerRequest, completion: @escaping (Result<RecordingOutput, Error>) -> Void) {
        requests.append(request)
        completion(.success(RecordingOutput(url: request.outputURL, duration: request.finalDuration)))
    }
}

private extension RecordingSessionConfiguration {
    static func test() -> RecordingSessionConfiguration {
        RecordingSessionConfiguration(
            writerConfiguration: RecordingWriterConfiguration(
                outputURL: URL(fileURLWithPath: "/tmp/session.mov"),
                fileType: .mov,
                videoOutputSettings: nil,
                systemAudioOutputSettings: nil,
                micOutputSettings: nil
            ),
            finalizerMode: .videoWithoutRemux
        )
    }
}
```

- [ ] **步骤 2：验证失败**

运行：`rtk swift test --filter RecordingSessionTests`

预期：FAIL，缺少 `RecordingSession`、`RecordingSessionConfiguration`、测试 spy 或 session API。

- [ ] **步骤 3：实现 session**

`RecordingSession` must:

- Own `sessionQueue`.
- Own `RecordingTimeline`.
- Own `RecordingWriter`.
- Own last complete video sample and last video presentation time.
- Own `AECAudioClock`.
- Expose async `start`, `appendVideo`, `appendSystemAudio`, `appendDefaultMicBuffer`, `appendAECMicBuffer`, `appendExternalMic`, `pause`, `resume`, `stop`.
- Ensure timeline and last-frame mutations only happen on `sessionQueue`.
- Reject all sample appends after stopping.
- Call finalizer after writer finish.
- Expose `rejectedSampleCount` for tests and diagnostics.
- Provide an internal `init(configuration:finalizer:writer:)` for unit tests so tests can use `RecordingWriter(adapter: RecordingWriterTestAdapter())` instead of writing real files.

Required public shape:

```swift
public final class RecordingSession {
    public init(configuration: RecordingSessionConfiguration, finalizer: RecordingFinalizing)
    public func start() throws
    public func appendVideo(_ sampleBuffer: CMSampleBuffer)
    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer)
    public func appendDefaultMicBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime)
    public func appendAECMicBuffer(_ buffer: AVAudioPCMBuffer)
    public func appendExternalMic(_ sampleBuffer: CMSampleBuffer)
    public func pause(at sourceTime: CMTime)
    public func resume(at sourceTime: CMTime)
    public func stop(at sourceTime: CMTime, completion: @escaping (Result<RecordingOutput, Error>) -> Void)
}
```

Required configuration shape:

```swift
public struct RecordingSessionConfiguration {
    public let writerConfiguration: RecordingWriterConfiguration
    public let finalizerMode: RecordingFinalizerMode
}
```

- [ ] **步骤 4：验证**

运行：`rtk swift test`

预期：PASS.

- [ ] **步骤 5：Commit**

```bash
git add QuickRecorder/RecordingCore/RecordingSession.swift Tests/RecordingCoreTests/RecordingSessionTests.swift
git commit -m "feat: add recording session"
```

## 任务 7：把 RecordingCore 加入 Xcode app target

**文件：**
- 修改：`QuickRecorder.xcodeproj/project.pbxproj`

- [ ] **步骤 1：添加所有 RecordingCore Swift 文件到 app target**

Add these files to the QuickRecorder group and Sources build phase:

```text
RecordingTimeline.swift
SampleRetiming.swift
AudioSampleBufferFactory.swift
AECAudioClock.swift
RecordingWriter.swift
RecordingSession.swift
RecordingFinalizer.swift
```

- [ ] **步骤 2：验证**

运行：

```bash
rtk swift test
rtk xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

预期：PASS and BUILD SUCCEEDED.

- [ ] **步骤 3：Commit**

```bash
git add QuickRecorder.xcodeproj/project.pbxproj
git commit -m "build: include recording core"
```

## 任务 8：补齐 Session 时钟与显示状态

**文件：**
- 修改：`QuickRecorder/RecordingCore/RecordingTimeline.swift`
- 修改：`QuickRecorder/RecordingCore/AECAudioClock.swift`
- 修改：`QuickRecorder/RecordingCore/RecordingSession.swift`
- 修改：`Tests/RecordingCoreTests/RecordingTimelineTests.swift`
- 修改：`Tests/RecordingCoreTests/AECAudioClockTests.swift`
- 修改：`Tests/RecordingCoreTests/RecordingSessionTests.swift`

- [ ] **步骤 1：写时钟和显示状态测试**

新增测试必须覆盖：

- 默认麦克风使用 `AVAudioTime.hostTime` 转换为统一 source PTS；不得只使用 `sampleTime / sampleRate`。
- AEC 使用连续帧计数器，但第一个 AEC source time 必须锚定到 session source clock，而不是每个 buffer 的转换时刻 host clock。
- `pause()` / `resume()` / `stop()` 可以由 session 内部时钟给出 source time；调用方不需要在 app 层维护旧 `timeOffset`。
- `elapsedDisplayTime` 在录制时递增，暂停期间保持不变，恢复后不包含暂停时长。
- 首个 video/audio/default mic/AEC/external mic 任一轨道先到都可以建立 timeline，PTS 单调。

```swift
func testDisplayTimeDoesNotAdvanceWhilePaused()
func testDefaultMicUsesHostTimeSourceClock()
func testAECClockUsesContinuousFramesFromSessionClock()
func testStopWithoutExplicitSourceTimeUsesSessionClock()
```

- [ ] **步骤 2：验证失败**

运行：

```bash
rtk swift test --filter RecordingSessionTests
rtk swift test --filter AECAudioClockTests
```

预期：FAIL，缺少 session clock/display API 或 host-time conversion 行为。

- [ ] **步骤 3：实现 session clock**

实现要求：

- `RecordingSession` 持有统一 source clock，默认使用 host clock；测试可注入 deterministic clock。
- 新增线程安全 `public var elapsedDisplayTime: TimeInterval`。
- 新增无参数 `pause()`、`resume()`、`stop(completion:)`，内部从 source clock 取时；保留带 sourceTime 的内部/test API。
- 默认麦克风从 `AVAudioTime.hostTime` 转换到 source clock；若 hostTime 不可用则拒绝该 buffer 并计入 rejected。
- AEC 只用 `AECAudioClock` 连续帧推进，初始时间来自 session source clock 或已建立的 timeline source start。
- 不使用转换时刻 host clock 给每个 AEC buffer 打 PTS。

```swift
public protocol RecordingSourceClock {
    func currentSourceTime() -> CMTime
    func sourceTime(forHostTime hostTime: UInt64) -> CMTime?
}
```

- [ ] **步骤 4：验证**

运行：

```bash
rtk swift test
rtk xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

预期：PASS and BUILD SUCCEEDED。

- [ ] **步骤 5：Commit**

```bash
git add QuickRecorder/RecordingCore/RecordingTimeline.swift QuickRecorder/RecordingCore/AECAudioClock.swift QuickRecorder/RecordingCore/RecordingSession.swift Tests/RecordingCoreTests/RecordingTimelineTests.swift Tests/RecordingCoreTests/AECAudioClockTests.swift Tests/RecordingCoreTests/RecordingSessionTests.swift
git commit -m "feat: add recording session clock"
```

## 任务 9：补齐输出模式与 Finalizer 后处理

**文件：**
- 修改：`QuickRecorder/RecordingCore/RecordingWriter.swift`
- 修改：`QuickRecorder/RecordingCore/RecordingFinalizer.swift`
- 修改：`QuickRecorder/RecordingCore/RecordingSession.swift`
- 修改：`Tests/RecordingCoreTests/RecordingWriterStateTests.swift`
- 修改：`Tests/RecordingCoreTests/RecordingFinalizerTests.swift`
- 修改：`Tests/RecordingCoreTests/RecordingSessionTests.swift`

- [ ] **步骤 1：写输出模式测试**

新增测试必须覆盖：

- `RecordingSessionConfiguration` 能表达视频直出、视频双音轨 remux、纯系统音频单轨、qma package。
- `RecordingFinalizer` 的 `videoWithRemux` 不再返回 integration-required 错误，并且控制 duration 使用 `finalDuration`。
- `RecordingFinalizer` 的 `pureAudioPackage` 不再返回 integration-required 错误；qma request 必须显式包含 package URL、sys audio URL、mic audio URL 和 info。
- remux/export 失败时保留源文件和中间文件；成功后才允许删除中间文件。
- `RecordingWriter`/`RecordingSession` finish 后才触发 finalizer，finalizer 不读取未完成 writer 输出。

- [ ] **步骤 2：验证失败**

运行：

```bash
rtk swift test --filter RecordingFinalizerTests
rtk swift test --filter RecordingSessionTests
```

预期：FAIL，`videoWithRemux` / `pureAudioPackage` 仍返回明确错误或缺少 request fields。

- [ ] **步骤 3：实现输出模式**

实现要求：

- `RecordingSessionConfiguration` 必须显式描述输出：
  - video direct output URL。
  - video remux intermediate URL and final URL。
  - pure audio single output URL。
  - qma package URL、`sys.*` URL、`mic.*` URL、format/encoder/exportMP3/sysVol/micVol。
- `RecordingFinalizerRequest` 必须携带 finalDuration 和上述输出信息。
- `RecordingFinalizer.outputTimeRange(finalDuration:)` 是 remux 唯一控制 duration；不得使用 `asset.duration` 作为最终裁剪依据。
- qma 生成只在 sys audio 和 mic writer 都完成后执行；失败时保留 package/intermediate files。
- 删除所有 `remuxRequiresAppIntegration` / `audioPackageRequiresAppIntegration` 等占位错误。

- [ ] **步骤 4：验证**

运行：

```bash
rtk swift test
rtk xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
rtk rg -n "remuxRequiresAppIntegration|audioPackageRequiresAppIntegration|asset\\.duration\\)" QuickRecorder/RecordingCore QuickRecorder/SCContext.swift
```

预期：

- Tests pass.
- Build succeeds.
- rg 无 integration-required 占位错误。
- `asset.duration` 不出现在新的 finalizer duration 控制逻辑中。

- [ ] **步骤 5：Commit**

```bash
git add QuickRecorder/RecordingCore/RecordingWriter.swift QuickRecorder/RecordingCore/RecordingFinalizer.swift QuickRecorder/RecordingCore/RecordingSession.swift Tests/RecordingCoreTests/RecordingWriterStateTests.swift Tests/RecordingCoreTests/RecordingFinalizerTests.swift Tests/RecordingCoreTests/RecordingSessionTests.swift
git commit -m "feat: add recording output modes"
```

## 任务 10：切断旧 writer 状态并接入 Session

**文件：**
- 修改：`QuickRecorder/SCContext.swift`
- 修改：`QuickRecorder/RecordEngine.swift`
- 修改：`QuickRecorder/ViewModel/StatusBar.swift`

- [ ] **步骤 1：删除旧媒体状态**

从 `SCContext` 删除或停止使用：

```swift
frameCache
isResume
isSkipFrame
lastPTS
timeOffset
audioFile2
vW
vwInput
awInput
micInput
```

新增：

```swift
static var recordingSession: RecordingSession?
```

- [ ] **步骤 2：修复 minimumFrameInterval**

使用：

```swift
conf.minimumFrameInterval = audioOnly ? .zero : CMTime(value: 1, timescale: CMTimeScale(frameRate))
```

- [ ] **步骤 3：创建 session**

在开始采集前构造完整 `RecordingSessionConfiguration` 并调用：

```swift
SCContext.recordingSession = RecordingSession(configuration: configuration, finalizer: RecordingFinalizer())
try SCContext.recordingSession?.start()
```

配置必须覆盖视频、系统音频、默认麦克风、AEC、外接麦克风、纯音频、qma package 和 remux。

- [ ] **步骤 4：转发 sample**

所有回调必须转发：

```swift
SCContext.recordingSession?.appendVideo(sampleBuffer)
SCContext.recordingSession?.appendSystemAudio(sampleBuffer)
SCContext.recordingSession?.appendDefaultMicBuffer(buffer, time: time)
SCContext.recordingSession?.appendAECMicBuffer(pcmBuffer)
SCContext.recordingSession?.appendExternalMic(sampleBuffer)
```

`RecordEngine.swift`、`AudioRecorder.captureOutput` 和麦克风 tap 中不得直接访问 writer/input。

- [ ] **步骤 5：pause/stop 异步转发**

`SCContext.pauseRecording()` 只更新 UI pause state 并调用 session pause/resume。

`SCContext.stopRecording()` 先停止 ScreenCaptureKit 和麦克风采集，然后调用 session stop 并立即返回；completion 中统一预览、通知、trim、overlay/control panel 清理、sleep preventer 释放。不得使用 `DispatchGroup.wait()`。

- [ ] **步骤 6：状态栏使用 session display time**

`StatusBar.swift` 读取 `SCContext.recordingSession?.elapsedDisplayTime`；没有 session 时回退当前显示。

- [ ] **步骤 7：验证**

运行：

```bash
rtk swift test
rtk xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
rtk rg -n "SCContext\\.(vW|vwInput|awInput|micInput|lastPTS|timeOffset|isResume)|CMTime\\(value: 1, timescale: 0\\)|asSampleBuffer!|DispatchGroup\\(\\).*wait" QuickRecorder
rtk rg -n "AVAssetWriterInput\\.append|\\.markAsFinished\\(\\)|\\.finishWriting\\(|\\.endSession\\(" QuickRecorder -g "*.swift"
```

预期：

- Tests pass.
- Build succeeds.
- 第一条 rg 无输出。
- 第二条 rg 只允许命中 `QuickRecorder/RecordingCore/RecordingWriter.swift`。

- [ ] **步骤 8：Commit**

```bash
git add QuickRecorder/SCContext.swift QuickRecorder/RecordEngine.swift QuickRecorder/ViewModel/StatusBar.swift
git commit -m "refactor: route recording through single session"
```

## 任务 11：问题记录和后处理收口

**文件：**
- 修改：`QuickRecorder/SCContext.swift`
- 修改：`QuickRecorder/RecordingCore/RecordingFinalizer.swift`
- 修改：`docs/recording-issues.md`

- [ ] **步骤 1：确认旧 remux 调用已删除**

All remux calls must go through `RecordingFinalizer` and pass `finalDuration`.

- [ ] **步骤 2：确认纯音频 qma 流程已由 finalizer 管理**

Pure audio qma export must be triggered only by finalizer completion. Remove any remaining direct `vW.finishWriting {}` branch.

- [ ] **步骤 3：更新问题记录**

For each QR-REC item, set status to:

```markdown
- 状态：已实现，等待最终人工验证
```

After manual verification, update verified items to:

```markdown
- 状态：已修复并通过验证
```

- [ ] **步骤 4：验证**

运行：

```bash
rtk swift test
rtk xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
rtk rg -n "vW\\.finishWriting|asset\\.duration\\)|SCContext\\.(vW|vwInput|awInput|micInput|lastPTS|timeOffset|isResume)|asSampleBuffer!|CMTime\\(value: 1, timescale: 0\\)|remuxRequiresAppIntegration|audioPackageRequiresAppIntegration" QuickRecorder
```

预期：测试和构建成功，rg 无输出。

- [ ] **步骤 5：Commit**

```bash
git add QuickRecorder/SCContext.swift QuickRecorder/RecordingCore/RecordingFinalizer.swift docs/recording-issues.md
git commit -m "fix: finalize recordings through recording core"
```

## 任务 12：最终人工回归

**文件：**
- 修改：`docs/recording-issues.md`

- [ ] **步骤 1：运行自动验证**

```bash
rtk swift test
rtk xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
rtk rg -n "SCContext\\.(vW|vwInput|awInput|micInput|lastPTS|timeOffset|isResume)|asSampleBuffer!|CMTime\\(value: 1, timescale: 0\\)|DispatchGroup\\(\\).*wait|vW\\.finishWriting" QuickRecorder
```

预期：PASS、BUILD SUCCEEDED、rg 无输出。

- [ ] **步骤 2：人工验证清单**

```markdown
- [ ] 静止画面录制 2 分钟，输出 duration 接近 2 分钟。
- [ ] 录制 30 秒，中途暂停 10 秒，输出 duration 接近 20 秒。
- [ ] 屏幕 + 系统音频。
- [ ] 屏幕 + 默认麦克风。
- [ ] 屏幕 + AEC 麦克风。
- [ ] 屏幕 + 外接麦克风。
- [ ] 屏幕 + 系统音频 + 麦克风 + remux。
- [ ] 纯系统音频 + 麦克风。
- [ ] 60 FPS 默认设置启动录制，minimumFrameInterval 合法。
- [ ] 停止录制后立即预览，文件可播放。
```

- [ ] **步骤 3：更新问题记录为验证结果**

Update `docs/recording-issues.md` statuses based on the checklist.

- [ ] **步骤 4：Commit**

```bash
git add docs/recording-issues.md
git commit -m "docs: record recording stability verification"
```
