---
feature: onboarding-accessibility-crash
status: delivered
updated: 2026-09-18
branch: fix/onboarding-accessibility-crash
commits: e302398..82ae3e3
---

# Onboarding Accessibility Crash + Single-Window Grant UX

## Report

**What was built** — Typester 1.22.0 aborted in onboarding step 3 because `SpaceFollowingWindow.configure` assigned `NSWindow.CollectionBehavior` flags AppKit rejects: `.moveToActiveSpace` combined with `.canJoinAllSpaces` and `.stationary`. Crash reports showed `-[NSWindow _validateCollectionBehavior:]` from `AccessibilityDragHelper.show()`. HUD collection behavior now derives from `SpaceFollowPolicy.hudFlags` = `[.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]`.

The floating `AccessibilityDragHelper` (second drag window beside onboarding/Settings/recovery) is gone. Grant UX is one Typester window + System Settings: in-window `DraggableAppIconTile` remains the drag source; step 3 still opens the Accessibility pane automatically.

**Verification** — `swift build` PASS; `swift test` PASS (244 tests, 0 failures), including `SpaceFollowPolicyTests` (rejects the 1.22.0 flag set) and `AccessibilityGrantPresentationTests`. Independent review of `e302398..82ae3e3` approved all six acceptance criteria; no critical findings. Residual manual check: launch onboarding to Accessibility step on macOS — no crash, Settings opens, only one drag tile.

**Journey log**
1. 1.22.0 space-follow added `.moveToActiveSpace` on top of older `.canJoinAllSpaces` + `.stationary`; AppKit treats those pairs as mutually exclusive and aborts.
2. Onboarding was the first crash site because it auto-showed a borderless helper window that shared `SpaceFollowingWindow.configure` with caption/pill/toast HUDs.
3. Single-source-of-truth: UI maps `SpaceFollowPolicy.hudFlags`; tests fail if the invalid combo returns.
4. User preference: never present a second floating drag helper — Settings/recovery/open-settings paths use the same single-window rule.
5. SwiftPM names are inverted vs folders: module `TypesterCore` = `Sources/TypesterLogic`; folder `Sources/TypesterCore` = `TypesterUI`.

## [S1] Problem

Typester 1.22.0 crashes with SIGABRT when onboarding step 3 tries to help the user grant Accessibility.

Crash reports (`Typester-2026-09-18-173036.ips`, `Typester-2026-09-18-173048.ips`, app 1.22.0, macOS 27.0) share the same last exception:

1. `AccessibilityDragHelper.show(autoHideSeconds:)` creates a borderless `NSWindow`
2. `SpaceFollowingWindow.configure(_:)` assigns `window.collectionBehavior`
3. `-[NSWindow _validateCollectionBehavior:]` throws → `abort()`

Root cause: 1.22.0 space-follow work set

```swift
[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
```

AppKit rejects mutually exclusive pairs:

- `.canJoinAllSpaces` + `.moveToActiveSpace`
- `.stationary` + `.moveToActiveSpace`

The same `configure` path is used by caption overlay, floating pill, learning toast, and the accessibility helper, so any of those windows can crash once shown after 1.22.0. Onboarding hits it first because step 3 auto-calls `AccessibilityDragHelper.shared.show()`.

Second user-visible defect: onboarding already embeds a `DraggableAppIconTile` in the accessibility step, and `AccessibilityDragHelper` opens a **second** floating window with another drag tile. Settings and Permission Recovery do the same pairing. User wants **one** Typester window for drag-to-grant — not two.

## [S2] Design

### S2.1 Valid Space-follow flags

`SpaceFollowingWindow` keeps HUDs on the active Space via `orderFrontRegardless()` + `.moveToActiveSpace`, not via `.canJoinAllSpaces`.

**HUD collection behavior (single source of truth):**

```swift
[.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
```

