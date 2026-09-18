---
feature: space-follow-voice-focus
status: in-progress
updated: 2026-09-18
branch: fix/space-follow-voice-focus
commits: 4cc8bad..HEAD
---

# Space Follow + Voice Focus

## Report

## [S1] Problem

Two user-visible defects remain in Typester on macOS:

1. **HUD does not follow Spaces.** When the user starts dictation on Desktop 1 and swipes to Desktop 2 or 3, the caption capsule (live transcript + waveform), the floating click pill, and the learning toast stay on Desktop 1. A prior fix (v1.19.4, `SpaceFollowingWindow`) set collectionBehavior flags and reasserted on `activeSpaceDidChange`, but the overlays still pin to the first Space in real use.

2. **Dictation mixes other people’s speech.** The mic path captures raw `AVAudioEngine` input with no voice isolation. Nearby speech is transcribed and pasted. No provider-side speaker filter is configured.

User-chosen acceptance direction:
- All dictation overlays follow the active Space (caption capsule, floating pill, learning toast).
- Voice focus = combined local Apple voice-processing + provider diarization primary-speaker filter.
- Primary speaker = first speaker after dictation starts for that session.

## [S2] Design

### S2.1 Space following

**Why the shipped flags were not enough**

- `LSUIElement` / `.accessory` apps can still pin borderless HUD windows to the Space where they were first ordered front, even with `.canJoinAllSpaces`.
- Space transitions are animated; a single immediate `orderFrontRegardless()` can run mid-transition and be lost.
- `AppDelegate.updateActivationPolicy` flips between `.accessory` and `.regular` when Settings/onboarding/Dock visibility change; that flip can re-pin existing HUD windows.
- `SubtitleOverlay` only reasserted while `presentationPhase == .visible`, so presenting/dismissing frames skipped reassert.

**Contracts**

1. `SpaceFollowingWindow.collectionBehavior` becomes:
   `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]`.
   `.moveToActiveSpace` makes a later `orderFrontRegardless()` relocate the window onto the *current* Space when AppKit had pinned it elsewhere.

2. Window level for HUDs: `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)` — above plain `.floating` / `.statusBar`, still below screensaver.

3. `SpaceFollowingWindow.reaffirm(_:)` re-applies collectionBehavior + level and calls `orderFrontRegardless()`.

4. `SpaceFollowingWindow.reaffirmWithTransitionPasses(_:reposition:)` reasserts immediately, then again at ~0.05s, ~0.20s, ~0.45s. Each pass re-applies flags + `orderFrontRegardless()` and invokes `reposition`. Passes no-op if the window has been ordered out or alpha is ~0.

5. `SpaceObserver` observes:
   - `NSWorkspace.activeSpaceDidChangeNotification`
   - `TypesterActivationPolicyDidChange` (posted by AppDelegate after `setActivationPolicy`)
   and calls the transition-pass reassert while `shouldReassert()` is true.

6. Overlays (`SubtitleOverlay`, `FloatingDictationPill`, `LearningHUD`, `AccessibilityDragHelper`) use transition-pass reaffirm. `SubtitleOverlay` reasserts while `presentationPhase != .hidden` (not only `.visible`).

7. No focus steal: windows stay `canBecomeKey/Main == false` where they already are; `orderFrontRegardless` only.

8. Residual manual check: swipe Spaces while dictating; capsule + floating pill must remain on the active Space. AppKit HUD Space membership is not covered by the logic test target.

### S2.2 Voice focus

**Setting:** `SettingsStore.focusOnMyVoice: Bool = true` (persisted). When off, behavior matches today: raw input, no diarization filter.

**Local DSP (all providers)**

- While the audio engine is *stopped* and before installing the input tap, if `focusOnMyVoice` is true, call `engine.inputNode.setVoiceProcessingEnabled(true, error:)` (macOS 10.15+). This enables Apple’s voice-processing AU (noise suppression / echo path / speech-focused DSP).
- Re-query `inputNode.outputFormat(forBus: 0)` *after* enabling voice processing — the format can change — then build the converter/tap as today.
- If enable fails, log and continue without it (graceful degradation). Do not abort recording.
- When `focusOnMyVoice` is false, do not enable voice processing on newly created engines.

**System Voice Isolation (macOS Control Center)**

- Apps cannot force `AVCaptureDevice.MicrophoneMode.voiceIsolation`; the user selects it. Settings shows a row when `focusOnMyVoice` is on:
  - Status from `AVCaptureDevice.activeMicrophoneMode` / `preferredMicrophoneMode`.
  - Button “Open Mic Modes…” → `AVCaptureDevice.showSystemUserInterface(.microphoneModes)`.
- Footer copy: best results when macOS mic mode is Voice Isolation; Typester still applies voice-processing DSP and speaker filtering without it.

