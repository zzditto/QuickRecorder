# QuickRecorder 录制链路问题记录

本文记录 2026-07-24 对录屏/录音链路的静态审查结果。当前文档只记录问题和证据，不包含修复实现。

## QR-REC-001：录制时长被截断到最后一帧画面变化时间

- 严重级别：高
- 状态：根因已确认
- 现象：用户实际录制 6 分钟以上，但导出视频只有 1 分多钟；多次复现。
- 触发条件：录制过程中后半段画面静止或 ScreenCaptureKit 没有继续交付新的屏幕帧，尤其是无系统音频或音频轨没有拉长容器时。
- 根本原因：状态栏时长使用 `Date.now` 计算真实经过时间，但 `AVAssetWriter` 的视频时长由写入 sample buffer 的 PTS 决定。当前停止录制时直接 `markAsFinished()`/`finishWriting()`，没有补写一帧到真实停止时间，也没有调用 `endSession(atSourceTime:)` 将媒体会话结束到当前录制时间。ScreenCaptureKit 又只在屏幕内容变化时交付帧，因此最终文件时长会停在最后一帧到达的时间。
- 代码证据：
  - UI 计时使用墙钟：`QuickRecorder/SCContext.swift:324-331`
  - 首帧到达后用 sample PTS 启动 writer session：`QuickRecorder/RecordEngine.swift:598-600`
  - 屏幕帧只在 sample 回调内 append：`QuickRecorder/RecordEngine.swift:603-628`
  - 停止录制时直接结束 input/writer，未补尾帧/未 end session：`QuickRecorder/SCContext.swift:351-408`
  - 代码注释已说明 SCK 只在变化时交付帧：`QuickRecorder/RecordEngine.swift:229-234`
- 影响：静止画面录屏、演示停顿、长时间等待页面加载、只录桌面但没有持续变化时，输出视频时长明显短于用户看到的录制时长。
- 建议修复方向：
  - 保存最后一帧 video sample buffer。
  - 停止录制前基于真实停止时间构造同图像的新 sample buffer，PTS 设置为目标结束时间，append 后再结束输入。
  - 或显式 `endSession(atSourceTime:)` 到结束时间，但仍需确认不同容器/播放器是否保留最后静止画面。
  - 增加最小复现测试：录制 10 秒，其中前 2 秒有画面变化、后 8 秒静止，校验文件 duration 接近 10 秒。

## QR-REC-002：`minimumFrameInterval` 在 60 FPS 及以上使用了无效/异常 CMTime

- 严重级别：中
- 状态：高可信问题
- 现象：60 FPS 及以上时帧节流配置异常，可能导致采集行为不稳定、性能压力变高，或和预期帧率不一致。
- 根本原因：当前代码在 `frameRate >= 60` 时设置 `CMTime(value: 1, timescale: 0)`，并把它注释为“0 表示不节流”。但 `timescale` 为 0 的 `CMTime` 不是表达零时长的正常方式；不节流应使用 `.zero` 或符合 API 语义的零时长。
- 代码证据：
  - `QuickRecorder/RecordEngine.swift:223-239`
- 影响：用户选择默认 60 FPS 时就会走到该分支，可能放大掉帧、时间戳异常、CPU/编码压力等问题。
- 建议修复方向：
  - 若要不节流，使用 `CMTime.zero`。
  - 若要按用户选择节流，统一使用 `CMTime(value: 1, timescale: CMTimeScale(frameRate))`，不要在 60 FPS 特判为 `timescale: 0`。
  - 增加启动录制时的断言/日志，确保 `minimumFrameInterval.isValid`。

## QR-REC-003：暂停/恢复只修正视频时间戳，没有同步修正系统音频和麦克风时间戳

- 严重级别：高
- 状态：高可信问题
- 现象：暂停恢复后，可能出现音频空洞、音画不同步、容器 duration 被音频拉长，或恢复后的音频时间轴和视频时间轴不一致。
- 根本原因：恢复时 `timeOffset` 只用于 `.screen` sample buffer。系统音频 `.audio` 分支直接 append 原始 sample buffer；默认麦克风和外接麦克风也直接 append 自己的 sample buffer。暂停期间虽然回调被 return 掉，但恢复后的音频 PTS 没有减去暂停时长。
- 代码证据：
  - 恢复时计算 `timeOffset`：`QuickRecorder/RecordEngine.swift:577-587`
  - 只对屏幕 sample 调用 `adjustTime`：`QuickRecorder/RecordEngine.swift:602`
  - 系统音频直接 append：`QuickRecorder/RecordEngine.swift:641-643`
  - 默认麦克风直接 append：`QuickRecorder/RecordEngine.swift:473-486`
  - 外接麦克风直接 append：`QuickRecorder/RecordEngine.swift:721-725`
- 影响：用户使用暂停/恢复功能并录制音频时，导出结果可能出现明显不同步。
- 建议修复方向：
  - 建立统一的录制时间轴，所有视频/系统音频/麦克风 sample 都经过同一套 PTS 重基准和暂停 offset 处理。
  - 对暂停恢复增加集成测试：录制音视频，暂停 3 秒，恢复后继续录制，校验最终 duration 不包含暂停时长且音画同步。

