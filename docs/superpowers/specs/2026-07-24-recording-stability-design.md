# QuickRecorder 录制稳定性系统修复设计

日期：2026-07-24

## 背景

QuickRecorder 当前录制链路把 ScreenCaptureKit、AVAudioEngine、AVCaptureAudioDataOutput、AVAssetWriter 和后处理逻辑分散在 `RecordEngine.swift` 与 `SCContext.swift` 中。用户反馈“实际录制 6 分钟以上，导出视频只有 1 分多钟”。静态审查确认，根因是媒体文件时长依赖写入 sample buffer 的 PTS，而停止录制时没有补齐真实结束时间。

本设计聚焦 `docs/recording-issues.md` 中记录的录制稳定性问题，目标是做系统修复，而不是局部补丁。

## 目标

- 静止画面长时间录制时，输出视频 duration 接近真实录制时长。
- 视频、系统音频、默认麦克风、外接麦克风使用同一套录制时间轴。
- 暂停和恢复不造成音画错位，也不把暂停时长计入媒体 duration。
- 停止录制时 writer 写入、补尾帧、结束 session、finish 和后处理按确定顺序执行。
- remux 和纯音频导出只读取已经完成写入的文件。
- 保持现有 UI、选择器、快捷键入口尽量不变，降低迁移风险。

## 非目标

- 不重写屏幕、窗口、区域、应用选择 UI。
- 不一次性移除所有 `SCContext` 全局状态。
- 不改变用户可见的录制格式选项、编码器选项和保存目录逻辑。
- 不在第一阶段引入复杂帧生成器或固定帧率编码管线。

## 推荐方案

采用“录制会话协调器”方案：新增一个轻量录制核心，集中管理媒体时间轴和 writer 写入。现有 `AppDelegate`、`SCContext` 与选择器继续保留，但不再直接到处操作 `AVAssetWriterInput`。

### 新增组件

#### `RecordingTimeline`

职责：唯一管理录制媒体时间。

- 记录 writer session 起点。
- 记录 UI 计时起点。
- 记录暂停开始时间和累计暂停时长。
- 提供 `presentationTime(for:)`，把源 PTS 转换为录制内 PTS。
- 提供 `finalDuration`，供停止、补尾帧、remux 和日志使用。

设计原则：

- 所有轨道共享同一套暂停 offset。
- writer session 在首个可写 sample 到来时启动。
- 停止时使用 timeline 计算真实媒体结束时间。
- 不再让 `SCContext.lastPTS` 同时承担去重、暂停恢复、音频开闸和 duration 控制。

#### `RecordingWriter`

职责：唯一拥有并操作 `AVAssetWriter` 与 inputs。

- 持有 `AVAssetWriter`、video input、system audio input、mic input。
- 持有专用串行队列，例如 `QuickRecorder.RecordingWriter`。
- 管理状态：`idle`、`writing`、`stopping`、`finished`、`failed`。
- 暴露 `appendVideo`、`appendSystemAudio`、`appendMic`、`finish` 等方法。

写入规则：

- ScreenCaptureKit 和麦克风回调不直接 append。
- 所有 append、mark finished、end session、finish writing 都在 writer 串行队列执行。
- input not ready 时采用实时录制策略：记录 dropped count，避免阻塞采集回调；同时持续保留最后一个有效视频帧。
- 停止开始后拒绝新的外部 sample。

#### `RecordingSession`

职责：连接 UI/SCContext 与录制核心。

- 创建 timeline 和 writer。
- 接收 screen/system audio/mic sample。
- 处理 pause、resume、stop。
- 保存最后一个完整视频 sample。
- 对外暴露 display elapsed time、file path、stop result。

#### `RecordingFinalizer`

职责：录制结束后的确定性后处理。

- 等 writer 完成后再 remux、导出、预览和通知。
- remux 以 timeline 的 `finalDuration` 为准。
- remux 失败时保留中间文件，并向用户报告“主录制文件已保存，混音失败”。
- 纯音频 qma 包必须等待系统音频文件关闭和麦克风 writer finish 后再导出。

## 数据流

### 开始录制

