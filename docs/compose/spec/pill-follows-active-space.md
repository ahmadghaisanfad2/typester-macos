---
feature: pill-follows-active-space
status: delivered
updated: 2026-09-11
branch: fix/pill-follows-active-space
commits: 555212e..643b571
---

# Pill Follows Active Space

## Report

**What was built** — The caption pill and learning HUD toast now stay on every macOS Space while visible. Overlay windows use a shared `SpaceFollowingWindow` helper: `.statusBar` level, `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, immovable, and presented with `orderFrontRegardless()`. While shown, both windows re-assert Space membership and re-center on `NSScreen.main` when `NSWorkspace.activeSpaceDidChangeNotification` fires; observers are removed on hide. LearningHUD dismiss completions are generation-guarded so a rapid re-show cannot be ordered out by a stale fade.

**Verification** — `swift build --target TypesterUI` PASS; `swift test` PASS (175 tests, 0 failures). Independent review of `555212e..d8c6684` requested changes (LearningHUD dismiss race, missing re-center); fixes landed in `643b571` and re-review approved.

**Journey log**
1. Existing `.floating` + `.canJoinAllSpaces` + `orderFront(nil)` was insufficient for this `LSUIElement` app — AppKit can pin the window to the first Space.
2. Raised level to `.statusBar` and switched to `orderFrontRegardless()`; added Space-change reassert rather than relying on one-shot flags.
3. Review found LearningHUD could kill a newly shown toast from a stale dismiss completion; fixed with `presentationID` generation checks.
4. LearningHUD was also missing re-center on Space change; extracted `reposition(window:hosting:)`.
5. AppKit HUD window config is not covered by the logic test target; residual manual check is switching Spaces while dictating.

## [S1] Problem

When the user switches macOS desktops (Spaces) while dictation is active, the caption pill stays on Desktop 1 instead of remaining visible on the newly focused Space. The user must switch back to see live transcript / processing state.

Reproduction:
1. Start Typester and begin dictation on Desktop 1 so the pill is visible.
2. Move to Desktop 2 or Desktop 3 (Mission Control / trackpad swipe).
3. Expected: pill remains visible at the bottom of the active Space.
4. Actual: pill stays on Desktop 1.

## [S2] Design

The caption pill is a borderless `NSWindow` created in `SubtitleOverlay.ensureWindow()`. It already sets `collectionBehavior = [.canJoinAllSpaces, .stationary]` and `level = .floating`, then uses `orderFront(nil)`. That combination is unreliable for an `LSUIElement` menu-bar app: AppKit can pin the window to the Space where it was first ordered front, and `orderFront` does not force presentation when the app is not active.

**Chosen behavior**

- The pill (and the learning HUD toast, same class of floating overlay) must remain visible on every Space, including full-screen Spaces, for as long as it is on screen.
- No focus steal: the target app keeps keyboard focus.

**Contracts**

1. Configure overlay windows with Space-sticky HUD behavior:
   - `level = .statusBar` (above `.floating`, which can stick to one Space)
   - `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`
   - `isMovable = false`, `hidesOnDeactivate = false`
2. Present with `orderFrontRegardless()` so a non-activating menu-bar app can show the window on the current Space.
3. While a pill/learning window is visible, observe `NSWorkspace.activeSpaceDidChangeNotification` and re-apply collection behavior + `orderFrontRegardless()`, then re-center on `NSScreen.main` (the screen that currently has focus).
4. Remove the Space observer when the window is ordered out so the object does not leak observers across sessions.

Shared helper `SpaceFollowingWindow.configure(_:)` lives in the UI target so both overlays use identical flags.

## [S3] Out of Scope

- Multi-monitor coordinate re-pinning beyond `NSScreen.main`.
- Changing pill layout, animation, or stream-preview content.
- Settings/onboarding windows (those are user-managed and should not join all Spaces).

## Tasks

- [x] T1: Add `SpaceFollowingWindow.configure` helper — acceptance: helper sets level/collectionBehavior/movability as in S2 and is used by both overlays (covers: S2)
- [x] T2: Fix `SubtitleOverlay` presentation and Space reassert — acceptance: `show()` uses `orderFrontRegardless`, Space-change reassert while visible, observer removed on hide (covers: S2; depends: T1)
- [x] T3: Fix `LearningHUD` presentation and Space reassert — acceptance: same configure + reassert pattern as pill (covers: S2; depends: T1)
- [x] T4: Build UI target and run logic tests — acceptance: `swift build` for typester target succeeds; `swift test` passes (covers: S2)
