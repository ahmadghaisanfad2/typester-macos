# Typester

[![Tests](https://github.com/nickustinov/typester-macos/actions/workflows/tests.yml/badge.svg)](https://github.com/nickustinov/typester-macos/actions/workflows/tests.yml)

A lightweight macOS menu bar app for speech-to-text dictation using [Soniox](https://soniox.com), [Deepgram](https://deepgram.com), or [OpenAI](https://platform.openai.com).

![Demo](Assets/demo.gif)

## What it does

Typester lives in your menu bar and lets you dictate text directly into any application. Hold a key to speak or toggle recording with a hotkey — your words are automatically typed into the active text field.

**Bring Your Own Key (BYOK)** — Typester connects directly to your chosen speech-to-text provider using your own API key. No middleman, no subscription, no data collection. You pay only for what you use directly to the provider.

Features:
- **Multiple providers** — Choose Soniox, Deepgram, or OpenAI for speech recognition
- **Press-to-speak** — Hold a key to dictate, release to paste (default mode, configurable: Fn, Left/Right ⌘, Left/Right ⌥)
- **Toggle mode** — Or use a global hotkey to start/stop recording (triple-tap ⌘⌘⌘ or custom shortcut)
- **Cancel with Esc** — Press Escape while dictating to discard the transcript without pasting
- **Real-time transcription** — Streaming APIs (Soniox `stt-rt-v5`, Deepgram `nova-3`, OpenAI `gpt-live-transcribe` and related models)
- **OpenAI model picker** — Select `gpt-live-transcribe`, `gpt-transcribe`, `gpt-4o-transcribe`, or `gpt-4o-mini-transcribe`
- **Multilingual** — Soniox/OpenAI: language hints; Deepgram: auto-detects with multilingual model
- **Microphone selection** — Choose your preferred input device from the menu
- **Custom dictionary** — Add domain-specific words, names, or technical terms (Soniox context / OpenAI keywords)
- **Automatic dictionary learning** — Correct a recently pasted transcript and Typester saves safe word/phrase corrections locally for future dictation
- **Teachable corrections** — Use **Teach last transcript…** in the menu to save wrong→right pairs; they replace before paste and feed provider hints
- **Domain / topic context** — Optional context fields in Settings for better domain bias
- **Check for Updates** — Compare against your fork’s GitHub Releases and download the latest DMG
- **Auto-paste** — Transcribed text is automatically pasted into the active application
- **Clipboard keeping** — Optional: keep each transcript on your clipboard so you can ⌘V it again when no text field was focused
- **Secure API key storage** — Your API keys are stored in the macOS Keychain
- **Launch at login** — Start automatically when you log in

## Requirements

- macOS 13 or later
- API key from [Soniox](https://soniox.com), [Deepgram](https://console.deepgram.com), or [OpenAI](https://platform.openai.com/api-keys)

## Permissions

Typester requires two macOS permissions:

- **Microphone** — needed to capture your voice for transcription. Without this, the app cannot hear you speak.

- **Accessibility** — needed to paste transcribed text into other applications. Typester simulates ⌘V to insert text at your cursor position. Without this, transcription works but text won't be pasted automatically.

## Installation

1. Download `Typester-x.x.x.dmg` from Releases
2. Open the DMG and drag Typester to Applications
3. Launch from Applications — it appears as an icon in your menu bar
4. Follow the setup wizard to choose your provider and enter your API key
5. Grant Microphone and Accessibility permissions when prompted

### Updating

From 1.15.0 onward, Typester updates itself: menu bar icon → **Check for Updates…**
(or Settings → Check for Updates). The update downloads, installs in place, and
relaunches.

**One-time migration from 1.15.2 or earlier:** Typester 1.16 introduced a stable
signing identity, so the old Keychain and Accessibility authorization does not
transfer automatically. When Keychain asks about your existing API key, enter
your **Mac login password** and click **Always Allow** (not Allow Once). Then open
**System Settings → Privacy & Security → Accessibility**, remove the old Typester
entry, add `/Applications/Typester.app`, turn it on, and relaunch Typester.
Microphone permission may also need to be confirmed. After both migration steps,
future releases signed with the same stable identity keep these grants.

## Usage

**Press-to-speak mode (default):**
1. Hold the configured key (Fn by default — changeable in Settings)
2. Speak — your words are transcribed in real-time
3. Release the key — text is pasted into the active field

**Toggle mode:**
1. Press triple-Cmd (⌘⌘⌘) or your custom hotkey to start
2. Speak — your words appear in the active text field
3. Press the hotkey again to stop

**Cancel:** Press **Esc** while dictating to discard the current transcript without pasting.

You can switch between modes in Settings. Use the menu bar to select your microphone, preferred languages (Soniox/OpenAI), teach corrections from the last transcript, or access settings.

## Building from source

**Debug build (requires Xcode for SwiftUI UI target):**
```bash
swift build
swift run
```

**Logic-only build (Command Line Tools):**
```bash
swift build --target TypesterCore --build-system native
swift run dictionary-smoke --build-system native
```

**Release build (universal binary + DMG):**
```bash
./scripts/build-release.sh
```

This creates a universal binary (arm64 + x86_64), signs it if you have a Developer ID certificate, and packages it into a DMG at `dist/Typester-x.x.x.dmg`.

**Publish a GitHub Release locally (no Actions minutes):**
```bash
./scripts/publish-release.sh
```

This builds the DMG, then creates (or updates) a `vX.Y.Z` release on your fork with the DMG attached. In Settings, **Check for Updates** compares the running app to that release and can download the DMG.

Requirements for building:
- Swift 5.9 or later
- Xcode Command Line Tools (full Xcode needed for the SwiftUI UI target)
- `gh` CLI authenticated to your fork (for publish)

## Development

**Debug logging:**
```bash
TYPESTER_DEBUG=1 swift run
```

**Reset app for fresh testing:**
```bash
# Reset permissions
tccutil reset Microphone com.typester.app
tccutil reset Accessibility com.typester.app

# Clear saved settings
defaults delete com.typester.app

# Remove API keys from keychain
security delete-generic-password -s "com.typester.api" -a "soniox-api-key"
security delete-generic-password -s "com.typester.api" -a "deepgram-api-key"
security delete-generic-password -s "com.typester.api" -a "openai-api-key"
```

## Architecture

```
Sources/
├── main.swift                      # App entry point
├── DictionarySmoke/                # CLI smoke checks (no XCTest required)
├── TypesterLogic/                  # Non-UI core (builds with Command Line Tools)
│   ├── Models.swift                # Data models + DictionaryHelpers
│   ├── SettingsStore.swift         # UserDefaults + Keychain persistence
│   ├── HotkeyManager.swift         # Global hotkey registration (Carbon Events)
│   ├── PressKeyMonitor.swift       # Press-to-speak key detection (CGEventTap)
│   ├── AudioRecorder.swift         # AVAudioEngine microphone capture
│   ├── STTProvider.swift           # Speech-to-text provider protocol
│   ├── STTClientBase.swift         # Base class for STT WebSocket clients
│   ├── SonioxClient.swift          # Soniox WebSocket streaming (stt-rt-v5)
│   ├── DeepgramClient.swift        # Deepgram WebSocket streaming
│   ├── OpenAIClient.swift          # OpenAI Realtime transcription
│   ├── TranscriptFormatter.swift   # Local punctuation / capitalization cleanup
│   ├── TextPaster.swift            # Clipboard + simulated Cmd+V paste
│   ├── UpdateChecker.swift         # GitHub Releases update check + DMG download
│   ├── KeyboardUtils.swift         # Key code to string conversion
│   ├── AssetLoader.swift           # Asset path finding and loading
│   └── Debug.swift                 # Debug logging utility
└── TypesterCore/                   # SwiftUI UI (needs Xcode / CI macOS image)
    ├── AppDelegate.swift           # Status bar, menu, recording control
    ├── TypesterTheme.swift         # Design tokens + shared components (Codex-style)
    ├── SettingsView.swift          # Sidebar-based settings interface
    ├── OnboardingView.swift        # First-run setup wizard
    ├── TeachDictionaryView.swift   # Teach wrong→right correction UI
    ├── SubtitleOverlay.swift       # Live subtitle overlay
    └── Exports.swift               # Re-exports TypesterCore logic

Tests/
├── ModelsTests.swift               # Model encoding/decoding tests
├── KeyboardUtilsTests.swift        # Keyboard utility tests
├── DictionaryHelpersTests.swift    # Correction / context helper tests
├── UpdateCheckerTests.swift        # Version compare + release parsing tests
├── TranscriptFormatterTests.swift  # Local transcript formatting tests
└── STTResponseParsingTests.swift   # STT response parsing tests
```

**Local build notes (Command Line Tools only):** macOS CLT may lack SwiftUI macro plugins and XCTest. Use:

```bash
swift build --target TypesterCore --build-system native
swift build --build-system native --product dictionary-smoke
.build/debug/dictionary-smoke
```

Full app UI build and `swift test` require Xcode (or GitHub Actions `macos-14`).
## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Soniox, Deepgram, or OpenAI. These are third-party services used for speech recognition.

## License

MIT License

Copyright (c) 2026 Nick Ustinov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