**Provider speaker filter**

- Pure logic type `PrimarySpeakerFilter` in `TypesterLogic`:
  - `nil` / empty speaker labels → always include (provider did not diarize).
  - First non-empty speaker after `reset()` locks the session’s primary speaker.
  - Subsequent tokens with a different speaker are dropped; same speaker is kept.
  - `reset()` on each dictation session start / client connect.
- `STTParseResult.transcript` gains an associated `speaker: String?` (default nil at call sites that have no labels).
- `STTClientBase.routeParseResults` holds a `PrimarySpeakerFilter`. When `SettingsStore.shared.focusOnMyVoice` is true, tokens whose speaker is present and ≠ locked primary are dropped. When the setting is false, no filtering.
- **Soniox realtime:** `SonioxRealtimeSessionConfig.build(..., focusOnMyVoice:)` sets `"enable_speaker_diarization": true` when focus is on. `SonioxConnectionConfig.parseResponse` copies `token["speaker"]` into the transcript result.
- **Deepgram streaming:** when focus is on, query adds `diarize_model=latest`. `parseResponse` prefers `words[]` (with `speaker`) when present: filter words via the same first-speaker policy *inside* parse only if labels exist; if the response has no `words`, fall back to the channel transcript (unlabeled → include all). Token-level filter in `STTClientBase` still applies when speaker labels appear on words assembled into transcript pieces — Deepgram path will emit per-word transcripts with speaker so the shared filter can apply consistently.
  Implementation note: Deepgram parse emits one `.transcript` per kept word span (or the full unlabeled transcript). Prefer emitting word-level results with `speaker` when `words` is present so `STTClientBase` owns the lock (single policy, testable).
- **OpenAI / OpenRouter / Soniox async file path:** no realtime diarization filter. Local voice processing still applies to OpenAI/OpenRouter recording. OpenRouter batch models may transcribe other speech; out of scope for speaker filter.
- Diarization + paste-on-pause: Soniox docs note endpoint detection reduces diarization accuracy. When both `focusOnMyVoice` and `pasteOnPause` are on, still enable diarization; do not change endpoint settings.

**Settings UI**

- Dictation section: “Focus on my voice” toggle + footer explaining local DSP + first-speaker keep on Soniox/Deepgram + link/button for Mic Modes.
- Default on.

### S2.3 Testing boundaries

Logic target (`TypesterCore` / `Sources/TypesterLogic`) covers:
- `PrimarySpeakerFilter` lock / drop / unlabeled / reset.
- Soniox session config includes/excludes `enable_speaker_diarization`.
- Deepgram query includes/excludes `diarize_model`.
- Soniox/Deepgram parse emit speaker labels.
- `STTClientBase` filtering behavior via a small test subclass or direct `routeParseResults` with focus flag (SettingsStore in tests: set `focusOnMyVoice` before the case).

UI/AppKit Space membership is residual manual verification only.

## [S3] Out of Scope

- Multi-monitor coordinate re-pinning beyond `NSScreen.main`.
- Forcing macOS Control Center Voice Isolation without user action.
- Speaker enrollment / voiceprint models.
- OpenAI/OpenRouter provider-side speaker filtering.
- Changing pill/capsule visual design or voice-glow work on other branches.
- Language restriction (`language_hints_strict`) — not selected.

## Tasks

- [ ] T1: Harden `SpaceFollowingWindow` (behavior flags, elevated level, transition-pass reaffirm, activation-policy notification) — acceptance: helper applies S2.1 contracts; observer reacts to Space *and* activation-policy changes (covers: S2.1)
- [ ] T2: Wire overlays to transition-pass reaffirm (`SubtitleOverlay`, `FloatingDictationPill`, `LearningHUD`, `AccessibilityDragHelper`) and fix SubtitleOverlay shouldReassert to `phase != .hidden` — acceptance: all four call the multi-pass helper; AppDelegate posts activation-policy notification (covers: S2.1; depends: T1)
- [ ] T3: Add `focusOnMyVoice` setting + `PrimarySpeakerFilter` + Soniox/Deepgram config and parse speaker plumbing — acceptance: setting persists; filter unit tests pass; Soniox config and Deepgram query honor the flag (covers: S2.2)
- [ ] T4: `STTParseResult` speaker field + `STTClientBase` route filter + AudioRecorder voice-processing enable + Settings UI row/Mic Modes — acceptance: logic tests cover filter via routeParseResults; recorder attempts VP when setting on; Settings shows toggle and mic-mode helper (covers: S2.2; depends: T3)
- [ ] T5: Build + run full test suite — acceptance: `swift build` and `swift test` pass with new tests (covers: S2.2, S2.3)
