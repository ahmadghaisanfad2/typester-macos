---
feature: space-follow-voice-focus
status: delivered
updated: 2026-09-18
branch: fix/space-follow-voice-focus
commits: 4cc8bada96aa079472d72a4bf5b2312b695f7716..94a20dec92ac65f176011a866e76bce5173e61b2
---

# Space Follow + Voice Focus

## Report

**What was built** — Dictation HUDs (caption capsule, floating pill, learning toast, accessibility helper) now stay on the active macOS Space. `SpaceFollowingWindow` uses `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]`, a status-window+1 level, multi-pass reassert after Space swipes (0.05/0.20/0.45s), and reassert after activation-policy flips. Delayed passes require both `isVisible` and non-zero alpha so an ordered-out caption pill cannot be resurrected.

Voice focus (`SettingsStore.focusOnMyVoice`, default on) enables Apple voice-processing on the mic path for every provider (and disables it on warm engines when the setting is off). On Soniox and Deepgram it enables diarization and keeps only the first speaker after dictation starts. Unlabeled tokens still pass through. Settings exposes a “Focus on my voice” toggle and a macOS Mic Modes helper (system Voice Isolation cannot be forced by the app). Span joining inserts spaces when unpadded speaker-filtered deltas are batched so primary-speaker words never glue.

**Verification** — `swift build` PASS; `swift test` PASS (229 tests, 0 failures), including PrimarySpeakerFilterTests, VoiceFocusConfigTests, and span-join regressions. Independent review of `4cc8bad..25c00ca` found two criticals (Deepgram span glue; inverted Space reaffirm guard); fixed in `ed988f5` and re-review approved. Residual cross-message join fixed in the session assembler/overlay with tests. AppKit Space membership remains a residual manual check (swipe Desktop 1→2→3 while dictating).

**Journey log**
1. Prior v1.19.4 Space-follow (flags + single reaffirm) was insufficient for LSUIElement HUDs — policy flips and mid-transition reassert still pinned windows.
2. `.moveToActiveSpace` + multi-pass `orderFrontRegardless` + activation-policy notification address the real failure modes.
3. Review: STT span join must live in the shared router/assembler — provider parse alone cannot stop glued words after speaker filtering.
4. Review: Space reaffirm skip-guard must AND `isVisible` and alpha; SubtitleOverlay never zeros window alpha before `orderOut`.
5. Swift imports `setVoiceProcessingEnabled` as throwing, not `NSError**`; enable must run while the engine is stopped, then re-query input format.
6. SwiftPM naming is inverted vs folders: module `TypesterCore` = `Sources/TypesterLogic`; folder `Sources/TypesterCore` = `TypesterUI`.

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

1. `SpaceFollowingWindow.collectionBehavior` is:
   `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]`.
   `.moveToActiveSpace` makes a later `orderFrontRegardless()` relocate the window onto the *current* Space when AppKit had pinned it elsewhere.

2. Window level for HUDs: `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)` — above plain `.floating` / `.statusBar`, still below screensaver.

3. `SpaceFollowingWindow.reaffirm(_:)` re-applies collectionBehavior + level and calls `orderFrontRegardless()`.

4. `SpaceFollowingWindow.reaffirmWithTransitionPasses(_:reposition:)` reasserts immediately, then again at 0.05s, 0.20s, 0.45s. Delayed passes no-op unless `window.isVisible && window.alphaValue > 0.01` (AND — not OR).

5. `SpaceObserver` observes `NSWorkspace.activeSpaceDidChangeNotification` and `typesterActivationPolicyDidChange` (posted by AppDelegate after `setActivationPolicy`).

6. Overlays use transition-pass reaffirm. `SubtitleOverlay` reasserts while `presentationPhase != .hidden`.

7. No focus steal: windows stay `canBecomeKey/Main == false` where they already are.

8. Residual manual check: swipe Spaces while dictating; capsule + floating pill must remain on the active Space.

### S2.2 Voice focus

**Setting:** `SettingsStore.focusOnMyVoice: Bool = true` (persisted).

**Local DSP (all providers)**

- While the audio engine is stopped and before the input tap, if focus is on: `try inputNode.setVoiceProcessingEnabled(true)`, then re-query format.
- If focus is off and a warm engine still has VP enabled: disable it.
- Failure logs and continues; recording is not aborted.

**System Voice Isolation**

- Apps cannot force `AVCaptureDevice.MicrophoneMode.voiceIsolation`. Settings shows active mic-mode label + “Open Mic Modes…” → `showSystemUserInterface(.microphoneModes)`.

**Provider speaker filter**

- `PrimarySpeakerFilter`: unlabeled tokens always included; first non-empty speaker locks the session; other speakers dropped; `reset()` on connect.
- `STTParseResult.transcript` carries `speaker: String?` (2-arg convenience for unlabeled).
- `STTClientBase.routeParseResults` filters when focus is on and smart-joins unpadded spans with a single space.
- Soniox: `enable_speaker_diarization: true`; parse copies `speaker`.
- Deepgram: `diarize_model=latest`; word-level parse only when speaker labels exist; else channel transcript.
- OpenAI/OpenRouter: no provider filter; local VP still applies.
- `TranscriptSessionAssembler.appendFinal` and caption `updateFinal` smart-join unpadded deltas across messages.

**Settings UI** — Dictation → Voice focus: toggle + footer + conditional mic-mode row.

### S2.3 Testing boundaries

Logic target covers filter lock/drop/unlabeled/reset, Soniox/Deepgram config flags, parse speaker emission, routeParseResults filtering + span join, session-assembler join. AppKit Space membership is residual manual verification only.

## [S3] Out of Scope

- Multi-monitor coordinate re-pinning beyond `NSScreen.main`.
- Forcing macOS Control Center Voice Isolation without user action.
- Speaker enrollment / voiceprint models.
- OpenAI/OpenRouter provider-side speaker filtering.
- Language restriction (`language_hints_strict`).
- Changing pill/capsule visual design or voice-glow work on other branches.

## Tasks

- [x] T1: Harden `SpaceFollowingWindow` (behavior flags, elevated level, transition-pass reaffirm, activation-policy notification) — acceptance: helper applies S2.1 contracts; observer reacts to Space *and* activation-policy changes (covers: S2.1)
- [x] T2: Wire overlays to transition-pass reaffirm (`SubtitleOverlay`, `FloatingDictationPill`, `LearningHUD`, `AccessibilityDragHelper`) and fix SubtitleOverlay shouldReassert to `phase != .hidden` — acceptance: all four call the multi-pass helper; AppDelegate posts activation-policy notification (covers: S2.1; depends: T1)
- [x] T3: Add `focusOnMyVoice` setting + `PrimarySpeakerFilter` + Soniox/Deepgram config and parse speaker plumbing — acceptance: setting persists; filter unit tests pass; Soniox config and Deepgram query honor the flag (covers: S2.2)
- [x] T4: `STTParseResult` speaker field + `STTClientBase` route filter + AudioRecorder voice-processing enable + Settings UI row/Mic Modes — acceptance: logic tests cover filter via routeParseResults; recorder attempts VP when setting on; Settings shows toggle and mic-mode helper (covers: S2.2; depends: T3)
- [x] T5: Build + run full test suite — acceptance: `swift build` and `swift test` pass with new tests (covers: S2.2, S2.3)
