---
feature: pill-follows-active-space
status: in-progress
updated: 2026-09-11
branch: fix/pill-follows-active-space
commits: 555212e..<head>
---

# Pill Follows Active Space

## Report

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
