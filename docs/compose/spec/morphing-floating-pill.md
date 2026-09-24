---
feature: morphing-floating-pill
status: delivered
updated: 2026-09-23
branch: cursor/morphing-dock-aware-pill
commits: 1b190d6 (v1.25.0)
---

# Morphing Floating Pill (Dock-aware)

## Report

**What was built** — The floating click pill and the live-transcript caption capsule were two independent borderless HUD windows driven in parallel by every dictation call site. They are now one HUD owned by `SubtitleOverlay`: a single `morph` value (0 = resting pill, 1 = expanded caption) drives one shell. At 0 the shell is a small faint capsule with no logo and no text; at 1 it is the existing caption bar (waveform + live transcript + Voice glow). The shell's frame, corner radius, shadow depth and opacity all interpolate on that one value, and the caption crossfades in over the back half of the growth.

`FloatingDictationPill` is deleted; its view model, drag and window logic are gone rather than kept as a parallel path. Behaviour with **Show floating pill** off is unchanged (caption appears only while dictating), apart from the Dock fix below.

**Amended 1.25.1** — The first cut animated the *window frame* between a pill-sized and a caption-sized window while the content stayed `.fixedSize()`. Probed behaviour of that combination: SwiftUI pins overflowing fixed-size content to the **top-leading** of its container, so mid-transition the visible slice was a cropped corner of the caption tracking the moving window — which read as the pill sliding diagonally up the screen. The window is now sized once per state and never animated; the morph happens entirely inside it. Because the window is set instantly to the caption footprint *before* the shell grows and only returns to pill size *after* it has shrunk, the shell is never clipped. Measured after the change (1440×900, Dock 58pt): resting window `112×82 @ x=664 y=38`, expanded `644×178 @ x=664… y=38` — identical bottom edge and identical horizontal centre, so the capsule's anchored point does not move at all.

**Amended 1.25.1 (Dock)** — Following the Dock is not detectable, so it was replaced with reserving it. Measured with **Automatically hide and show the Dock** on: `visibleFrame` reports `(0, 0, 1440, 870)` — a bottom reserve of 0, i.e. as if the Dock were absent — and it does **not** change when the Dock reveals itself. `didChangeScreenParametersNotification` does not fire either, and `CGWindowListCopyWindowInfo` returns no Dock windows without Screen Recording permission. A pill anchored to the raw frame therefore sat where the Dock appears and was covered the moment the user reached for it. When auto-hide is on, `DockReserve.visibleFrame` now reserves the Dock's configured band (tilesize, magnification, orientation, read from `com.apple.dock`) instead.

**Amended 1.25.2** — The caption came out dead to the mouse, its two buttons crushed into slivers. Three compounding faults, all found by measuring rather than reading:

1. **`NSHostingView` owns the window size.** It imposes its content's *minimum* size on a window (default `sizingOptions`), so every `setFrame` smaller than the caption was silently overridden — measured: `setFrame(100×70)` became `260×99`. The window therefore never matched the capsule drawn inside it, which is exactly what the user saw. Fixed with `hosting.sizingOptions = [.intrinsicContentSize]`: the intrinsic size still backs `fittingSize`, while the window size is ours again. (`[]` also hands the window back but zeroes `fittingSize`.)
2. **Preferences out of a `GeometryReader` background never reached the view.** The capsule's target size was measured that way; it fired exactly once with `0×0` and never again, even while the hosting view resized 112×82 → 644×178 — true for the caption reader *and* a root reader. The capsule therefore stayed pill-sized while the window was caption-sized. Geometry now comes from `GeometryReader`s used as real containers (mask/background/overlay all receive the primary's size), and the window size from `fittingSize`.
3. **A filled shape in the gesture overlay covered the transcript**, dimming the text to 37/255. The hit area now draws nothing and only sets `contentShape`.

Also fixed: an oversized layout inside a smaller window is *centred*, not aligned to the bottom, so the resting pill sat 12pt low — resting on the Dock rather than above it. The layout is pinned to the pill's own footprint while resting.

**Verification** — `swift build` PASS; `swift test` PASS (319 tests, 0 failures) including 7 `DockReserveTests` and 10 `PillAnchorPolicyTests`. `TYPESTER_DEMO=pill TYPESTER_PILL_MODE=collapsed|live|hover TYPESTER_SNAPSHOT=…` now renders real PNGs: the snapshot path builds a non-layer-backed `NSHostingView` offscreen, which `cacheDisplay` actually draws (the live window renders through layers and comes out blank without a WindowServer session). `TYPESTER_FORCE_HOVER=1` forces the hover actions for a render. Measured from those PNGs: resting capsule 42×14pt and expanded 357×40pt, each with its **bottom edge 30pt above the window's bottom** — the same anchor — and the window bottom edge identical in both states (`y=40`), with the transcript at 244/255 and `Stop`/`Cancel` rendered legibly. Morph smoothness and Dock clearance while the app is in use remain residual manual checks; screen capture is not permitted in this environment.

