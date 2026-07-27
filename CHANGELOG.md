# Changelog

## 1.7.1 — 2026-07-27

### Fixed

- Hardened the recording lifecycle, sample timing, and audio remuxing to improve recording stability and output finalization.
- Stopped automatic ScreenCaptureKit refresh retries after screen-recording access is denied, preventing repeated permission dialogs.
- Prevented stale mouse and asynchronous completion events from an old window-selection session from affecting a new session.

### Release metadata

- Marketing version: `1.7.1`
- Build number: `171`

## 1.7.0

- Fixed a crash that could occur while recording system audio.
