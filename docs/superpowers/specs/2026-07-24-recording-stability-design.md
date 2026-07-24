# QuickRecorder 录制稳定性系统修复设计

日期：2026-07-24

## 背景

QuickRecorder 当前录制链路把 ScreenCaptureKit、AVAudioEngine、AVCaptureAudioDataOutput、AVAssetWriter 和后处理逻辑分散在 `RecordEngine.swift` 与 `SCContext.swift` 中。已确认的问题包括：静止画面录制时长被截断、60 FPS 配置异常、暂停恢复音画不同步、麦克风 PTS 漂移、停止录制竞态、纯音频麦克风 writer 未等待完成、remux 继承错误 duration。

本设计要求做完整系统修复：录制媒体时间、写入、停止、后处理由单一录制内核负责。不得保留旧 writer 直写路径，不设置过渡兼容层，不把关键问题留到后续阶段。

实现允许先建立可测试的新 `RecordingCore`，再在明确的切换任务中接入 app 录制路径。切换前的中间提交可以与仓库已有旧录制代码共存，但不得新增旧 writer/timing 状态引用，不得让新核心依赖旧状态；切换任务完成后，旧 writer 直写路径和旧 timing 状态必须从录制路径中彻底移除。

## 目标

- 静止画面长时间录制时，输出视频 duration 接近真实录制时长。
- 视频、系统音频、默认麦克风、AEC 麦克风、外接麦克风全部使用同一套录制时间轴。
- 暂停和恢复不造成音画错位，也不把暂停时长计入媒体 duration。
- `AVAssetWriter` 的 `startWriting`、`startSession`、append、补尾帧、`endSession`、`markAsFinished`、`finishWriting` 全部由单一 writer 内核管理。
- 停止录制是异步状态机，不阻塞主线程，不使用 `DispatchGroup.wait()` 等同步等待 UI 的方式。
- remux、纯音频导出、预览、通知只读取已完成写入的文件。
- 失败时尽量保留用户素材，并给出可理解错误提示。

## 非目标

- 不重写屏幕、窗口、区域、应用选择 UI。
- 不改变用户可见的录制格式、编码器、保存目录、快捷键语义。
- 不引入固定帧率全帧生成管线；当前只在停止时补尾帧以保证 duration。

## 架构总览

新增 `RecordingCore`，由以下组件组成：

- `RecordingSession`：唯一录制会话入口，拥有串行 `sessionQueue`，管理状态、timeline、最后视频帧、暂停恢复、停止。
- `RecordingTimeline`：唯一媒体时间轴，负责源时间到录制时间的映射、暂停区间、final duration。
- `RecordingWriter`：唯一 writer 所有者，完整管理 `AVAssetWriter` 生命周期和所有 inputs。
- `RecordingFinalizer`：唯一后处理入口，负责 remux、纯音频 qma 导出、预览和通知的顺序。
- `SampleRetiming`：重写 `CMSampleBuffer` PTS/duration 的工具。
- `AudioSampleBufferFactory`：把 `AVAudioPCMBuffer` 转为带明确 PTS 的 `CMSampleBuffer`。

`SCContext` 只保留 UI 可见状态、当前 stream、当前选择对象和入口转发，不再保存 writer、writer input、`lastPTS`、`timeOffset` 等媒体写入状态。

## 实施门禁

### 切换前

- 新增代码必须进入 `RecordingCore`，并通过 SwiftPM/XCTest 独立验证。
- 不得新增 `SCContext.vW`、`SCContext.vwInput`、`SCContext.awInput`、`SCContext.micInput`、`SCContext.lastPTS`、`SCContext.timeOffset`、`SCContext.isResume` 的引用。
- 不得新增 `RecordingWriter` 以外的 writer append/finish 逻辑。
- 不得新增 `CMTime(value: 1, timescale: 0)`、`asSampleBuffer!` 或停止路径同步等待。

### 切换任务完成后

- `SCContext`、`RecordEngine`、麦克风回调和后处理入口只能转发给 `RecordingSession` / `RecordingFinalizer`。
- 旧 writer/input/timing 状态必须在全仓库 grep 清零。
- 录制路径中的 writer 生命周期必须只由 `RecordingWriter` 管理。
- 后处理必须只读取 writer 已完成的文件，并以 `finalDuration` 作为裁剪依据。

## 状态边界

### `SCContext` 保留职责

- `stream`、`streamType`、`screen/window/application/screenArea` 等 UI 和 ScreenCaptureKit 选择状态。
- `filePath` 和展示用 `startTime`，来源由 `RecordingSession` 写入。
- `recordingSession: RecordingSession?`，作为录制核心入口。
- `pauseRecording()`、`stopRecording()` 只转发给 session，并在 completion 中更新 UI。

### `SCContext` 移除职责

