# AGENTS.md

## Cursor Cloud specific instructions

Typester is a **macOS-only** menu bar app (SwiftPM package, `swift-tools-version:5.9`, platform `.macOS(.v13)`). Almost every source file imports Apple-only frameworks (`Cocoa`, `AppKit`, `SwiftUI`, `Carbon.HIToolbox`, `AVFoundation`, `CoreAudio`, `ServiceManagement`, `Security`, `ApplicationServices`), and the test target depends on that same macOS-only module.

### The app cannot be built, tested, or run on the Linux Cloud Agent VM

This is a platform limitation, not a missing-setup problem:

- `swift build` and `swift test` fail on Linux with `error: no such module 'Cocoa'` (and the other Apple frameworks). There is no Linux stub for these frameworks.
- Even the "networking-only" files (`STTClientBase.swift`, `SonioxClient.swift`, `DeepgramClient.swift`) do not compile unmodified on Linux, because `URLSession`/`URLRequest` live in `FoundationNetworking` there, while the sources only `import Foundation` (the macOS behavior).
- Building/running/testing must be done on **macOS with the Xcode Command Line Tools** (Swift 5.9+). CI runs on `macos-14` (`.github/workflows/tests.yml`) and only runs `swift build` + `swift test`.

### Standard commands (macOS only — see `README.md`)

- Debug build/run: `swift build`, `swift run`
- Debug logging: `TYPESTER_DEBUG=1 swift run`
- Tests: `swift test`
- Release (universal binary + DMG): `./scripts/build-release.sh`

There are **no external SwiftPM dependencies** (`Package.swift` `dependencies:` is empty), so no dependency-install step is needed even on macOS — `swift build` resolves everything.

### What is available on this Linux VM

- No lint tooling is configured in the repo (no `.swiftlint.yml` / swift-format config); "lint" is not a separate step for this project.
- A Swift 6.1 toolchain is installed at `/opt/swift` and symlinked into `/usr/local/bin` (`swift`, `swiftc`, `swift-package`). On Linux it can only be used for **manifest inspection / lightweight syntax checks** (e.g. `swift package describe`, `swift package dump-package`) — it cannot compile or run the app or its tests. This toolchain lives in the VM snapshot, not in the startup update script.
