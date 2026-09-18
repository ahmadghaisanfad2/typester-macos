# Changelog

All notable changes to Typester are documented in this file.

## [1.22.0] — 2026-09-18

### Fixed
- **Dictation HUDs follow every macOS Space.** The caption capsule, floating pill, learning toast, and accessibility helper stay on the active desktop when you swipe Desktop 1 → 2 → 3. Overlay windows use stronger Space flags (`.moveToActiveSpace` + elevated level), multi-pass reassert after Space transitions, and reassert after Dock/settings activation-policy flips.

### Added
- **Focus on my voice** (Settings → Dictation → Voice focus, default on):
  - Apple voice-processing DSP on the microphone path for all providers (noise / speech-focused capture).
  - On **Soniox** and **Deepgram**, enables speaker diarization and keeps only the **first speaker** after you start dictating, so nearby people’s speech is not pasted into your document.
  - **macOS mic mode** helper: opens Control Center Mic Modes so you can select **Voice Isolation** (best results; macOS does not allow apps to force this mode).
  - OpenAI / OpenRouter still get local voice-processing only (no provider speaker filter).
- **Voice glow** on the floating pill and caption overlay (from main after merging #23): colorful bottom-edge glow that blooms with mic level, traveling beam while transcribing, and Reduce Motion support.

### Notes
- Install from the DMG or use **Check for Updates…** in the menu bar.
- Stable-signed updates keep Accessibility / Microphone grants. Ad-hoc builds may need a one-time re-grant after install.
- For strongest noise rejection, set macOS mic mode to **Voice Isolation** while dictating.

## [1.21.0] — 2026-09-17

### Added
- Voice glow effects on the floating pill and caption overlay (feature-branch release; also included in 1.22.0 main).

## [1.20.1] — 2026-09-13

### Fixed
- Stable signing identity for releases so Accessibility / Microphone permissions survive updates.

## [1.20.0] — 2026-09-11

### Added
- Flexible hotkeys (hold-key sides, custom shortcut combos).
- Filler-word cleanup before paste.
- Floating Wispr-style dictation pill.
- Shotbase-style Accessibility permission setup helper.

## [1.19.4] — 2026-09-10

### Fixed
- Earlier attempt to keep the dictation pill visible on every macOS Space (superseded by the more complete 1.22.0 Space-follow work).

## [1.19.0] — 2026-09-10

### Added
- OpenRouter STT with live transcription models.