**Amended 1.25.3** — The hover actions were unclickable and their labels truncated to “…”. The actions were rendered *under* `capsuleHitArea`, whose tap gesture consumed every click, and they were sized to the caption content rather than to the capsule, so the labels had less width than they needed. The actions are now an overlay applied **after** the hit area (topmost), the AppKit capsule shell is `allowsHitTesting(false)` so it can never take mouse events, and the buttons are icon-only. While they show, the capsule pulls in to `actionsCapsule` (122×36) so the bar is balanced around them — while the *hit area* deliberately keeps the full caption footprint, since a hit area that shrank with the capsule would leave the pointer outside it and flicker the hover on and off.

**Amended 1.25.4** — The actions still flickered. Cause: **two** hit-testable layers. Making the actions hit-testable as real `Button`s took the hover away from the capsule surface underneath the instant they appeared, which set `isHovering = false`, which hid them — a loop. The capsule is now a *single* interactive surface: hover lives there, the actions are inert drawings, and a tap is routed by point via `SpatialTapGesture` against `PillActionsLayout.actionRects` — the same rects the visuals are positioned with, unit-tested in `PillActionsLayoutTests` (even insets, no overlap, membership at centres, and nil in the gap/margins). Also removed the shrink-on-hover: the bar keeps its size and the actions fill it, which is both what was asked for and one fewer thing changing under the pointer. Verified by measuring the render: the drawn icon centres land at 121.5pt and 294.5pt against the rects' 122.25pt and 294.75pt.

**Amended 1.25.5** — Clicking the HUD made Typester frontmost, which cost the target field its caret and made the transcript attribute itself to Typester. Focus stealing is two problems, not one: a window becoming *key*, and its app becoming *active*. `canBecomeKey = false` only fixes the first — clicking any window still activates its app. The HUD is now a `DictationHUDPanel: NSPanel` with the `.nonactivatingPanel` style mask (which is what lets it receive clicks without activating the app), `canBecomeKey`/`canBecomeMain` false, and `hidesOnDeactivate = false` — a panel hides itself whenever its app deactivates, and a non-activating panel's app is deactivated by design, so without that line it only works while Typester happens to be frontmost. The elevated level and `.canJoinAllSpaces`/`.fullScreenAuxiliary` behavior are unchanged. `AppDelegate` logs the resulting configuration (`nonactivatingPanel=true canBecomeKey=false canBecomeMain=false hidesOnDeactivate=false level=26`), since a synthetic click cannot be delivered from a test binary without Accessibility permission.

**Amended 1.25.6 (Keychain prompts)** — Treating this as part of the same HUD work because the prompts fired from the same places. Every provider key was a computed property reading the Keychain per access (`SettingsStore.apiKey` et al), with **one item per provider**, so opening Settings read all five on appear (`SettingsView.onAppear`) plus again on every render of the key section, onboarding re-read on every provider switch (`loadApiKeyForProvider`), and every dictation start read one (`hasAPIKeyForCurrentProvider`). Each read raises the login-password prompt whenever macOS cannot match the item's ACL to the running build — measured here: the test process itself took 11.8s on a legacy item until the read was removed, i.e. it really did prompt. Now: one item holding a JSON `APIKeyPayload`, cached for the process, and `hasAPIKey(for:)` answered from a `UserDefaults` account list so the UI never reads a secret. Existing items are folded in once by `migrateAPIKeyStorageIfNeeded()`, called explicitly from the app rather than from `load()` so a test process cannot hit the real Keychain. The key fields no longer display the stored value (Save/Remove instead of prefill), which is what made the reads unnecessary.

**Amended 1.25.7** — 1.25.6 made every stored key look empty. The keys were never lost — they were sitting in the new `api-keys` item the whole time — but the app could not see them, for two reasons. `SecItemCopyMatching`'s status was discarded and every failure became `nil`, so a read macOS *refused* was indistinguishable from “no key here”, and the migration then marked itself done and never retried. And the payload could exist while `configuredProviders` stayed empty, which is what the UI reads. Fixed by keeping the outcome (`value`/`missing`/`unavailable`), retrying while any read is refused, deleting only accounts actually read, reconciling `configuredProviders` from the payload on every load, and rewriting the payload once so its ACL is created by this build — replacing an item is the only thing that stops the prompts for good. Root cause of the emptied keychain was mine, not the migration's: it ran from `load()`, tests call `load()`, and a `swift test` folded the user's items into the new payload and deleted the originals with the bookkeeping landing in the test bundle's defaults domain. It is now skipped under XCTest, and the decision is a pure, unit-tested `LegacyKeyMigration` whose tests cover the refused-read case explicitly.

