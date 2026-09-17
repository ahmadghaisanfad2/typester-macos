---
feature: voice-glow
status: delivered
updated: 2026-09-18
branch: feature/voice-glow
commits: 4cc8bada96aa079472d72a4bf5b2312b695f7716..929c51039812ac242ec16fa0300b1603b9664844
---

# Voice Glow (Libraries.dev Voice — native port)

## Report

**What was built** — A native SwiftUI port of Libraries.dev’s Voice effect for Typester. `VoiceGlowPalette` / `VoiceGlowConfig` / `VoiceGlowDriver` / `VoiceGlowFrame` / `VoiceGlowTargetBox` live in `Sources/TypesterLogic` (SPM target `TypesterCore`); `VoiceGlowBeamView` draws a colorful multi-lobe bottom-edge bloom in `Sources/TypesterCore` (target `TypesterUI`). `AppDelegate` fans `AudioRecorder.onAudioLevel` out to the floating pill and the caption overlay; `onSpectrum` still feeds the existing bar waveform only. While recording, glow rises and blooms with mic energy; while processing, a concentrated beam travels the bottom edge. Reduce Motion freezes the beam into a steady mid glow. Pill windows re-measure on state change so reserved glow height is not clipped.

**Verification** — `swift build --target TypesterUI` PASS. `swift test` PASS (222 tests, 0 failures), including 10 `VoiceGlowModelTests` (palette lobes, attack/release, threshold gate, beam phase, target-box reset/inactive). Independent review of `4cc8bad..dcccdfc` flagged one critical (pill NSWindow never re-laid-out for glow height); fix landed in `929c510` and focused re-review approved with no remaining criticals.

**Journey log**
1. Repo is Swift/SwiftUI only — `voice-glow` cannot be npm-installed; grill chose a native port on pill + subtitle, colorful palette.
2. Package naming trap: folder `Sources/TypesterLogic` is target **TypesterCore**; folder `Sources/TypesterCore` is target **TypesterUI**.
3. 60 Hz mic UI must use non-`@Published` target boxes + `TimelineView(.animation(paused:))` (pattern of `SpectrumTargetBox`).
4. Borderless pill NSWindows are not content-sized: height-changing UI must `layoutSubtreeIfNeeded` + `setFrame`; Space observer will not save you. Clip flags must be reapplied on every `NSHostingView` / `contentView` swap.
5. Glow drawn as `.background` does not enlarge layout — reserved spacer height feeds window `fittingSize`.

## [S1] Problem

Typester’s floating pill and caption overlay show recording state with a static indicator or a monochrome bar waveform. They do not communicate live voice energy the way modern dictation UIs do: a colorful glow that rises and blooms from the bottom edge while speaking, and a traveling beam while the provider is transcribing.

Libraries.dev ships this as the React package `voice-glow` (`VoiceBeam` / `useMicrophone`). This repository is a native Swift/SwiftUI macOS app with no React/npm surface, so the package cannot be installed. The effect must be ported natively, reusing Typester’s existing mic pipeline (`AudioRecorder.onAudioLevel`, `onSpectrum`).

## [S2] Design

**Chosen behavior**

A native “Voice glow” overlay on:

1. **FloatingDictationPill** — colorful multi-lobe bloom along the bottom edge of the capsule while listening; levels rise with mic energy; while `isProcessing`, a concentrated beam travels left→right along the pill’s range.
2. **Subtitle/caption overlay** — the same visual language on the caption pill’s bottom edge (not a replacement for the existing bar waveform). Recording: bloom with voice. Processing: traveling beam.

Default palette is Libraries.dev **colorful** (multi-lobe). Geometry scales per surface (compact pill vs wider caption pill).

**Pipeline**

```
AudioRecorder.emitAnalysis (main, ~60 Hz)
  onAudioLevel(0…1) ──► FloatingDictationPill.setLevel
                   └──► SubtitleViewModel.updateLevel
  onSpectrum(bands) ──► SubtitleViewModel.updateSpectrum (unchanged waveform bars)
```

`VoiceGlowDriver` (logic) smooths the 0…1 level (threshold gate, attack/release, idle floor) and, when processing, advances a beam phase. UI views read a non-`@Published` holder on a `TimelineView` so 60 Hz updates do not storm SwiftUI publishes — same pattern as `SpectrumTargetBox`.