必须从 `SCContext` 删除或停止使用：

- `vW`
- `vwInput`
- `awInput`
- `micInput`
- `lastPTS`
- `timeOffset`
- `isResume`
- 任何直接 `AVAssetWriterInput.append`
- 任何直接 `markAsFinished` / `finishWriting`

## 时间轴设计

`RecordingTimeline` 使用源时间统一建模：

- ScreenCaptureKit video/audio 使用 sample PTS。
- 外接麦克风使用 `AVCaptureAudioDataOutput` sample PTS。
- 默认麦克风使用 `AVAudioTime.hostTime` 转换出的 source PTS。
- AEC 麦克风使用连续帧计数器生成 source PTS，起点为 writer session source start，步进为 `frameLength / sampleRate`。

Timeline 规则：

- 首个被接受的媒体 sample 定义 `sourceStartTime`。
- 所有轨道的输出 PTS = `sourceTime - sourceStartTime - accumulatedPauseDuration`。
- 暂停期间 sample 被拒绝写入。
- `pause(at:)` 记录暂停 source time。
- `resume(at:)` 累加暂停 duration。
- `finalDuration(at:)` 使用停止 source time 计算真实媒体结束时间。
- timeline 所有读写必须在 `RecordingSession.sessionQueue` 上执行。

音频先到不丢弃。首个有效 video/audio/mic sample 都可以启动 writer session。若视频晚于音频到达，视频从自己的 retimed PTS 开始；最终 duration 由 timeline 管理。

## Writer 设计

`RecordingWriter` 完整接管 writer 生命周期：

- 初始化 `AVAssetWriter` 和所有需要的 inputs。
- `startWriting()` 由 writer 内核调用。
- 首个可写 sample 到达时调用 `startSession(atSourceTime: .zero)`，因为所有 sample 在进入 writer 前已经 retime 到录制内时间。
- append video/system audio/mic 均在 writer queue 执行。
- input not ready 时不阻塞采集线程，记录 dropped count；最后视频帧仍由 session 保存。
- 停止时在同一 writer queue block 内按顺序执行：
  1. append tail video sample。
  2. `endSession(atSourceTime: finalDuration)`。
  3. mark all inputs finished。
  4. `finishWriting()`。

Writer 不暴露底层 `AVAssetWriter` 或 input 给 `SCContext`、`RecordEngine` 或音频回调。

## Session 数据流

### 开始录制

1. UI/选择器调用 `AppDelegate.prepRecord(...)`。
2. `record(filter:fastStart:)` 构造 `SCStreamConfiguration`。
3. 修正 `minimumFrameInterval`：
   - 录屏：`CMTime(value: 1, timescale: CMTimeScale(frameRate))`。
   - 纯音频：`.zero`。
   - 禁止 `CMTime(value: 1, timescale: 0)`。
4. 创建 `RecordingSession.Configuration`，包含输出 URL、文件类型、视频设置、系统音频设置、麦克风设置、是否 remux、是否纯音频。
5. `RecordingSession.start()` 创建 writer、inputs 并调用 `startWriting()`。
6. `SCStreamOutput` 和麦克风回调只把 sample/buffer 交给 session。

### 写入视频

1. `.screen` sample 经过有效性、attachments、`SCFrameStatus.complete` 校验。
2. sample 交给 `recordingSession.appendVideo(sample:)`。
3. session queue 内更新 timeline、保存最后视频帧、生成 retimed sample。
4. writer queue append retimed sample。

### 写入系统音频

1. `.audio` sample 交给 `recordingSession.appendSystemAudio(sample:)`。
2. session queue 内 retime。
3. writer queue append 到 system audio input。

### 写入默认麦克风

1. `AVAudioEngine` tap 使用 `AVAudioTime.hostTime` 生成 source PTS。
2. `AudioSampleBufferFactory.makeSampleBuffer(from:presentationTime:)` 创建 sample buffer。
3. sample 交给 `recordingSession.appendMic(sample:sourceTime:)`。

### 写入 AEC 麦克风

AEC 回调若没有时间戳，使用 session 内的 `AECAudioClock`：

- 第一个 AEC buffer source time = 当前 timeline source time 或 session source start。
- 每个后继 AEC source time = 上一个 AEC source time + `frameLength / sampleRate`。
- 该计数器只在 session queue 上更新。

不得使用“转换时刻的 host clock”作为每个 AEC buffer 的 PTS。

### 写入外接麦克风

`AVCaptureAudioDataOutput` sample 自带 PTS，直接交给 `recordingSession.appendMic(sample:sourceTime:)`。

## 暂停与恢复

`SCContext.pauseRecording()` 只负责切换 UI 状态并转发：

- 暂停：`recordingSession.pause(at: currentSourceTime)`。
- 恢复：`recordingSession.resume(at: currentSourceTime)`。