- Drop `.canJoinAllSpaces` and `.stationary` — both conflict with `.moveToActiveSpace` under AppKit validation on current macOS.
- Keep elevated `hudWindowLevel` and multi-pass `reaffirmWithTransitionPasses`.
- `configure` and `reaffirm` must use the same valid set.

**Pure policy (testable, `TypesterLogic`):**

`SpaceFollowPolicy` enumerates flag cases, exposes `hudFlags`, and `isValid(_:)` which rejects:

- `moveToActiveSpace` together with `canJoinAllSpaces`
- `moveToActiveSpace` together with `stationary`

`SpaceFollowingWindow` derives AppKit `collectionBehavior` from `SpaceFollowPolicy.hudFlags` so UI cannot reintroduce the crash combo.

### S2.2 Single-window Accessibility grant UX

Grant UX is **one Typester window + System Settings**.

| Surface | Drag tile | Open Settings | Floating helper |
| --- | --- | --- | --- |
| Onboarding step 3 | yes (in-window) | yes | **no** |
| Settings → Permissions | yes (in-window) | yes | **no** |
| Permission recovery panel | yes (in-window) | yes | **no** |
| Dictation blocked (recovery panel path) | recovery panel only | via recovery | **no** |

**Contracts:**

1. Remove every `AccessibilityDragHelper.shared.show()` call site (`OnboardingView`, `SettingsView`, `PermissionRecoveryView`, `AppDelegate.ensureAccessibilityForDictation`).
2. Delete `AccessibilityDragHelper.swift` (class + view).
3. Onboarding step 3 still auto-opens the system prompt and Privacy → Accessibility pane; it does **not** spawn a second Typester window.
4. In-window `DraggableAppIconTile` remains the drag source; pasteboard types stay Finder-like (`public.file-url` + `NSFilenamesPboardType`).
5. Pure policy: `AccessibilityGrantPresentation.presentsFloatingDragHelper == false` documents the product rule in logic tests.
6. README Shotbase-style bullet describes single-window grant, not a floating helper over Settings.

### S2.3 Regression coverage

- `SpaceFollowPolicyTests`: old 1.22.0 flag set is invalid; `hudFlags` is valid; each mutually exclusive pair is rejected.
- `AccessibilityGrantPresentationTests`: floating helper is not part of grant UX.
- Existing `PermissionSetupTests` / `PermissionRecoveryTests` remain green (decision logic unchanged).

AppKit cannot be fully exercised in unit tests; residual manual check is: launch onboarding to step 3 on macOS → app does not crash, System Settings opens, only the onboarding window shows a drag tile.

## [S3] Out of Scope

- Changing STT / voice-focus / voice-glow behavior.
- Replacing Accessibility grant with a non-drag flow (plus button / SMJobBless / etc.).
- Fixing unrelated AppKit issues on macOS 27.
- Shipping a new app version / DMG (separate release task after merge).

## Tasks

- [x] T1: Add `SpaceFollowPolicy` in TypesterLogic with valid HUD flags + mutual-exclusion validation — acceptance: unit tests pass; policy rejects the 1.22.0 combo and accepts `hudFlags` (covers: S2.1)
- [x] T2: Point `SpaceFollowingWindow.configure`/`reaffirm` at `SpaceFollowPolicy.hudFlags` — acceptance: UI target compiles; collectionBehavior no longer includes `.canJoinAllSpaces` or `.stationary` with `.moveToActiveSpace` (covers: S2.1; depends: T1)
- [x] T3: Remove floating Accessibility drag helper from grant UX — acceptance: no `AccessibilityDragHelper.shared.show()` call sites remain; `AccessibilityDragHelper.swift` deleted; onboarding/settings/recovery keep in-window tiles only (covers: S2.2)
- [x] T4: Add presentation policy + tests and update README wording — acceptance: new tests pass; README describes single-window grant (covers: S2.2, S2.3; depends: T3)
- [x] T5: Full package verification — acceptance: `swift build` and `swift test` pass in the worktree (covers: S2.3; depends: T1–T4)
