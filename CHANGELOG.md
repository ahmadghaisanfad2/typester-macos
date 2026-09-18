# Changelog

All notable changes to Typester are documented in this file.

## [1.22.4] — 2026-09-18

### Fixed
- **Transcripts no longer split words** (`Wel com e back to o ur world` → `Welcome back to our world`). Soniox realtime tokens already include spaces at word boundaries; the assembler was inserting an extra space between every unpadded token. Join style is now provider-aware: Soniox concatenates tokens as-is; spaces are only added after a speaker-filter skip (or for Deepgram-style unpadded spans).

### Notes
- Dictate a short English line after updating — history should show normal words.
- Mixed Arabic/English greetings should come through as continuous words, not letter groups.

## [1.22.3] — 2026-09-18

### Fixed
- **Transcriptions no longer fail with empty “Failed · App” history.** Failed sessions were recording **digital silence** (RMS 0) on the mic path when **Focus on my voice** (Apple voice-processing DSP) was on. The audio engine now starts *before* the input tap is installed (VP rewrites the format at start), converts to non-interleaved Int16, and surfaces a clear error if silence persists.
- **Focus on my voice defaults to off.** Re-enable it in Settings → Dictation after a successful dictate if you want DSP + primary-speaker filtering.

### Notes
- Stable-signed 1.22.3 keeps Accessibility / Microphone grants.
- If you still see Failed history entries, check Settings → Dictation → Focus on my voice is off, then dictate again.

## [1.22.2] — 2026-09-18

### Fixed
- **Voice glow stays inside the capsule.** Ported the refined in-capsule glow from `feature/voice-glow`: the colorful gradient paints the pill/caption body (clipped by the capsule), and transcribing shows a border beam on the capsule edges — not a bloom floating outside the plate.
- **Dictation HUDs stay on every macOS Space.** HUD `collectionBehavior` uses `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.ignoresCycle` (no `.moveToActiveSpace`), so AppKit will not abort and overlays remain visible across Spaces.

### Notes
- Stable-signed 1.22.2 keeps Accessibility / Microphone grants from earlier stable builds.
- Install from the DMG or **Check for Updates…**.

## [1.22.1] — 2026-09-18

### Fixed
- **Onboarding Accessibility crash.** Typester 1.22.0 aborted when step 3 presented the Accessibility helper. AppKit rejects HUD `collectionBehavior` that combined `.moveToActiveSpace` with `.canJoinAllSpaces` or `.stationary`. Overlay windows now use a validated flag set (`.fullScreenAuxiliary` + `.ignoresCycle` + `.moveToActiveSpace`) via `SpaceFollowPolicy`.
- **Single-window Accessibility grant.** Removed the floating drag-helper window. Onboarding, Settings, and permission recovery keep one in-window Typester drag tile and open System Settings — no second Typester window.

### Notes
- Stable-signed 1.22.1 keeps Accessibility / Microphone grants from earlier stable builds.
- Install from the DMG or use **Check for Updates…** in the menu bar.

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
