---
feature: morphing-floating-pill
status: delivered
updated: 2026-09-23
branch: cursor/morphing-dock-aware-pill
---

# Morphing Floating Pill (Dock-aware)

## Report

**What was built** — The floating click pill and the live-transcript caption capsule were two independent borderless HUD windows driven in parallel by every dictation call site. They are now one HUD owned by `SubtitleOverlay`: a new `.collapsed` presentation phase rests as a small capsule (no logo, no text) and morphs into the existing caption bar (waveform + live transcript + Voice glow) when dictation starts, collapsing back when it stops. The morph animates the window frame alongside the SwiftUI crossfade, anchored to the same edge so the capsule grows out of the pill.

The resting position is derived, not hardcoded. A new pure-logic `PillAnchorPolicy` computes the window origin from `NSScreen.visibleFrame`, the configured `PillEdge`, and the shadow insets: the pill is centered along the edge and keeps a constant gap from the Dock / menu bar. `SubtitleOverlay` re-anchors on `NSApplication.didChangeScreenParametersNotification` (Dock hidden/shown/moved/resized, display change) plus the existing Space observer — notification-driven, no polling. `Settings → Floating pill → Position` selects Bottom (default) / Top / Left / Right.

`FloatingDictationPill` is deleted; its view model, drag, and window logic are gone rather than kept as a parallel path. Behaviour with **Show floating pill** off is unchanged (caption appears only while dictating), except that the caption now also clears the Dock, which it previously did not.

**Verification** — `swift build` PASS; `swift test` PASS (312 tests, 0 failures), including 10 new `PillAnchorPolicyTests`. Debug harness `TYPESTER_DEMO=pill TYPESTER_PILL_MODE=collapsed TYPESTER_SNAPSHOT=…` added and confirms the collapsed window measures 72×50pt (44×24 capsule + shadow bleed) against 232×120pt expanded, i.e. the resting pill stays small enough not to swallow clicks over the caption's area. AppKit rendering, Dock re-anchoring, and morph smoothness remain residual manual checks (the snapshot harness renders blank without an attached WindowServer session).

## [S1] Problem

1. **Two HUDs, one intent.** `FloatingDictationPill` and `SubtitleOverlay` were separate windows positioned independently (`visibleFrame.maxX - w - 28` / `visibleFrame.minY + 96` bottom-right vs `screen.frame.minY + 48` bottom-center). Starting dictation showed both, and the user had to look at two places.
2. **Hardcoded position.** The pill docked bottom-right at a fixed offset and, once sized, `layout()` only re-applied `setFrame` with the *preserved* origin — it never recomputed from the screen. Hiding the Dock did not move it; there was no way to put it elsewhere.
3. **Caption ignored the Dock.** `SubtitleOverlay` placed the capsule from `screen.frame.minY + 48`, the raw screen edge, so a pinned Dock overlapped it.

Requested behaviour: one small pill (no logo or text) floating above the Dock, centered, that morphs into the caption bar on click or hotkey, with the resting edge configurable to top / left / right.

## [S2] Design

**Single HUD.** `SubtitlePresentationPhase` gains `.collapsed`. `SubtitleOverlay` owns the only window; `FloatingDictationPill` is removed. `AppDelegate` drives one object: `show` / `showProcessing` / `hide` / `updateLevel`, with `onToggle` wired to `toggleRecording`.

**Presence contract**
- `showFloatingPill == true` → the window is always on screen, resting as the pill while idle.
- `showFloatingPill == false` → unchanged legacy behaviour: hidden while idle, caption only during dictation.

**Phase contract**
- `collapse()` clears transcript/glow state and sets `.collapsed`; `hide()` collapses instead of dismissing when the pill is enabled.
- The dismissal work item re-checks `showFloatingPill`, so enabling the pill while a caption is fading rests as a pill rather than ordering the window away.
- `shouldReassert` remains `phase != .hidden`, so the resting pill keeps Space membership.

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

- `visibleFrame` (not `frame`) is what makes it Dock-aware in every direction.
- The **capsule** is centered, not the window: the shadow bleed is asymmetric (deeper below), so centering the window would offset the pill along the edge.
- Insets are passed in per phase (collapsed 10/14/16/14, expanded 36/44/44/44) so the anchored capsule edge keeps an identical `gap` across the morph instead of shifting by the inset delta.
- Result is clamped so the capsule cannot leave `screenFrame`.

**Morph contract**
- Borderless windows are not content-sized, so `repositionWindow(animated:)` re-fits the frame per phase; the collapsed frame must stay small or the resting pill would swallow clicks across the caption's transparent area.
- The morph animates the window frame (`NSAnimationContext`, 0.26s ease) in parallel with a SwiftUI opacity crossfade between phases; `accessibilityDisplayReduceMotion` falls back to an instant frame.
- Ordering matters: `SpaceFollowingWindow.reaffirmWithTransitionPasses` repositions on its immediate and delayed passes, so the morph runs first and the passes are handed an *animated* reposition. Passing `animated: false` snapped the frame to its final size and cut the morph on the first pass.
- `presenting` and `visible` share a layout size (`scaleEffect`/`offset` are visual only), so the post-`present()` re-fit is skipped during a morph.

**Testing boundary** — Anchor math is pure and lives in `TypesterLogic` behind `PillAnchorPolicyTests`. AppKit window animation, Dock re-anchoring, and Space membership are residual manual checks.

## [S3] Out of scope

- Drag-to-move / snap-to-edge dock targets (the requested model is a centered, edge-pinned pill chosen in Settings).
- Multi-monitor anchoring beyond `NSScreen.main` (matches the existing HUD policy).
- Changing transcript rendering, provider behaviour, or the Voice glow.

## Tasks

- [x] T1: `PillEdge` + `PillInsets` + `PillAnchorPolicy` in TypesterLogic; `pillEdge` setting with persistence — acceptance: policy returns Dock-aware origins for all four edges and clamps on screen (covers: S2)
- [x] T2: `PillAnchorPolicyTests` — acceptance: pinned vs hidden Dock, left/right Dock inset, menu-bar clearance, vertical centering, morph edge stability, clamp, degenerate insets
- [x] T3: `SubtitleOverlay` `.collapsed` phase + `collapse()` + morph view + `refreshFloatingPresence()` + screen-parameter observer + Dock-aware `repositionWindow` — acceptance: UI target compiles; collapsed and expanded frames chosen per phase (covers: S2)
- [x] T4: `AppDelegate` rewiring; delete `FloatingDictationPill` — acceptance: no `FloatingDictationPill` references remain; one overlay drives pill and caption (covers: S2)
- [x] T5: Settings Position picker + `TYPESTER_PILL_MODE=collapsed` snapshot hook — acceptance: picker binding re-anchors the pill; snapshot renders the resting pill
- [x] T6: Build + full test suite — acceptance: `swift build` and `swift test` pass (312 tests)