所有暂停状态写入 session queue。暂停期间所有轨道 sample 都被拒绝写入。恢复后的所有轨道都减去同一段暂停 duration。

## 停止流程

停止流程必须异步：

1. `SCContext.stopRecording()` 调用 `recordingSession.stop(completion:)` 后立即返回。
2. session 切换为 stopping，拒绝新 sample。
3. 停止 ScreenCaptureKit 和麦克风采集。
4. session queue 计算 `finalDuration`。
5. 如存在最后视频帧且 `finalDuration > lastVideoPTS`，创建 tail sample，PTS = `finalDuration`。
6. writer queue append tail sample、end session、mark inputs、finish writing。
7. writer completion 后调用 finalizer。
8. finalizer 完成后回主线程更新 UI、预览、通知、清理状态。

无论成功或失败，都必须释放 sleep preventer、音频 tap、overlay、控制面板和 capture session。

## Remux 与纯音频

### 视频 remux

- 只处理 writer 已完成的文件。
- duration 使用 `RecordingTimeline.finalDuration`。
- 视频轨插入 `0..<finalDuration`。
- 音频轨按可用范围插入并裁剪到 `finalDuration`。
- 音频短于 finalDuration 时不缩短最终视频。
- 音频长于 finalDuration 时裁掉超出部分。
- remux 失败时保留主录制文件和中间文件。

### 纯音频 qma

纯系统音频 + 麦克风也必须由 `RecordingSession` 和 `RecordingFinalizer` 管理：

- 系统音频文件 writer/`AVAudioFile` 关闭完成。
- 麦克风 writer finish 完成。
- qma package load/export 只能在两者完成后执行。
- 不允许保留旧 `vW.finishWriting {}` 直写分支。

## 错误处理与诊断

错误分类：

- writer creation failed
- writer start failed
- session start failed
- sample retime failed
- audio sample creation failed
- append dropped
- finish writing failed
- remux failed
- audio export failed

诊断信息：

- session source start time
- first video/audio/mic PTS
- pause/resume source time 和 duration
- dropped video/audio/mic count
- finalDuration
- writer status/error
- remux status/error

用户提示：

- writer 失败：保存失败，并显示底层错误摘要。
- remux 失败：主录制文件已保存，混音失败，中间文件保留。
- 后处理失败：录制素材保留，提示导出失败原因。

## 测试策略

### 自动测试

必须添加测试 target 或 SwiftPM 测试，覆盖：

- `RecordingTimeline`
  - 首个 sample 归零。
  - video/audio/mic 任一轨道先到都能启动 timeline。
  - 暂停 duration 被所有轨道扣除。
  - finalDuration 使用停止 source time。
  - PTS 单调。
- `SampleRetiming`
  - 有效 video sample PTS 被改写。
  - 有效 audio sample PTS 被改写。
  - duration 和 format description 保留。
  - invalid sample 安全失败。
- `AudioSampleBufferFactory`
  - 使用传入 PTS。
  - sample count 正确。
- `AECAudioClock`
  - 按 frameLength/sampleRate 连续递增。
- `RecordingWriter` 状态机
  - start -> writing -> stopping -> finished。
  - stopping 后拒绝 append。
  - finish 顺序包含 tail -> endSession -> markFinished -> finishWriting。
- `RecordingFinalizer`
  - 使用 finalDuration 裁剪。
  - remux 失败不删除主文件。

### 人工集成验证

- 静止画面录制 2 分钟，输出 duration 接近 2 分钟。
- 录制 30 秒，中途暂停 10 秒，输出 duration 接近 20 秒。
- 屏幕 + 系统音频。
- 屏幕 + 默认麦克风。
- 屏幕 + AEC 麦克风。
- 屏幕 + 外接麦克风。
- 屏幕 + 系统音频 + 麦克风 + remux。
- 纯系统音频 + 麦克风。
- 60 FPS 默认设置下启动录制，`minimumFrameInterval` 合法。
- 停止录制后立即预览，文件可播放。

## 完成标准

- `docs/recording-issues.md` 中 QR-REC-001 至 QR-REC-007 全部标记为已修复或有明确验证结果。
- 不存在 `SCContext.vW`、`SCContext.vwInput`、`SCContext.awInput`、`SCContext.micInput`、`SCContext.lastPTS`、`SCContext.timeOffset`、`SCContext.isResume`。
- 不存在 `CMTime(value: 1, timescale: 0)`。
- 不存在 `asSampleBuffer!`。
- 不存在录制路径直接调用 `AVAssetWriterInput.append`，除 `RecordingWriter` 内部。
- 不存在录制停止路径使用 `DispatchGroup.wait()` 阻塞 UI。
- 所有自动测试通过。
- Xcode Debug build 成功。
- 人工集成验证清单完成。
