# Changelog

All notable changes to Typester are documented in this file.

## [1.25.6] — 2026-09-24

### Fixed
- **macOS kept asking for your login password.** Every API key was a computed property that read the Keychain on each access, and there was one item *per provider* — so opening Settings fired five reads on appear plus more on every render, and each one could raise the prompt. Keys now live in a single Keychain item, are read at most once per launch, and are cached. Opening Settings and onboarding no longer read a secret at all: whether a key is configured is answered from a stored flag, so neither screen touches the Keychain.
- The key fields no longer display the stored secret. They start empty with a “saved” tick, and **Remove** clears it — which is also why they no longer have to fetch it.

### Changed
- Existing per-provider items are folded into the single payload once, on the first launch after this update. That is the last time macOS may ask, and there is a hint in Settings and onboarding to choose **Always Allow** so it never asks again.

## [1.25.5] — 2026-09-23

### Fixed
- **Clicking the pill brought Typester to the front**, so the field you were dictating into lost its caret, the transcript was attributed to Typester instead of your app, and nothing pasted. The HUD was a plain borderless `NSWindow`: `canBecomeKey = false` only stops a window taking *key* focus — clicking any window still activates its app. The HUD is now an `NSPanel` subclass with the `.nonactivatingPanel` style mask, so clicks reach it without activating Typester, and it also refuses key/main focus and no longer hides on deactivate (a panel hides itself when its app deactivates, and a non-activating panel's app is permanently deactivated). Both halves are needed — either one alone still steals focus.

## [1.25.4] — 2026-09-23

### Fixed
- **The hover actions flickered on and off under the pointer.** Two hit-testable layers were competing for the pointer: the moment the buttons appeared they took the hover away from the capsule surface underneath, which hid them again. The capsule is now a *single* interactive surface, the actions are inert drawings, and a tap is routed to **Stop** or **Cancel** by point — against the same rects that are drawn, covered by `PillActionsLayoutTests`.

### Changed
- The capsule no longer shrinks under the pointer while the actions are showing. It keeps its size and the actions fill it, so there is nothing to chase and no dead space.

## [1.25.3] — 2026-09-23

### Fixed
- **The caption's hover buttons did nothing when clicked.** The gesture layer that gives the capsule its hit area sat on top of them and swallowed every click before it could reach them. The actions now render above it, and the AppKit-drawn capsule no longer accepts mouse events at all.
- **The buttons showed “…” instead of their labels.** They were sized to the caption content rather than to the capsule, so both labels truncated. The actions are now icon-only — a stop square and an × — which reads at a glance and needs no room.

### Changed
- While the hover actions are showing, the capsule pulls in to their footprint (122×36) rather than staying as wide as the transcript, so the bar stays balanced around them instead of leaving dead space either side.

## [1.25.2] — 2026-09-23

### Fixed
- **The caption was dead to the mouse and its buttons were crushed together.** Two separate faults. `NSHostingView` silently imposes its content's *minimum* size on the window, so every explicit frame smaller than the caption was overridden and the window never matched the capsule drawn inside it; and the view's own capsule size was never measured, because the preference it relied on did not propagate out of a `GeometryReader` background — so the capsule stayed pill-sized while the window was caption-sized. The hosting view now contributes only its intrinsic size, and the capsule is derived from the layout directly.
- **Hovering the caption blanked the transcript.** The gesture layer painted a filled shape over the caption to bound its hit area. It now draws nothing and only sets the hit region.
- **The resting pill sat 12 points too low.** An oversized layout inside a smaller window is centred rather than aligned to the bottom, so the pill ended up resting on the Dock instead of 12 points above it. The layout is now pinned to the pill's own footprint while resting.

### Changed
- The resting pill is slimmer — 42×14 rather than 44×24 — with a tighter shadow, and still lifts on hover.

## [1.25.1] — 2026-09-23

### Fixed
- **The pill slid diagonally across the screen as it expanded into the caption.** The window frame was animated while the caption content stayed pinned to its final size inside it, so mid-transition what you saw was a cropped corner of the caption tracking the moving window rather than the pill inflating. The window is now sized once per state and never moves: the capsule grows from the pill's own anchor point, bottom-centre, so the whole transition happens in place.
- **A revealed Dock covered the pill.** With **Automatically hide and show the Dock** on, macOS reports the screen as if the Dock were absent and says nothing when the Dock reveals itself — no notification fires and `NSScreen.visibleFrame` never changes — so the pill sat in the strip the Dock appears in and was hidden the moment it was reached for. When auto-hide is on the pill now reserves the Dock's configured thickness (tilesize, magnification, orientation), so it stays clear whether the Dock is showing or not.

### Changed
- Hovering the caption while dictating now offers **Stop** — finish and paste — next to **Cancel**, which discards. Mouse-only dictation no longer needs the hotkey to finish.
- The resting pill is a plain faint capsule: no logo, no text. It lifts on hover so it stays discoverable.

## [1.25.0] — 2026-09-23

### Added
- **The floating pill now morphs into the caption bar.** The click pill and the live-transcript capsule were two separate floating windows that could drift apart on screen. They are now one HUD: a small capsule that expands into the waveform + live transcript bar the moment dictation starts — by hotkey or by clicking the pill — and shrinks back to the pill when you stop. The transition is animated in place, anchored to the same edge.
- **The pill sits above the Dock, centered, and follows it.** Its resting position is computed from the screen's visible area instead of a hardcoded bottom-right corner, so it clears a pinned Dock, drops when the Dock is auto-hidden, and re-centers when the Dock moves to the left or right. It re-anchors on Dock and display changes without polling.
- **Settings → Floating pill → Position** picks the edge the pill rests against (**Bottom**, **Top**, **Left**, **Right**), always centered along that edge.

### Changed
- The caption bar also respects the Dock now: it used to be placed from the raw screen edge, so a pinned Dock could overlap it.

### Removed
- The separate floating-pill window and its view model, folded into the caption overlay so the two can no longer disagree about position or state.

## [1.24.2] — 2026-09-23

### Fixed
- **Dictation failed on every provider with empty “Failed · App” history and nothing pasted.** With **Focus on my voice** on, capture ran through Apple voice processing, which on some Macs delivers all-zero PCM — every recording was pure digital silence, so Soniox, Deepgram, OpenAI, OpenRouter and xAI all returned nothing. Typester no longer enables voice processing on the mic path at all (the 1.22.3 “start the engine before the tap” mitigation did not hold on these Macs); **Focus on my voice** keeps doing what it says by keeping only the first speaker on Soniox and Deepgram, and noise isolation is left to the macOS mic mode (**Voice Isolation** under Control Center → Mic Mode).
- **The silent-capture watchdog never fired.** It counted *buffers* against a ~60 Hz tap assumption, but Apple's voice processor delivers far fewer, larger buffers, so sustained silence went unnoticed instead of surfacing an error. It now measures silence in seconds, so a genuinely silent mic reports “the microphone is sending silence” instead of silently failing.

## [1.24.1] — 2026-09-23

### Fixed
- **xAI (Grok) dictation failed with "The model `grok-voice-transcribe-2` does not exist or your team does not have access to it".** The app sent a model ID xAI does not recognize. It now uses `grok-voice-transcribe-2.0` for both the **Real-time** and **Async** routes, and passes the model explicitly on the streaming WebSocket URL.

### Added
- Hovering the **Real-time / Async** mode picker (Soniox and xAI) now shows a tooltip noting that real-time transcription costs more.

## [1.24.0] — 2026-09-23

### Added
- **Punctuation styles.** Settings → Dictation → **Punctuation** now offers **Minimal**, **Casual**, **Neutral**, and **Formal**, and applies to every provider — Soniox (real-time and async), Deepgram, OpenAI, OpenRouter, and xAI:
  - **Minimal** strips sentence punctuation and auto-capitalization.
  - **Casual** drops sentence-ending periods but keeps `?`/`!` and abbreviations like `Dr.`.
  - **Neutral** keeps the provider's punctuation (the previous behavior).
  - **Formal** keeps full punctuation and adds a sentence-ending period.
- Each provider is steered natively where its API allows it, then the transcript is normalized locally so the result stays predictable: Soniox receives a `context.general` instruction, OpenAI a transcription `prompt`, Deepgram toggles `punctuate`/`smart_format`, and xAI async skips inverse text normalization for **Minimal**. xAI real-time exposes no formatting knob, so it relies on the same local normalization.

## [1.23.0] — 2026-09-22

### Added
- **xAI (Grok) speech-to-text provider.** Pick **xAI** in Settings or onboarding and choose a mode:
  - **Real-time** streams live text over the xAI WebSocket (`wss://api.x.ai/v1/stt`) with interim results, paste-on-pause, and speaker diarization for **Focus on my voice**.
  - **Async** records locally and uploads a WAV to `POST https://api.x.ai/v1/stt` after you stop (no live text, paste-on-pause disabled).
  - Uses the `grok-voice-transcribe-2.0` model. Dictionary terms are sent as `keyterm` hints, and a language hint enables text formatting.

### Notes
- Add your xAI API key from [console.x.ai](https://console.x.ai/team/default/api-keys) in Settings → xAI; it is stored in the macOS Keychain.

## [1.22.5] — 2026-09-22

### Fixed
- **Words are no longer split apart (`wel come`) in the pasted transcript or the live pill.** The 1.22.4 fix made Soniox token joining provider-aware, but two hardcoded "insert a space" paths were missed: tokens kept after a **Focus on my voice** speaker-filter skip still got a forced boundary space, and the floating pill still used its own space-between heuristic. Both now follow the provider's join policy — Soniox concatenates tokens as-is; Deepgram-style unpadded spans still get a boundary space.
- **Switching STT providers mid-session no longer keeps the old join style.** The session assembler's join style is re-synced whenever the provider changes (and at the start of each dictation), so dictating on Soniox after launching on another provider can no longer space-split words.

### Notes
- Dictate a short line with **Focus on my voice** on — history and the pill should show normal words.

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