1. 选择器继续调用 `AppDelegate.prepRecord(...)`。
2. `record(filter:fastStart:)` 创建 ScreenCaptureKit configuration。
3. 修正 `minimumFrameInterval`：
   - 若按用户 FPS 节流，使用 `CMTime(value: 1, timescale: CMTimeScale(frameRate))`。
   - 若明确不节流，使用 `CMTime.zero`。
   - 不再使用 `CMTime(value: 1, timescale: 0)`。
4. 初始化 `RecordingSession`，由 session 创建 writer 与 inputs。
5. `SCStreamOutput` 回调只把 sample 交给 session，不直接写 writer。

### 写入视频

1. 收到 `.screen` sample。
2. 校验 sample 有效、attachments 存在、`SCFrameStatus.complete`。
3. session 保存最后一个完整视频 sample。
4. timeline 将 sample PTS 转换为录制内 PTS。
5. writer 在串行队列 append retimed sample。

### 写入系统音频

1. 收到 `.audio` sample。
2. 交给 session。
3. 如果 writer session 已启动，timeline retime 后写入 system audio input。
4. 如果音频先于视频到达，第一版采用保守策略：session 启动前的少量音频不写入，避免黑屏前音频拉长文件。

### 写入默认麦克风

1. `AVAudioEngine` tap 使用回调里的 `AVAudioTime` 生成源 PTS。
2. `AVAudioPCMBuffer.asSampleBuffer` 改为接收明确的 PTS。
3. 转换失败时记录并丢弃该 buffer，不强制解包。
4. writer retime 后写入 mic input。

### 写入 AEC 麦克风

如果 AECAudioStream 能提供时间戳，则使用真实时间戳进入 timeline。若不能，则 writer 为 AEC 麦克风维护连续帧计数器，按采样率累加 PTS。该分支需要重点人工验证。

### 写入外接麦克风

`AVCaptureAudioDataOutput` 的 sample buffer 自带 PTS。回调只转交 session，由 writer 统一 retime 后 append。

## 暂停与恢复

暂停恢复由 timeline 事件管理。

- `pause()`：记录当前源时间或 host time，并让 session 进入暂停状态。
- 暂停期间 sample 不写入。
- `resume()`：累加暂停持续时间，恢复写入。
- 后续所有轨道 retime 时减去同一个 accumulated pause duration。
- 不再依赖下一帧视频计算全局 `timeOffset`。

成功标准：

- 录制 30 秒，中间暂停 10 秒，输出媒体 duration 接近 20 秒。
- 暂停后先到音频 sample 或先到视频 sample，都不会造成 offset 错乱。

## 停止流程

停止流程必须串行化和确定化。

1. UI、快捷键或自动停止触发 `SCContext.stopRecording()`。
2. `SCContext` 将停止请求转发给 `RecordingSession.stop()`。
3. session 状态切到 stopping，拒绝新的外部 sample。
4. 停止 ScreenCaptureKit、麦克风采集、mouse monitor、overlay。
5. timeline 计算 `targetEndTime`。
6. 如果存在最后视频帧且 `targetEndTime > lastVideoPTS`，创建同图像的新 sample，PTS 为 `targetEndTime`，append 到视频轨。
7. writer 调用 `endSession(atSourceTime: targetEndTime)`。
8. writer mark 所有已添加 input finished。
9. writer `finishWriting()` 完成后返回结果。
10. finalizer 执行 remux、纯音频导出、预览、通知。
11. 清理 `SCContext` 状态。

无论成功或失败，都必须释放 sleep preventer、音频 tap、overlay 和控制面板。

## Remux 与后处理

### 视频 remux

- 只处理已经 `finishWriting` 完成的文件。
- duration 使用 `RecordingTimeline.finalDuration`。
- 视频轨插入 `0..<finalDuration`。
- 音频轨插入可用范围并裁剪到 `finalDuration`。
- 音频短于 finalDuration 时不缩短最终视频。
- 音频长于 finalDuration 时裁掉超出部分。
- remux 失败时不删除原始录制文件。

### 纯音频录制