**Contracts**

1. **`VoiceGlowPalette`** (logic): up to 7 lobe hex colors + band colors. `static let colorful` is the default vibrant multi-lobe set.
2. **`VoiceGlowConfig`** (logic): `threshold`, `attack`, `release`, `idle`, `reach`, `spread`, `strength`, `beamPeriod` (delivered also includes `processingLevel` for the steady processing glow).
3. **`VoiceGlowDriver.step(level:processing:time:active:)` → `VoiceGlowFrame`**:
   - `level`: smoothed 0…1 bloom energy (gated below `threshold` toward `idle`).
   - `intensity`: overall opacity factor including idle floor.
   - `beamPhase`: `Float?` — non-nil only while `processing`; 0…1 travel position with period `beamPeriod`.
4. **`VoiceGlowBeamView`** (UI): `Canvas` overlay, `allowsHitTesting(false)`, draws multi-lobe soft gradients along the bottom edge; when `beamPhase != nil`, concentrates a bright core at that horizontal position. Honors `accessibilityReduceMotion` (static low bloom, no travel).
5. **Wiring**:
   - `AppDelegate` assigns `audioRecorder.onAudioLevel` to both overlays.
   - `FloatingDictationPillViewModel` / `SubtitleViewModel` hold latest level in a box; reset to 0 on hide/stop/processing end as appropriate.
   - Processing state already exists on both view models; glow reads it, does not invent a second state machine.
   - Pill window re-lays-out (`layoutSubtreeIfNeeded` + `setFrame` on `fittingSize`) on recording/processing transitions so reserved glow height is visible; hosting clip flags applied on every contentView swap.
6. **Idle / inactive**: when pill is idle (not recording, not processing) or subtitle is hidden, glow is off or at a negligible idle floor — no full bloom.
7. **Performance**: glow is a non-interactive Canvas; 8pt bottom reservation on the pill when active, removed when idle. Subtitle bottom padding increased slightly (44→52) to host the bloom.

**Error / edge behavior**

- Mic permission denied or recorder error: levels stay 0 → idle glow, no crash.
- Reduce Motion: no traveling beam animation; processing shows a steady mid-level glow.
- Rapid start/stop: driver reset clears smoothed level so the next session does not inherit bloom.

## [S3] Out of Scope

- Installing or shimming the npm package `voice-glow`, React, or WKWebView.
- Settings UI toggle / colorVariant picker (always-on colorful for this delivery).
- Changing the existing subtitle bar waveform algorithm (spectrum bars stay).
- Per-lobe spectrum coloring beyond a simple level-driven multi-lobe bloom.
- Light-theme pill variants (overlays are dark chrome today).
- OpenRouter/Soniox/Deepgram behavior changes.

## Tasks

- [x] T1: Add `VoiceGlowPalette`, `VoiceGlowConfig`, `VoiceGlowDriver`, `VoiceGlowFrame` in TypesterLogic — acceptance: public types compile in TypesterCore target; colorful palette has ≥5 lobes (covers: S2)
- [x] T2: Unit-test driver envelope + beam phase — acceptance: tests cover attack rise, release fall, threshold→idle, processing beamPhase advances, reset clears (covers: S2; depends: T1)
- [x] T3: Add `VoiceGlowBeamView` canvas overlay in TypesterUI — acceptance: view renders bottom-edge multi-lobe glow; processing mode draws traveling core; reduce-motion path static (covers: S2; depends: T1)
- [x] T4: Wire levels into FloatingDictationPill — acceptance: `onAudioLevel` updates pill view model; recording blooms with voice; processing shows beam; idle/off when not dictating; window re-lays-out for glow height (covers: S2; depends: T1, T3)
- [x] T5: Wire levels into SubtitleOverlay caption pill — acceptance: same glow language on caption bottom edge; existing waveform bars unchanged; levels reset on hide (covers: S2; depends: T1, T3)
- [x] T6: Verify build + tests — acceptance: `swift build --target TypesterUI` PASS; `swift test` PASS (covers: S2; depends: T2, T4, T5)