**Amended 1.25.8** — 1.25.7 reconciled the keys at launch, and that read *blocked*: an item whose ACL does not authorise the build raises a dialog, so the app sat behind a prompt before finishing startup (observed: `SecurityAgent` up, `isActive` never reached, no bookkeeping written). Launch-time reads now run with `SecKeychainSetUserInteractionAllowed(false)`, which returns `errSecInteractionNotAllowed` (-25293) straight away; measured in isolation, an absent item still returns `errSecItemNotFound` (-25300), so "cannot read" and "not there" stay distinguishable without any dialog. A blocked read also had no exit: the configured list stayed empty, so dictation refused to start for want of a key and nothing would ever prompt again. Settings now reports the state and offers **Allow access to stored keys**, which re-reads with the prompt allowed and rewrites the payload so the item's ACL is created by this build.

**Amended 1.25.9** — The recovery path was the wrong way round: the user had to open Settings to find a button before macOS would ask. Now `shouldAutoPromptForKeychainAccess` fires the prompt shortly after launch (once, so it cannot nag), and starting dictation while blocked prompts too instead of opening Settings. The Settings button stays as a deliberate retry.

## [S1] Problem

1. **Two HUDs, one intent.** `FloatingDictationPill` and `SubtitleOverlay` were separate windows positioned independently (`visibleFrame.maxX - w - 28` / `visibleFrame.minY + 96` bottom-right vs `screen.frame.minY + 48` bottom-center). Starting dictation showed both, and the user had to look at two places.
2. **Hardcoded position.** The pill docked bottom-right at a fixed offset and, once sized, `layout()` only re-applied `setFrame` with the *preserved* origin — it never recomputed from the screen.
3. **Caption ignored the Dock.** `SubtitleOverlay` placed the capsule from `screen.frame.minY + 48`, the raw screen edge, so a pinned Dock overlapped it.
4. **The transition drifted.** After merging the two HUDs, expanding into the caption moved the visible content diagonally instead of growing in place (see the 1.25.1 amendment).
5. **A revealed Dock hid the pill** when auto-hide was on.
6. **Mouse-only dictation could not finish** — hovering the caption offered only Cancel, so completing a dictation still required the hotkey.

Requested behaviour: one small pill (no logo, no text, faint) floating above the Dock, centered, that morphs into the caption bar in place, with Stop/Cancel on hover and the resting edge configurable to top / left / right.

## [S2] Design

**Single HUD, single morph value.** `SubtitleOverlay` owns the only window. `SubtitleViewModel.morph: Double` (0…1) is the entire transition: `SubtitleView.capsuleSize` lerps between `restingCapsule` (44×24) and the *measured* caption size, and the corner radius, `shadowScale` and shell opacity interpolate on the same value. The caption's opacity ramps over the back 70% so the growth reads as an inflating capsule rather than text sprouting mid-way.

**Phases** — `.hidden` / `.collapsed` / `.visible` / `.dismissing`. The phase is lifecycle only; the visuals come from `morph`, so no view switches on it.

**Morph contract**
- The window is never animated. `show` sets it to the caption footprint up front, then `withAnimation` grows the shell into it; `hide` shrinks the shell first and only resizes the window once the morph has landed.
- `morph` reaches its target *instantly* (SwiftUI animates only the presentation), so a `needsCaptionWindow` flag — not `morph` — decides whether the window may be small. Deriving it from `morph` would shrink the window the moment a collapse starts and clip the shrinking shell.
- The caption content is `.fixedSize()` inside the shell's frame, so it keeps its natural layout and is cropped from the centre as the shell grows instead of reflowing.
- The shell is clipped to `RoundedRectangle(cornerRadius:)` (not a plain rect) so content cannot escape the rounded ends mid-growth.
- The content view reports its natural size through a `PreferenceKey`; the controller resizes the window from it, so the window is never narrower than the shell.
- `accessibilityDisplayReduceMotion` skips the animation and the deferred window resize.

**Position contract** (`PillAnchorPolicy.origin`)