- 系统音频文件和麦克风 writer 都完成后，才允许 qma load、导出和预览。
- 当前 `vW.finishWriting {}` 不等待 completion 的流程需要改为异步 finalizer。

## 错误处理与诊断

新增低噪声诊断信息：

- writer session start PTS
- first video/audio/mic PTS
- pause/resume duration
- dropped video/audio/mic count
- finalDuration
- writer status 和 error
- remux status 和 error

错误分类：

- writer start failed
- sample retime failed
- append failed
- finish writing failed
- remux failed
- audio export failed

用户可见策略：

- 主录制文件成功但 remux 失败：通知用户主文件已保存，混音失败。
- writer 失败：通知保存失败，并输出具体错误。
- 后处理失败：保留中间文件，避免素材丢失。

## 兼容迁移

第一阶段保留 `SCContext` 作为 UI 与全局状态入口，但新增：

- `SCContext.recordingSession: RecordingSession?`

逐步替换：

- `SCContext.vW`
- `SCContext.vwInput`
- `SCContext.awInput`
- `SCContext.micInput`
- `SCContext.lastPTS`
- `SCContext.timeOffset`

迁移过程中，`SCContext.startTime`、`filePath`、`streamType` 暂时保留，避免大范围 UI 改动。

## 测试策略

### 单元测试

如果工程没有测试 target，先添加最小测试 target，覆盖纯逻辑：

- `RecordingTimeline`
  - 首帧归零。
  - 暂停时长被扣除。
  - finalDuration 等于真实录制时长减暂停时长。
  - 音频先到和视频先到都保持单调时间。
- sample retime helper
  - PTS 正确改写。
  - duration 和 format description 保留。
  - invalid sample 安全失败。

### 人工集成验证

- 静止画面录制 2 分钟，输出 duration 接近 2 分钟。
- 录制 30 秒，中途暂停 10 秒，输出 duration 接近 20 秒。
- 屏幕 + 系统音频。
- 屏幕 + 默认麦克风。
- 屏幕 + 外接麦克风。
- 屏幕 + 系统音频 + 麦克风 + remux。
- 纯系统音频 + 麦克风。
- 60 FPS 默认设置下启动录制，确认 `minimumFrameInterval` 合法。
- 停止录制后立即预览，确认文件已完成写入。

## 落地阶段

### 阶段一：视频时间轴与 writer 收口

- 新增 `RecordingTimeline` 和 `RecordingWriter`。
- 接入 screen video。
- 修复 `minimumFrameInterval`。
- 实现最后视频帧缓存、补尾帧、`endSession(atSourceTime:)`、串行 finish。
- 目标：解决短视频 duration 问题。

### 阶段二：音频轨接入统一时间轴

- 系统音频改由 session/writer 写入。
- 默认麦克风使用 `AVAudioTime` 生成 PTS。
- 外接麦克风统一 retime。
- 暂停恢复改为 timeline 事件。
- 目标：解决音画同步和暂停恢复问题。

### 阶段三：后处理收口与诊断

- remux 使用 `finalDuration`。
- 纯音频 qma finalizer 等待所有 writer 完成。
- 增加错误分类和诊断日志。
- 清理不再使用的 `SCContext` writer 全局变量。

## 风险与缓解

- 风险：真实 ScreenCaptureKit 行为难以完全自动化测试。
  - 缓解：保留人工验证清单和诊断日志。
- 风险：AEC 麦克风没有可靠时间戳。
  - 缓解：使用连续帧计数器，并单独实测。
- 风险：迁移期间 `SCContext` 和 session 双状态不一致。
  - 缓解：阶段一只让 session 拥有 writer，`SCContext` 只转发和显示。
- 风险：remux 改动可能影响已有双音轨流程。
  - 缓解：remux 失败保留中间文件，不破坏主录制结果。

## 完成标准

- `docs/recording-issues.md` 中 QR-REC-001 至 QR-REC-007 都有对应修复或明确验证结论。
- 静止画面长录制不会截断。
- 暂停恢复不会造成明显音画错位。
- 停止录制不会依赖并发回调时机。
- remux 不继承错误 duration。
- 失败时用户得到可理解提示，录制素材尽量保留。