## QR-REC-004：默认麦克风 sample buffer 使用转换时刻作为 PTS，可能产生漂移和抖动

- 严重级别：中
- 状态：高可信问题
- 现象：默认麦克风录制可能出现轻微漂移、延迟不稳定，长录制或高负载下更明显。
- 根本原因：`AVAudioPCMBuffer.asSampleBuffer` 在转换时使用 `CMClockGetTime(CMClockGetHostTimeClock())` 作为 `presentationTimeStamp`，忽略了 `AVAudioEngine` tap 回调提供的 `AVAudioTime`。这个 PTS 是“处理/转换发生的时间”，不是音频 buffer 被采集的真实时间。
- 代码证据：
  - tap 回调拿到了 `time` 但没有使用：`QuickRecorder/RecordEngine.swift:482-485`
  - sample buffer PTS 使用当前 host clock：`QuickRecorder/RecordEngine.swift:773-776`
- 影响：麦克风轨与视频/系统音频轨之间可能产生随机偏移；CPU 忙、回调排队、AEC 开启时风险更高。
- 建议修复方向：
  - 基于 `AVAudioTime` 的 hostTime/sampleTime 生成 PTS。
  - 或在 writer session 启动时记录统一 origin，然后按采样帧数累加生成单调 PTS。
  - 避免强制解包 `pcmBuffer.asSampleBuffer!`，转换失败时应记录错误并跳过。

## QR-REC-005：停止录制与 sample 回调并发访问 `AVAssetWriterInput`，存在竞态

- 严重级别：中
- 状态：高可信问题
- 现象：停止录制瞬间可能出现写入失败、丢尾帧、偶发崩溃或 `AVAssetWriter` 状态异常。
- 根本原因：ScreenCaptureKit 输出回调运行在 `.global()` 队列，麦克风也有独立队列；停止录制在主线程/其他线程中调用 `stopCapture()`、`markAsFinished()`、`finishWriting()`。当前没有专用串行写入队列，也没有停止状态门闩来确保“停止后不再 append”。
- 代码证据：
  - SCK 输出使用全局队列：`QuickRecorder/RecordEngine.swift:282-283`
  - sample 回调中直接 append video/audio：`QuickRecorder/RecordEngine.swift:628`、`QuickRecorder/RecordEngine.swift:643`
  - 停止录制中直接 mark/finish：`QuickRecorder/SCContext.swift:364-379`
  - 麦克风独立回调中直接 append：`QuickRecorder/RecordEngine.swift:721-725`
- 影响：长时间录制或高帧率录制停止时更容易暴露；也会影响 QR-REC-001 的尾帧补写可靠性。
- 建议修复方向：
  - 为 `AVAssetWriter` 写入建立专用串行队列，所有 append/mark/finish/endSession 都在同一队列执行。
  - 增加 `isStopping` 状态，停止开始后拒绝新的外部 sample append。
  - `stopCapture()` 完成和 writer finish 之间应有明确顺序，不依赖并发回调自然停止。

## QR-REC-006：系统音频 + 麦克风的纯音频录制完成流程没有等待麦克风 writer 完成

- 严重级别：中
- 状态：高可信问题
- 现象：纯音频录制且同时录系统音频和麦克风时，停止后立即进入后续导出/预览逻辑，可能读到尚未完成写入的麦克风文件。
- 根本原因：`streamType == .systemaudio` 且 `recordMic == true` 时调用 `vW.finishWriting {}`，但没有等待 completion；后续代码继续执行 qma/remux/export 逻辑。
- 代码证据：
  - 系统音频分支未等待 `finishWriting`：`QuickRecorder/SCContext.swift:409-410`
  - 后续立即可能读取 qma 并导出：`QuickRecorder/SCContext.swift:426-463`
- 影响：生成的音频包可能缺少麦克风尾部，或偶发导出失败。
- 建议修复方向：
  - 和视频分支一样等待 writer completion，或改成异步状态机，在 completion 后再触发导出/预览/通知。

## QR-REC-007：双音轨 remux 使用视频 asset duration 裁剪音频，可能继承被截断的视频时长

- 严重级别：中
- 状态：由 QR-REC-001 派生的高可信问题
- 现象：开启系统音频 + 麦克风并 remux 时，如果视频轨已因 QR-REC-001 被截短，后续混音也会按截短的视频 duration 裁掉音频。
- 根本原因：`mixAudioTracks` 插入音频和视频时都使用 `asset.duration` 作为时间范围。如果原始视频容器 duration 已短于真实录制时间，则音频导出和最终 composition 都继承短 duration。
- 代码证据：
  - 音频混合使用 `asset.duration`：`QuickRecorder/SCContext.swift:760-764`
  - 最终视频插入也使用 `asset.duration`：`QuickRecorder/SCContext.swift:806-807`
- 影响：即使音频真实更长，最终 remux 文件也可能被裁成短视频。
- 建议修复方向：
  - 先修复录制 session 结束时间。
  - remux 时使用各轨道 duration 的明确策略，例如以视频修正后的 duration 为准，或以最大有效轨道 duration 为准并补尾帧。