```
bottom: x = visibleFrame.midX - capsuleWidth/2 - insets.left
        y = visibleFrame.minY + gap - insets.bottom
top:    x as bottom, y = visibleFrame.maxY - windowHeight - gap + insets.top
left:   x = visibleFrame.minX + gap - insets.left
        y = visibleFrame.midY - capsuleHeight/2 - insets.bottom
right:  x = visibleFrame.maxX - windowWidth - gap + insets.right
        y as left
```

- The **capsule** is centered, not the window: the shadow bleed is asymmetric, so centering the window would offset the pill along the edge.
- One inset set (26/34/32/34) is used for **both** states, so the window's bottom edge and horizontal centre are identical whether resting or expanded — the precondition that lets the morph grow in place.
- Insets are removed from the anchor, so the capsule keeps an identical `gap` from the effective visible edge in every state.
- Result is clamped so the capsule cannot leave `screenFrame`.

**Dock contract** (`DockReserve`)

- `visibleFrame` is used rather than `frame`, so the menu bar and a *pinned* Dock are respected.
- When `com.apple.dock` reports `autohide`, the Dock's configured band (`max(tilesize, magnification ? largesize : tilesize) + 24` chrome) is reserved on its side (`orientation`), because macOS reports a hidden auto-hiding Dock as absent and never updates on reveal. The reserve is also taken as a floor against the reported inset, so a pinned Dock is never under-reserved.
- `DockPreferencesReader` reads the preferences; `didChangeScreenParametersNotification` still covers resize / move / auto-hide toggles (verified: it fires for a Dock *size* change).

**Hover actions** — while expanded, hovering swaps the caption body for **Stop** (`stopRecording()` → finalize and paste) and **Cancel** (`cancelActiveTranscription()` → discard). `captionMinWidth` keeps room for both labels. The resting pill has no actions; a click on it toggles dictation.

**Resting appearance** — a plain capsule at 34% opacity, no logo and no text, lifting to 90% on hover. Hit area is capped at the capsule, not the shadow bleed.

**Testing boundary** — Anchor and Dock-reserve maths are pure and covered by `PillAnchorPolicyTests` / `DockReserveTests`. Window sizing, morph smoothness and Dock clearance are residual manual checks.

## [S3] Out of scope

- Drag-to-move / snap-to-edge dock targets (the requested model is a centered, edge-pinned pill chosen in Settings).
- Multi-monitor anchoring beyond `NSScreen.main` (matches the existing HUD policy).
- Detecting an auto-hidden Dock revealing itself — established as impossible without Screen Recording (see the 1.25.1 amendment).
- Changing transcript rendering, provider behaviour, or the Voice glow.

## Tasks

- [x] T1: `PillEdge` + `PillInsets` + `PillAnchorPolicy` in TypesterLogic; `pillEdge` setting with persistence — acceptance: policy returns Dock-aware origins for all four edges and clamps on screen (covers: S2)
- [x] T2: `PillAnchorPolicyTests` — pinned vs hidden Dock, side-Dock inset, menu-bar clearance, vertical centering, morph edge stability, clamp, degenerate insets
- [x] T3: `SubtitleOverlay` `.collapsed` phase + `collapse()` + `refreshFloatingPresence()` + Dock-aware `repositionWindow` — acceptance: UI target compiles
- [x] T4: `AppDelegate` rewiring; delete `FloatingDictationPill` — acceptance: no `FloatingDictationPill` references remain
- [x] T5: Settings Position picker + `TYPESTER_PILL_MODE=collapsed` snapshot hook
- [x] T6: Build + full test suite — `swift build` and `swift test` pass
- [x] T7: Replace the window-frame animation with a single SwiftUI morph value — acceptance: resting and expanded windows share a bottom edge and horizontal centre (verified from the reposition log); caption measured via preference (covers: S1.4)
- [x] T8: `DockReserve` / `DockPreferences` + reader — acceptance: with auto-hide on, the capsule clears the Dock's configured band; `DockReserveTests` pass (covers: S1.5)
- [x] T9: Stop + Cancel hover actions, faint logo-free resting pill — acceptance: `onStop` wired to `stopRecording()`, `onCancel` to `cancelActiveTranscription()` (covers: S1.6)
- [x] T10: Give the window back to the controller (`sizingOptions = [.intrinsicContentSize]`), derive the capsule from `GeometryReader` containers, drop the preference measurement, and make the hit area draw nothing — acceptance: the window matches the shell in both states and the hover actions are legible and clickable (covers: S1.4 regression)
- [x] T11: Pin the view's layout to the pill footprint while resting — acceptance: the rendered capsule's bottom edge is 30pt above the window's bottom in both states (covers: S1.5 regression, measured from the snapshot PNGs)
