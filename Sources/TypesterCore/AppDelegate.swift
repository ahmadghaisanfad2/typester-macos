import Cocoa
import SwiftUI
import Carbon.HIToolbox
import AVFoundation
import CoreAudio
import TypesterCore

public class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var teachWindow: NSWindow?

    private let audioRecorder = AudioRecorder()
    private let textPaster = TextPaster()
    private let automaticCorrectionMonitor = AutomaticCorrectionMonitor()
    private let historyStore = TranscriptHistoryStore.shared
    private var sttProvider: STTProvider!
    private var lastTranscript = ""

    private func createSTTProvider() -> STTProvider {
        switch SettingsStore.shared.sttProvider {
        case .soniox:
            switch SettingsStore.shared.sonioxMode {
            case .realtime:
                return SonioxClient()
            case .async:
                return SonioxAsyncClient()
            }
        case .deepgram:
            return DeepgramClient()
        case .openai:
            return OpenAIClient()
        }
    }

    private var isRecording = false
    private var sessionDiscarded = false
    private var accumulatedText = ""
    private var lastInterimText = ""
    private let transcriptAssembler = TranscriptSessionAssembler()
    private let sessionAudioPCM = AudioSessionBuffer()
    /// Audio since the last successful paste-on-pause checkpoint.
    private let uncommittedAudioPCM = AudioSessionBuffer()
    private var sessionAppName = ""
    private var sessionSampleRate: Double = 16_000
    private var sessionPastedText = ""
    private var isRetranscribing = false
    private var retranscribeEntryID: UUID?
    private var pendingFinalizeWorkItem: DispatchWorkItem?
    private let recoveryLock = NSLock()
    private var recoveryPendingChunks: [Data] = []
    private var recoveryGeneration: UInt = 0
    private var recoveryAttempt = 0
    private var isRecoveringConnection = false
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryTimeoutWorkItem: DispatchWorkItem?
    private var recoveryReplayWorkItem: DispatchWorkItem?
    private var stopRequestedDuringRecovery = false
    private var normalIcon: NSImage?
    private var recordingIcon: NSImage?
    private let subtitleOverlay = SubtitleOverlay.shared

    public override init() {
        super.init()
        subtitleOverlay.onCancel = { [weak self] in
            self?.cancelActiveTranscription()
        }
        textPaster.onPasteObserved = { [weak self] observation in
            guard SettingsStore.shared.automaticDictionaryLearningEnabled else { return }
            self?.automaticCorrectionMonitor.begin(observation)
        }
        automaticCorrectionMonitor.onCorrections = { corrections in
            var learned: [DetectedCorrection] = []
            for correction in corrections {
                if SettingsStore.shared.addAutomaticCorrection(
                    wrong: correction.wrong,
                    right: correction.right
                ) {
                    learned.append(correction)
                }
            }
            // Only confirm corrections that actually entered the dictionary;
            // duplicates stay silent. The toast itself is optional.
            guard !learned.isEmpty,
                  SettingsStore.shared.showLearningHUD else { return }
            LearningHUD.shared.show(corrections: learned)
        }
    }

    // MARK: - App lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        sttProvider = createSTTProvider()
        setupIcons()
        setupStatusItem()
        setupHotkey()
        setupPressKeyMonitor()
        setupAudioPipeline()
        setupPasteSuppression()

        if let latest = historyStore.entries.first(where: { $0.hasText }) {
            lastTranscript = latest.text
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .settingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(automaticDictionaryLearningChanged),
            name: .automaticDictionaryLearningChanged,
            object: nil
        )

        // Show onboarding if selected provider has no API key. Reading the
        // existing key may trigger macOS's one-time Keychain prompt after the
        // stable-signing migration; the follow-up notice explains that prompt.
        // QA-only environment hooks bypass that read so the migration notice
        // and paste-learning path can be verified without modifying Keychain.
        let environment = ProcessInfo.processInfo.environment
        let isQALaunch = environment["TYPESTER_FORCE_STABLE_SIGNING_MIGRATION_NOTICE"] == "1"
            || environment["TYPESTER_QA_PASTE"] != nil
        let hasConfiguredAPIKey = isQALaunch || hasAPIKeyForCurrentProvider()
        if !hasConfiguredAPIKey {
            showOnboarding()
        } else {
            updateMonitoringMode()
        }
        scheduleStableSigningMigrationNoticeIfNeeded(
            hasConfiguredAPIKey: hasConfiguredAPIKey
        )

        // Do not touch the activation policy at launch unless the Dock
        // setting requires promoting from the LSUIElement default. Flipping
        // the policy during applicationDidFinishLaunching (e.g. demoting
        // after onboarding promoted to .regular while its window is not yet
        // visible) leaves the status item rendering blank on macOS 27.
        if SettingsStore.shared.showInDock {
            updateActivationPolicy()
        }

        // Silent background check for a newer GitHub release (throttled).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.autoCheckForUpdates()
        }

        applyDebugOverrides()
    }

    private func autoCheckForUpdates() {
        guard UpdateCheckSchedule.shouldAutoCheck(lastCheck: UpdateCheckSchedule.lastCheck()) else {
            return
        }
        UpdateCheckSchedule.recordCheck()
        UpdateChecker.shared.checkForUpdates { outcome in
            guard case .updateAvailable(_, let latest, let dmgURL, _) = outcome else { return }
            Debug.log("Background update check found \(latest)")
            AppUpdater.shared.pending = PendingUpdate(latest: latest, dmgURL: dmgURL)
            self.rebuildMenu()
            NotificationCenter.default.post(name: .updateDiscovered, object: nil)
        }
    }

    // MARK: - Demo overrides (screenshot/verification aid)

    /// Environment-driven hooks used for automated visual checks:
    /// TYPESTER_APPEARANCE=dark|light, TYPESTER_FAKE_TRANSCRIPT=…,
    /// TYPESTER_DEMO=settings|onboarding|teach|pill, TYPESTER_PILL_MODE=live|processing|reconnecting,
    /// TYPESTER_PANE=<settings pane>, TYPESTER_SNAPSHOT=/path.png,
    /// TYPESTER_QA_PASTE=… (exercise the real paste/learning path after launch),
    /// TYPESTER_FORCE_STABLE_SIGNING_MIGRATION_NOTICE=1 (render the migration alert),
    /// TYPESTER_INSTALL_UPDATE=/path/to/Typester-x.y.z.dmg (self-update E2E test).
    private func applyDebugOverrides() {
        let env = ProcessInfo.processInfo.environment

        if let appearance = env["TYPESTER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let fake = env["TYPESTER_FAKE_TRANSCRIPT"], !fake.isEmpty {
            lastTranscript = fake
        }
        if let qaPaste = env["TYPESTER_QA_PASTE"], !qaPaste.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.textPaster.paste(qaPaste, observeCorrections: true)
            }
        }
        if let dmgPath = env["TYPESTER_INSTALL_UPDATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                Debug.log("TYPESTER_INSTALL_UPDATE: installing from \(dmgPath)")
                AppUpdater.shared.install(
                    from: URL(fileURLWithPath: dmgPath),
                    status: { Debug.log("update: \($0)") },
                    completion: { result in
                        if case .failure(let error) = result {
                            Debug.log("TYPESTER_INSTALL_UPDATE failed: \(error.localizedDescription)")
                        }
                    }
                )
            }
        }

        let snapshotPath = env["TYPESTER_SNAPSHOT"]
        switch env["TYPESTER_DEMO"] {
        case "settings":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.openSettings()
                if let snapshotPath { self.scheduleSnapshot(of: \.settingsWindow, to: snapshotPath) }
            }
        case "onboarding":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.showOnboarding()
                if let snapshotPath { self.scheduleSnapshot(of: \.onboardingWindow, to: snapshotPath) }
            }
        case "teach":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.openTeachDictionary()
                if let snapshotPath { self.scheduleSnapshot(of: \.teachWindow, to: snapshotPath) }
            }
        case "pill":
            let mode = env["TYPESTER_PILL_MODE"] ?? "live"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.demoPill(mode: mode) }
            if let snapshotPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    self.subtitleOverlay.snapshotForDebug(to: snapshotPath)
                    NSApp.terminate(self)
                }
            }
        default:
            break
        }
    }

    /// Renders a demo window's content view to PNG (no screen-recording permission needed).
    private func scheduleSnapshot(of keyPath: ReferenceWritableKeyPath<AppDelegate, NSWindow?>, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let window = self[keyPath: keyPath] else { return }
            Self.snapshot(window: window, to: path)
            NSApp.terminate(self)
        }
    }

    static func snapshot(window: NSWindow, to path: String) {
        guard let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width) * 2,
                pixelsHigh: Int(bounds.height) * 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        contentView.cacheDisplay(in: bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            Debug.log("Snapshot written to \(path)")
        }
    }

    private func demoPill(mode: String) {
        let notesIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
        subtitleOverlay.show(appName: "Notes", appIcon: notesIcon)
        switch mode {
        case "processing":
            subtitleOverlay.showProcessing()
        case "reconnecting":
            subtitleOverlay.showReconnecting()
        default:
            subtitleOverlay.updateFinal("ship the ")
            subtitleOverlay.updateInterim("release candidate tomorrow")
        }
    }

    private func setupPasteSuppression() {
        textPaster.onPasteSimulationBegin = {
            PressKeyMonitor.shared.suppress()
        }
        textPaster.onPasteSimulationEnd = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                PressKeyMonitor.shared.unsuppress()
            }
        }
    }

    private func hasAPIKeyForCurrentProvider() -> Bool {
        switch SettingsStore.shared.sttProvider {
        case .soniox:
            return SettingsStore.shared.apiKey != nil
        case .deepgram:
            return SettingsStore.shared.deepgramApiKey != nil
        case .openai:
            return SettingsStore.shared.openaiApiKey != nil
        }
    }

    private func scheduleStableSigningMigrationNoticeIfNeeded(hasConfiguredAPIKey: Bool) {
        let defaults = UserDefaults.standard
        let forceNotice = ProcessInfo.processInfo.environment[
            "TYPESTER_FORCE_STABLE_SIGNING_MIGRATION_NOTICE"
        ] == "1"
        guard StableSigningMigration.shouldShowPostUpgradeNotice(
            hasConfiguredAPIKey: hasConfiguredAPIKey || forceNotice,
            accessibilityTrusted: forceNotice
                ? false
                : TextPaster.checkAccessibilityPermission(),
            noticeAlreadyShown: forceNotice
                ? false
                : defaults.bool(forKey: StableSigningMigration.noticeShownDefaultsKey)
        ) else { return }

        // Mark before scheduling so a second launch cannot enqueue a duplicate.
        if !forceNotice {
            defaults.set(true, forKey: StableSigningMigration.noticeShownDefaultsKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showStableSigningMigrationNotice()
        }
    }

    private func showStableSigningMigrationNotice() {
        let alert = NSAlert()
        alert.messageText = "Finish the one-time Typester upgrade"
        alert.informativeText = "Typester 1.16 uses a stable signing identity, so the old authorization does not transfer automatically. \(StableSigningMigration.keychainAuthorizationGuidance) Then open Accessibility settings, remove the old Typester entry if present, add /Applications/Typester.app, turn it on, and relaunch Typester."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()

        if alert.runModal() == .alertFirstButtonReturn {
            TextPaster.openAccessibilitySettings()
        }
        updateActivationPolicy()
    }

    @objc private func settingsChanged() {
        HotkeyManager.shared.registerHotkey()
        updateMonitoringMode()
        updateSTTProvider()
        rebuildMenu()
        updateActivationPolicy()
    }

    @objc private func automaticDictionaryLearningChanged() {
        if !SettingsStore.shared.automaticDictionaryLearningEnabled {
            automaticCorrectionMonitor.cancel()
        }
    }

    /// Keep the Dock presence in sync with the "Show in Dock" setting.
    /// The app launches as a menu-bar-only LSUIElement process; it must be
    /// .regular while any of its windows are open (text input needs it) or
    /// when the user opted into a permanent Dock icon.
    private func updateActivationPolicy() {
        let hasVisibleWindow = [settingsWindow, onboardingWindow, teachWindow]
            .contains { $0?.isVisible == true }
        let desired: NSApplication.ActivationPolicy =
            (SettingsStore.shared.showInDock || hasVisibleWindow) ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        if desired == .regular {
            setupMainMenu()
        }
        NSApp.setActivationPolicy(desired)
        // Reapply the icon after the policy flip: promoting an LSUIElement
        // process to .regular can leave the Dock tile rendering blank unless
        // the icon image is (re)set afterwards.
        if desired == .regular {
            setAppIcon()
        }
    }

    private func updateSTTProvider() {
        switch SettingsStore.shared.sttProvider {
        case .soniox:
            switch SettingsStore.shared.sonioxMode {
            case .realtime:
                if sttProvider is SonioxClient { return }
            case .async:
                if sttProvider is SonioxAsyncClient { return }
            }
        case .deepgram:
            if sttProvider is DeepgramClient { return }
        case .openai:
            if sttProvider is OpenAIClient { return }
        }

        // Disconnect old provider
        sttProvider.disconnect()

        // Setup new provider with same callbacks
        sttProvider = createSTTProvider()
        setupSTTCallbacks()
        syncAudioSampleRate()
    }

    private func syncAudioSampleRate() {
        audioRecorder.targetSampleRate = SettingsStore.shared.sttProvider.audioSampleRate
    }

    private func setupSTTCallbacks() {
        sttProvider.onConnected = { [weak self] in
            Debug.log("STT connected, buffered audio flushed")
            self?.onSTTConnected()
        }

        sttProvider.onDisconnected = { [weak self] in
            guard let self = self else { return }
            if self.isRetranscribing {
                self.subtitleOverlay.hide()
                self.audioRecorder.stopRecording()
                self.finishRetranscribe(success: false)
                return
            }
            if self.isConnectionRecoveryActive() {
                self.handleRecoveryDisconnect()
                return
            }
            if self.isRecording {
                self.beginConnectionRecovery()
            } else {
                self.subtitleOverlay.hide()
                self.audioRecorder.stopRecording()
            }
        }

        sttProvider.onTranscript = { [weak self] text, isFinal in
            guard let self = self else { return }
            Debug.log("onTranscript: \"\(text)\" isFinal=\(isFinal)")
            if isFinal {
                self.transcriptAssembler.appendFinal(text)
                self.syncTranscriptState()
                if !self.isRetranscribing {
                    self.subtitleOverlay.updateFinal(text)
                }
            } else {
                self.transcriptAssembler.replaceInterim(text)
                self.syncTranscriptState()
                if !self.isRetranscribing {
                    self.subtitleOverlay.updateInterim(text)
                }
            }
        }

        sttProvider.onEndpoint = { [weak self] in
            guard let self = self else { return }
            // Default: keep accumulating through pauses; paste only on finalize (user stops).
            // Optional paste-on-pause pastes each endpoint utterance immediately.
            guard !self.isRetranscribing else { return }
            guard SettingsStore.shared.pasteOnPause else { return }
            self.pasteAccumulatedTranscript(saveHistory: false)
            self.subtitleOverlay.clearText()
        }

        sttProvider.onFinalized = { [weak self] in
            guard let self = self else { return }
            if self.sessionDiscarded {
                self.sessionDiscarded = false
                self.subtitleOverlay.hide()
                self.sttProvider.disconnect()
                return
            }
            if self.isRetranscribing {
                self.handleRetranscribeFinalized()
                return
            }
            self.pasteAccumulatedTranscript(saveHistory: true)
            self.subtitleOverlay.hide()
            self.sttProvider.disconnect()
        }

        sttProvider.onError = { [weak self] error in
            guard let self = self else { return }
            if self.isConnectionRecoveryActive() {
                self.handleRecoveryError(error)
                return
            }
            if self.sessionDiscarded {
                self.sessionDiscarded = false
                self.isRecording = false
                self.statusItem.button?.image = self.normalIcon
                self.subtitleOverlay.hide()
                self.audioRecorder.stopRecording()
                self.sttProvider.disconnect()
                return
            }
            if self.isRetranscribing {
                self.finishRetranscribe(success: false)
                self.sttProvider.disconnect()
                self.showError(error)
                return
            }
            self.isRecording = false
            self.statusItem.button?.image = self.normalIcon
            self.subtitleOverlay.hide()
            self.audioRecorder.stopRecording()
            let current = TranscriptPastePayload.resolve(
                accumulatedText: self.accumulatedText,
                lastInterimText: self.lastInterimText
            ) ?? ""
            let historyText: String
            if self.sessionPastedText.isEmpty {
                historyText = current
            } else if current.isEmpty {
                historyText = self.sessionPastedText
            } else {
                historyText = self.sessionPastedText + " " + current
            }
            self.saveSessionToHistory(text: historyText, status: .failed)
            self.resetTranscriptSession()
            self.sessionPastedText = ""
            self.rebuildMenu()
            self.showError(error)
        }
    }

    private func onSTTConnected() {
        if isConnectionRecoveryActive() {
            replayRecoveredAudio()
            return
        }

        guard isRetranscribing, let id = retranscribeEntryID,
              let entry = historyStore.entries.first(where: { $0.id == id }),
              let url = historyStore.audioURL(for: entry),
              let pcm = try? Data(contentsOf: url), !pcm.isEmpty else {
            return
        }
        replayPCM(pcm, sampleRate: entry.sampleRate)
    }

    private func syncTranscriptState() {
        accumulatedText = transcriptAssembler.finalText
        lastInterimText = transcriptAssembler.interimText
    }

    private func resetTranscriptSession() {
        transcriptAssembler.reset()
        accumulatedText = ""
        lastInterimText = ""
    }

    // MARK: - Connection recovery

    private func isConnectionRecoveryActive() -> Bool {
        recoveryLock.withLock { isRecoveringConnection }
    }

    private func beginConnectionRecovery() {
        guard isRecording else { return }

        let shouldStart = recoveryLock.withLock { () -> Bool in
            guard !isRecoveringConnection else { return false }
            isRecoveringConnection = true
            recoveryAttempt = 0
            recoveryPendingChunks.removeAll(keepingCapacity: true)
            recoveryGeneration &+= 1
            stopRequestedDuringRecovery = false
            return true
        }

        recoveryReplayWorkItem?.cancel()
        recoveryTimeoutWorkItem?.cancel()
        if !shouldStart {
            scheduleRecoveryAttempt(after: 0.2)
            return
        }

        Debug.log("STT connection lost while recording; beginning recovery")
        subtitleOverlay.showReconnecting()
        // Clear the provider's old FIFO. The app-level PCM buffers are the
        // source of truth for replay, so the new socket starts at a known point.
        sttProvider.disconnect()
        scheduleRecoveryAttempt(after: 0.35)
    }

    private func scheduleRecoveryAttempt(after delay: TimeInterval) {
        guard isConnectionRecoveryActive() else { return }
        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptConnectionRecovery()
        }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func attemptConnectionRecovery() {
        guard isConnectionRecoveryActive() else { return }
        guard isRecording || recoveryStopWasRequested() else {
            cancelConnectionRecovery()
            return
        }

        let attempt = recoveryLock.withLock { () -> Int in
            recoveryAttempt += 1
            recoveryWorkItem = nil
            return recoveryAttempt
        }
        guard attempt <= 2 else {
            failConnectionRecovery("Connection recovery failed after two attempts. The captured audio was saved for re-transcription.")
            return
        }

        Debug.log("STT recovery attempt \(attempt)/2")
        sttProvider.disconnect()
        sttProvider.connect()

        recoveryTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isConnectionRecoveryActive() else { return }
            self.handleRecoveryError("The speech service did not reconnect in time.")
        }
        recoveryTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func handleRecoveryDisconnect() {
        guard isConnectionRecoveryActive() else { return }
        recoveryReplayWorkItem?.cancel()
        recoveryReplayWorkItem = nil
        recoveryTimeoutWorkItem?.cancel()
        recoveryTimeoutWorkItem = nil
        recoveryLock.withLock {
            recoveryGeneration &+= 1
        }
        scheduleRecoveryAttempt(after: 0.25)
    }

    private func handleRecoveryError(_ message: String) {
        guard isConnectionRecoveryActive() else { return }
        let lowered = message.lowercased()
        let isPermanent = lowered.contains("api key")
            || lowered.contains("unauthorized")
            || lowered.contains("authentication")
            || lowered.contains("401")
            || lowered.contains("403")
        let attempt = recoveryLock.withLock { recoveryAttempt }
        if isPermanent || attempt >= 2 {
            failConnectionRecovery(message)
        } else {
            scheduleRecoveryAttempt(after: 0.35)
        }
    }

    private func replayRecoveredAudio() {
        guard isConnectionRecoveryActive() else { return }
        recoveryTimeoutWorkItem?.cancel()
        recoveryTimeoutWorkItem = nil
        recoveryReplayWorkItem?.cancel()

        let generation = recoveryLock.withLock { recoveryGeneration }
        let pcm = SettingsStore.shared.pasteOnPause
            ? uncommittedAudioPCM.snapshot()
            : sessionAudioPCM.snapshot()

        // Replay replaces the provider's old transcript state. This is what
        // prevents final text from the old socket being appended a second time.
        resetTranscriptSession()
        subtitleOverlay.clearText()
        if !recoveryStopWasRequested() {
            subtitleOverlay.clearProcessing()
        }

        guard !pcm.isEmpty else {
            finishRecoveredReplay(generation: generation)
            return
        }

        let bytesPerSecond = Int(sessionSampleRate) * MemoryLayout<Int16>.size
        let chunkSize = max(bytesPerSecond / 10, MemoryLayout<Int16>.size * 2)
        var offset = 0

        func sendNextChunk() {
            guard self.isRecoveryGenerationActive(generation) else { return }
            if offset >= pcm.count {
                self.finishRecoveredReplay(generation: generation)
                return
            }

            let end = min(offset + chunkSize, pcm.count)
            self.sttProvider.sendAudio(pcm.subdata(in: offset..<end))
            offset = end

            let workItem = DispatchWorkItem {
                sendNextChunk()
            }
            self.recoveryReplayWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }

        sendNextChunk()
    }

    private func isRecoveryGenerationActive(_ generation: UInt) -> Bool {
        recoveryLock.withLock {
            isRecoveringConnection && recoveryGeneration == generation
        }
    }

    private func recoveryStopWasRequested() -> Bool {
        recoveryLock.withLock { stopRequestedDuringRecovery }
    }

    private func finishRecoveredReplay(generation: UInt) {
        guard isRecoveryGenerationActive(generation) else { return }
        recoveryReplayWorkItem = nil

        let shouldFinalize = recoveryLock.withLock { () -> Bool in
            let chunks = recoveryPendingChunks
            recoveryPendingChunks.removeAll(keepingCapacity: true)
            // Keep the recovery flag set while these chunks enter the
            // provider's admission FIFO. The audio callback blocks on the
            // same lock, so live audio cannot overtake the replay tail.
            for chunk in chunks {
                sttProvider.sendAudio(chunk)
            }
            let shouldFinalize = stopRequestedDuringRecovery
            isRecoveringConnection = false
            stopRequestedDuringRecovery = false
            return shouldFinalize
        }
        if shouldFinalize {
            subtitleOverlay.showProcessing()
            let workItem = DispatchWorkItem { [weak self] in
                self?.sttProvider.sendFinalize()
            }
            pendingFinalizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        } else {
            subtitleOverlay.clearProcessing()
        }
    }

    private func failConnectionRecovery(_ message: String) {
        guard isConnectionRecoveryActive() else { return }
        recoveryLock.withLock {
            isRecoveringConnection = false
            recoveryGeneration &+= 1
            recoveryPendingChunks.removeAll(keepingCapacity: true)
            stopRequestedDuringRecovery = false
        }
        recoveryWorkItem?.cancel()
        recoveryTimeoutWorkItem?.cancel()
        recoveryReplayWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryTimeoutWorkItem = nil
        recoveryReplayWorkItem = nil

        audioRecorder.stopRecording()
        isRecording = false
        statusItem.button?.image = normalIcon
        subtitleOverlay.hide()

        let current = currentSessionText()
        let historyText: String
        if sessionPastedText.isEmpty {
            historyText = current
        } else if current.isEmpty {
            historyText = sessionPastedText
        } else {
            historyText = sessionPastedText + " " + current
        }
        saveSessionToHistory(text: historyText, status: .failed)
        resetTranscriptSession()
        sessionPastedText = ""
        rebuildMenu()
        sttProvider.disconnect()
        showError(message)
    }

    private func cancelConnectionRecovery() {
        recoveryLock.withLock {
            isRecoveringConnection = false
            recoveryGeneration &+= 1
            recoveryPendingChunks.removeAll(keepingCapacity: true)
            stopRequestedDuringRecovery = false
        }
        recoveryWorkItem?.cancel()
        recoveryTimeoutWorkItem?.cancel()
        recoveryReplayWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryTimeoutWorkItem = nil
        recoveryReplayWorkItem = nil
    }

    private func appendRecoveryAudio(_ data: Data) -> Bool {
        recoveryLock.withLock {
            guard isRecoveringConnection else { return false }
            recoveryPendingChunks.append(data)
            return true
        }
    }

    private func currentSessionText() -> String {
        TranscriptPastePayload.resolve(
            accumulatedText: accumulatedText,
            lastInterimText: lastInterimText
        ) ?? ""
    }

    // MARK: - Icons

    private func setupIcons() {
        setAppIcon()
        normalIcon = loadMenuBarIcon()
        recordingIcon = createRecordingIcon()
    }

    private func setAppIcon() {
        if let image = AssetLoader.loadImage(named: "AppIcon.icns") {
            NSApp.applicationIconImage = image
        }
    }

    private func loadMenuBarIcon() -> NSImage {
        if let image = AssetLoader.loadImage(named: "MenuBarIcon.png") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            Debug.log("menu bar icon loaded: reps=\(image.representations.count) template=\(image.isTemplate)")
            return image
        }
        Debug.log("menu bar icon NOT FOUND — using fallback glyph")
        return createFallbackIcon()
    }

    private func createRecordingIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            circle.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func createFallbackIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 9, y: 4))
            path.line(to: NSPoint(x: 9, y: 14))
            path.move(to: NSPoint(x: 5, y: 10))
            path.appendArc(withCenter: NSPoint(x: 9, y: 10), radius: 4, startAngle: 180, endAngle: 0, clockwise: true)
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = normalIcon
            Debug.log("status item configured: icon=\(normalIcon != nil) reps=\(normalIcon?.representations.count ?? 0) size=\(String(describing: normalIcon?.size))")
        } else {
            Debug.log("status item has NO button")
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Dictate/Stop item
        let title = isRecording ? "Stop" : "Dictate"
        let shortcut = shortcutDisplayString()
        let recordItem = NSMenuItem(
            title: title,
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )

        let attributed = NSMutableAttributedString(string: "\(title)  \(shortcut)")
        let shortcutRange = NSRange(location: title.count + 2, length: shortcut.count)
        attributed.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: shortcutRange)
        recordItem.attributedTitle = attributed
        recordItem.target = self

        menu.addItem(recordItem)

        menu.addItem(.separator())

        // Microphone submenu
        let micMenu = NSMenu()
        let inputDevices = getInputDevices()
        let selectedMicID = SettingsStore.shared.selectedMicrophoneID

        let defaultMicItem = NSMenuItem(title: "System default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        defaultMicItem.target = self
        defaultMicItem.representedObject = nil
        defaultMicItem.state = selectedMicID == nil ? .on : .off
        micMenu.addItem(defaultMicItem)

        if !inputDevices.isEmpty {
            micMenu.addItem(.separator())
        }

        for device in inputDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: device.id)
            item.state = selectedMicID == String(device.id) ? .on : .off
            micMenu.addItem(item)
        }

        let micMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenuItem.submenu = micMenu
        menu.addItem(micMenuItem)

        // Languages submenu (Soniox hints / OpenAI languages; Deepgram auto-detects)
        if SettingsStore.shared.sttProvider == .soniox || SettingsStore.shared.sttProvider == .openai {
            let langMenu = NSMenu()
            let selectedLangs = Set(SettingsStore.shared.languageHints)

            // Sort: selected languages first, then popular (in original order), then rest alphabetically
            let sortedLanguages = supportedLanguages.enumerated().sorted { a, b in
                let aSelected = selectedLangs.contains(a.element.code)
                let bSelected = selectedLangs.contains(b.element.code)
                if aSelected != bSelected { return aSelected }
                if a.element.isPopular != b.element.isPopular { return a.element.isPopular }
                // Popular languages: preserve original order; others: alphabetically
                if a.element.isPopular && b.element.isPopular { return a.offset < b.offset }
                return a.element.name < b.element.name
            }.map { $0.element }

            for lang in sortedLanguages {
                let item = NSMenuItem(
                    title: "\(lang.flag) \(lang.name)",
                    action: #selector(toggleLanguage(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = lang.code
                item.state = selectedLangs.contains(lang.code) ? .on : .off
                langMenu.addItem(item)
            }

            let langMenuItem = NSMenuItem(title: "Languages", action: nil, keyEquivalent: "")
            langMenuItem.submenu = langMenu
            menu.addItem(langMenuItem)
        }

        menu.addItem(.separator())

        menu.addItem(makeSoundsMenuItem())

        menu.addItem(makeRecentMenuItem())

        let teachItem = NSMenuItem(
            title: "Teach last transcript…",
            action: #selector(openTeachDictionary),
            keyEquivalent: ""
        )
        teachItem.target = self
        teachItem.isEnabled = !lastTranscript.isEmpty
        menu.addItem(teachItem)

        if let pending = AppUpdater.shared.pending {
            let updateItem = NSMenuItem(
                title: "Update to \(pending.latest)…",
                action: #selector(installUpdateFromMenu),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let checkItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        checkItem.target = self
        menu.addItem(checkItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Typester",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        ))

        statusItem.menu = menu
    }

    private func makeSoundsMenuItem() -> NSMenuItem {
        let soundsMenu = NSMenu()

        let playItem = NSMenuItem(
            title: "Play sounds",
            action: #selector(toggleDictationSounds),
            keyEquivalent: ""
        )
        playItem.target = self
        playItem.state = SettingsStore.shared.playDictationSounds ? .on : .off
        soundsMenu.addItem(playItem)

        let volumeItem = NSMenuItem()
        volumeItem.view = makeDictationVolumeSliderView()
        soundsMenu.addItem(volumeItem)

        let soundsItem = NSMenuItem(title: "Sounds", action: nil, keyEquivalent: "")
        soundsItem.submenu = soundsMenu
        return soundsItem
    }

    private func makeDictationVolumeSliderView() -> NSView {
        // Knob draws outside the track; give the custom menu item enough height and disable clipping.
        let width: CGFloat = 220
        let height: CGFloat = 48
        let sliderHeight: CGFloat = 28
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.clipsToBounds = false
        view.wantsLayer = true
        view.layer?.masksToBounds = false

        let label = NSTextField(labelWithString: "Volume")
        label.font = .menuFont(ofSize: 13)
        label.textColor = .labelColor
        label.frame = NSRect(x: 14, y: (height - 16) / 2, width: 52, height: 16)

        let slider = NSSlider(
            value: Double(SettingsStore.shared.dictationSoundVolume),
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(dictationSoundVolumeChanged(_:))
        )
        slider.isContinuous = true
        slider.isEnabled = SettingsStore.shared.playDictationSounds
        slider.frame = NSRect(
            x: 68,
            y: (height - sliderHeight) / 2,
            width: width - 82,
            height: sliderHeight
        )

        view.addSubview(label)
        view.addSubview(slider)
        return view
    }

    @objc private func toggleDictationSounds() {
        SettingsStore.shared.playDictationSounds.toggle()
        rebuildMenu()
    }

    @objc private func dictationSoundVolumeChanged(_ sender: NSSlider) {
        SettingsStore.shared.dictationSoundVolume = Float(sender.doubleValue)
    }

    private func makeRecentMenuItem() -> NSMenuItem {
        let recentMenu = NSMenu()
        let entries = historyStore.entries

        if entries.isEmpty {
            let empty = NSMenuItem(title: "No recent transcriptions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            recentMenu.addItem(.separator())
            let openFolderItem = NSMenuItem(
                title: "Open Recordings Folder",
                action: #selector(openRecordingsFolder),
                keyEquivalent: ""
            )
            openFolderItem.target = self
            recentMenu.addItem(openFolderItem)
        } else {
            for entry in entries {
                let item = NSMenuItem(title: entry.menuTitle, action: nil, keyEquivalent: "")
                let sub = NSMenu()

                let pasteItem = NSMenuItem(
                    title: "Paste",
                    action: #selector(pasteHistoryEntry(_:)),
                    keyEquivalent: ""
                )
                pasteItem.target = self
                pasteItem.representedObject = entry.id
                pasteItem.isEnabled = entry.hasText && !isRetranscribing
                sub.addItem(pasteItem)

                let copyItem = NSMenuItem(
                    title: "Copy",
                    action: #selector(copyHistoryEntry(_:)),
                    keyEquivalent: ""
                )
                copyItem.target = self
                copyItem.representedObject = entry.id
                copyItem.isEnabled = entry.hasText
                sub.addItem(copyItem)

                let retryItem = NSMenuItem(
                    title: isRetranscribing && retranscribeEntryID == entry.id
                        ? "Re-transcribing…"
                        : "Re-transcribe",
                    action: #selector(retranscribeHistoryEntry(_:)),
                    keyEquivalent: ""
                )
                retryItem.target = self
                retryItem.representedObject = entry.id
                retryItem.isEnabled = historyStore.hasAudio(for: entry)
                    && !isRecording
                    && !isRetranscribing
                sub.addItem(retryItem)

                let revealItem = NSMenuItem(
                    title: "Show in Finder",
                    action: #selector(revealHistoryAudio(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = entry.id
                revealItem.isEnabled = historyStore.hasAudio(for: entry)
                sub.addItem(revealItem)

                item.submenu = sub
                recentMenu.addItem(item)
            }

            recentMenu.addItem(.separator())

            let openFolderItem = NSMenuItem(
                title: "Open Recordings Folder",
                action: #selector(openRecordingsFolder),
                keyEquivalent: ""
            )
            openFolderItem.target = self
            recentMenu.addItem(openFolderItem)

            let clearItem = NSMenuItem(
                title: "Clear Recent History…",
                action: #selector(clearRecentHistory),
                keyEquivalent: ""
            )
            clearItem.target = self
            clearItem.isEnabled = !isRetranscribing
            recentMenu.addItem(clearItem)
        }

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        return recentItem
    }

    private func pasteAccumulatedTranscript(saveHistory: Bool) {
        let raw = TranscriptPastePayload.resolve(
            accumulatedText: accumulatedText,
            lastInterimText: lastInterimText
        )

        defer {
            resetTranscriptSession()
        }

        if let text = raw {
            lastTranscript = text
            let replaced = SettingsStore.shared.applyReplacements(text)
            let formatted = TranscriptFormatter.format(replaced)
            let pasteText = formatted.hasSuffix(" ") ? formatted : formatted + " "
            textPaster.paste(
                pasteText,
                observeCorrections: SettingsStore.shared.automaticDictionaryLearningEnabled
            )
            let stored = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
            if sessionPastedText.isEmpty {
                sessionPastedText = stored
            } else {
                sessionPastedText += " " + stored
            }
            // Only audio after this checkpoint needs replaying on a reconnect
            // when paste-on-pause is enabled.
            uncommittedAudioPCM.clear()
        }

        if saveHistory {
            let historyText = sessionPastedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if historyText.isEmpty {
                saveSessionToHistory(text: "", status: .failed)
            } else {
                saveSessionToHistory(text: historyText, status: .succeeded)
            }
            sessionPastedText = ""
        }
        rebuildMenu()
    }

    private func saveSessionToHistory(text: String, status: TranscriptEntryStatus) {
        guard !sessionAudioPCM.isEmpty else { return }
        let pcm = sessionAudioPCM.take()
        let appName = sessionAppName
        let sampleRate = sessionSampleRate
        uncommittedAudioPCM.clear()

        do {
            _ = try historyStore.add(
                text: text,
                status: status,
                appName: appName,
                sampleRate: sampleRate,
                audioPCM: pcm
            )
        } catch {
            Debug.log("Failed to save transcript history: \(error.localizedDescription)")
        }
    }

    @objc private func pasteHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = historyStore.entries.first(where: { $0.id == id }),
              entry.hasText else { return }
        let pasteText = entry.text.hasSuffix(" ") ? entry.text : entry.text + " "
        textPaster.paste(
            pasteText,
            observeCorrections: SettingsStore.shared.automaticDictionaryLearningEnabled
        )
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = historyStore.entries.first(where: { $0.id == id }),
              entry.hasText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    @objc private func retranscribeHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        startRetranscribe(entryID: id)
    }

    @objc private func revealHistoryAudio(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = historyStore.entries.first(where: { $0.id == id }),
              let url = historyStore.audioURL(for: entry),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openRecordingsFolder() {
        let directory = historyStore.directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func clearRecentHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear recent history?"
        alert.informativeText = "This permanently deletes the last transcriptions and their saved audio."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            try? historyStore.clearAll()
            lastTranscript = ""
            rebuildMenu()
        }
        updateActivationPolicy()
    }

    private func startRetranscribe(entryID: UUID) {
        guard !isRecording, !isRetranscribing else { return }
        guard hasAPIKeyForCurrentProvider() else {
            openSettings()
            return
        }
        guard let entry = historyStore.entries.first(where: { $0.id == entryID }),
              historyStore.hasAudio(for: entry) else { return }

        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil

        // Disconnect any prior socket before flipping the retranscribe flag so
        // onDisconnected does not treat this teardown as a failed re-transcribe.
        sttProvider.disconnect()

        isRetranscribing = true
        retranscribeEntryID = entryID
        resetTranscriptSession()
        rebuildMenu()

        let frontApp = NSWorkspace.shared.frontmostApplication
        subtitleOverlay.show(
            appName: frontApp?.localizedName ?? "Re-transcribe",
            appIcon: frontApp?.icon
        )
        subtitleOverlay.showProcessing()

        sttProvider.connect()
    }

    private func replayPCM(_ pcm: Data, sampleRate: Double) {
        // Async Soniox uploads one buffer — skip chunked realtime replay.
        if sttProvider is SonioxAsyncClient {
            sttProvider.sendAudio(pcm)
            sttProvider.sendFinalize()
            return
        }

        let bytesPerSecond = Int(sampleRate) * MemoryLayout<Int16>.size
        let chunkSize = max(bytesPerSecond / 10, MemoryLayout<Int16>.size * 2) // ~100ms
        var offset = 0

        func sendNextChunk() {
            guard isRetranscribing else { return }
            if offset >= pcm.count {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.sttProvider.sendFinalize()
                }
                pendingFinalizeWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
                return
            }

            let end = min(offset + chunkSize, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            offset = end
            sttProvider.sendAudio(chunk)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                sendNextChunk()
            }
        }

        sendNextChunk()
    }

    private func handleRetranscribeFinalized() {
        let raw = TranscriptPastePayload.resolve(
            accumulatedText: accumulatedText,
            lastInterimText: lastInterimText
        )
        resetTranscriptSession()

        guard let text = raw else {
            finishRetranscribe(success: false)
            sttProvider.disconnect()
            showError("Re-transcription produced no text. Audio was kept for another try.")
            return
        }

        lastTranscript = text
        let replaced = SettingsStore.shared.applyReplacements(text)
        let formatted = TranscriptFormatter.format(replaced)
        let pasteText = formatted.hasSuffix(" ") ? formatted : formatted + " "
        textPaster.paste(
            pasteText,
            observeCorrections: SettingsStore.shared.automaticDictionaryLearningEnabled
        )

        if let id = retranscribeEntryID,
           var entry = historyStore.entries.first(where: { $0.id == id }) {
            entry.text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.status = .succeeded
            try? historyStore.update(entry)
        }

        finishRetranscribe(success: true)
        sttProvider.disconnect()
    }

    private func finishRetranscribe(success: Bool) {
        guard isRetranscribing else { return }
        isRetranscribing = false
        retranscribeEntryID = nil
        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil
        // Do not rely on the provider's disconnect callback to clean up the
        // processing pill. Some providers finalize before their socket emits
        // a disconnect event, which otherwise leaves the spinner on screen.
        subtitleOverlay.hide()
        Debug.log("Re-transcribe finished success=\(success)")
        rebuildMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        if let deviceID = sender.representedObject as? NSNumber {
            SettingsStore.shared.selectedMicrophoneID = String(deviceID.uint32Value)
        } else {
            SettingsStore.shared.selectedMicrophoneID = nil
        }
        rebuildMenu()
    }

    @objc private func toggleLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        var hints = SettingsStore.shared.languageHints

        if hints.contains(code) {
            hints.removeAll { $0 == code }
        } else {
            hints.append(code)
        }

        SettingsStore.shared.languageHints = hints
        rebuildMenu()
    }

    private struct AudioInputDevice {
        let id: AudioDeviceID
        let name: String
    }

    private func getInputDevices() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = []

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return devices
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return devices
        }

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else {
                continue
            }

            let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(inputSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListPointer.deallocate() }

            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPointer) == noErr else {
                continue
            }

            let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self).pointee
            guard bufferList.mNumberBuffers > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString?>.size)

            if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr,
               let deviceName = name?.takeUnretainedValue() as String? {
                // Check transport type to filter virtual devices
                var transportAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyTransportType,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var transportType: UInt32 = 0
                var transportSize = UInt32(MemoryLayout<UInt32>.size)

                if AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType) == noErr {
                    // Skip virtual and aggregate devices
                    if transportType == kAudioDeviceTransportTypeVirtual ||
                       transportType == kAudioDeviceTransportTypeAggregate {
                        continue
                    }
                }

                devices.append(AudioInputDevice(id: deviceID, name: deviceName))
            }
        }

        return devices
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        HotkeyManager.shared.onHotkeyTriggered = { [weak self] in
            self?.toggleRecording()
        }
        HotkeyManager.shared.onEscapePressed = { [weak self] in
            self?.cancelRecording()
        }
        HotkeyManager.shared.registerHotkey()
    }

    // MARK: - Press-to-speak key monitor

    private func setupPressKeyMonitor() {
        PressKeyMonitor.shared.onKeyPressed = { [weak self] in
            guard SettingsStore.shared.activationMode == .pressToSpeak else { return }
            self?.startRecording()
        }

        PressKeyMonitor.shared.onKeyReleased = { [weak self] in
            guard SettingsStore.shared.activationMode == .pressToSpeak else { return }
            self?.stopRecording()
        }
    }

    private func updateMonitoringMode() {
        switch SettingsStore.shared.activationMode {
        case .hotkey:
            PressKeyMonitor.shared.stop()
        case .pressToSpeak:
            setupPressKeyMonitor()
            PressKeyMonitor.shared.start()
        }
    }

    // MARK: - Audio pipeline

    private func setupAudioPipeline() {
        syncAudioSampleRate()
        // Recycle the audio engine after sleep/wake — a cached engine holding
        // a stale CoreAudio device crashes when restarted after wake.
        audioRecorder.installSleepWakeHandlers()
        // Pre-warm CoreAudio/AVAudioEngine — cold creation can take multiple seconds with Discord open.
        audioRecorder.prepareEngine()

        audioRecorder.onAudioBuffer = { [weak self] data in
            guard let self else { return }
            if !self.isRetranscribing {
                self.sessionAudioPCM.append(data)
                self.uncommittedAudioPCM.append(data)
                if self.appendRecoveryAudio(data) {
                    return
                }
            }
            self.sttProvider.sendAudio(data)
        }

        audioRecorder.onSpectrum = { [weak self] bands in
            self?.subtitleOverlay.updateSpectrum(bands)
        }

        audioRecorder.onError = { [weak self] _ in
            self?.stopRecording()
        }

        setupSTTCallbacks()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Transcription failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSettings()
        }
        // Hand the decision back on every exit path. When openSettings()
        // presented its window first, updateActivationPolicy() keeps the app
        // .regular while that window is visible; otherwise it demotes to
        // .accessory so the Dock icon disappears again.
        updateActivationPolicy()
    }

    // MARK: - Recording control

    @objc func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        Debug.log("startRecording() called, isRecording=\(isRecording)")
        guard !isRecording else {
            Debug.log("startRecording() SKIPPED - already recording")
            return
        }
        guard !isRetranscribing else {
            Debug.log("startRecording() SKIPPED - re-transcribe in progress")
            return
        }

        guard hasAPIKeyForCurrentProvider() else {
            Debug.log("startRecording() SKIPPED - no API key for \(SettingsStore.shared.sttProvider)")
            openSettings()
            return
        }

        Debug.log("Starting recording...")

        // Cancel any pending finalize from previous session
        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil

        isRecording = true
        sessionDiscarded = false
        cancelConnectionRecovery()
        statusItem.button?.image = recordingIcon
        resetTranscriptSession()
        sessionAudioPCM.clear()
        uncommittedAudioPCM.clear()
        sessionPastedText = ""
        sessionSampleRate = SettingsStore.shared.sttProvider.audioSampleRate
        rebuildMenu()

        FeedbackSoundPlayer.playStart()

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? ""
        let appIcon = frontApp?.icon
        sessionAppName = appName
        subtitleOverlay.show(appName: appName, appIcon: appIcon)

        syncAudioSampleRate()
        // Start audio immediately - it will buffer while WebSocket connects
        audioRecorder.startRecording()
        sttProvider.connect()
    }

    private func stopRecording() {
        Debug.log("stopRecording() called, isRecording=\(isRecording)")
        guard isRecording else {
            Debug.log("stopRecording() SKIPPED - not recording")
            return
        }

        Debug.log("Stopping recording...")
        let isRecovering = isConnectionRecoveryActive()
        isRecording = false
        sessionDiscarded = false
        statusItem.button?.image = normalIcon
        rebuildMenu()

        FeedbackSoundPlayer.playStop()

        audioRecorder.stopRecording()

        // Compact spinner while any provider finishes (async upload, OpenAI commit, etc.).
        subtitleOverlay.showProcessing()

        if isRecovering {
            recoveryLock.withLock {
                stopRequestedDuringRecovery = true
            }
            // The reconnect path will replay the complete unpasted PCM and
            // issue finalize only after the replay and live tail are ordered.
            return
        }

        // Small delay to let provider process last audio chunks before finalizing
        let workItem = DispatchWorkItem { [weak self] in
            Debug.log("Sending finalize after delay")
            self?.sttProvider.sendFinalize()
        }
        pendingFinalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// Discard the current dictation without pasting (ESC).
    private func cancelRecording() {
        Debug.log("cancelRecording() called, isRecording=\(isRecording)")
        guard isRecording else { return }

        cancelActiveTranscription()
    }

    private func cancelActiveTranscription() {
        Debug.log("cancelActiveTranscription() called, isRecording=\(isRecording), isRetranscribing=\(isRetranscribing)")

        if isRetranscribing {
            // Re-use the discard guard so a late provider callback cannot paste
            // or save a result after the user has cancelled the retry.
            sessionDiscarded = true
            resetTranscriptSession()
            finishRetranscribe(success: false)
            sttProvider.disconnect()
            return
        }

        guard isRecording || subtitleOverlay.viewModel.isActive else { return }

        let wasRecording = isRecording
        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil

        sessionDiscarded = true
        isRecording = false
        cancelConnectionRecovery()
        resetTranscriptSession()
        sessionAudioPCM.clear()
        uncommittedAudioPCM.clear()
        sessionPastedText = ""
        statusItem.button?.image = normalIcon
        rebuildMenu()

        if wasRecording {
            FeedbackSoundPlayer.playStop()
        }
        audioRecorder.stopRecording()
        subtitleOverlay.hide()
        sttProvider.disconnect()
    }

    // MARK: - Shortcut display

    private func shortcutDisplayString() -> String {
        if SettingsStore.shared.activationMode == .pressToSpeak {
            return SettingsStore.shared.pressToSpeakKey.displayName
        }

        let keys = SettingsStore.shared.shortcutKeys
        if keys.isTripleTap {
            return KeyboardUtils.formatModifierTapDisplay(
                modifier: keys.tapModifier ?? "command",
                tapCount: keys.tapCount
            )
        }

        let modifiers = NSEvent.ModifierFlags(rawValue: keys.modifiers)
        return KeyboardUtils.formatShortcutDisplay(modifiers: modifiers, keyCode: keys.keyCode)
    }

    @objc private func installUpdateFromMenu() {
        openSettings()
        // Give the Settings window a runloop tick to attach its observers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: .updateInstallRequested, object: nil)
        }
    }

    @objc private func checkForUpdatesFromMenu() {
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: .updateCheckRequested, object: nil)
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 700, height: 520)
            window.setContentSize(NSSize(width: 740, height: 600))
            window.center()
            window.setFrameAutosaveName("SettingsWindow")
            window.delegate = self
            settingsWindow = window
        }

        presentUtilityWindow(settingsWindow)
    }

    @objc private func openTeachDictionary() {
        guard !lastTranscript.isEmpty else { return }

        let transcript = lastTranscript
        let teachView = TeachDictionaryView(
            transcript: transcript,
            onSaved: { [weak self] in
                self?.teachWindow?.close()
                self?.teachWindow = nil
            },
            onCancel: { [weak self] in
                self?.teachWindow?.close()
                self?.teachWindow = nil
            }
        )

        let hostingController = NSHostingController(rootView: teachView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Teach Dictionary"
        window.styleMask = [.titled, .closable]
        window.center()
        window.delegate = self
        teachWindow = window

        presentUtilityWindow(window)
    }

    private func presentUtilityWindow(_ window: NSWindow?) {
        guard let window else { return }

        setupMainMenu()

        // Menu bar apps need .regular policy for text input to work
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // Reapply the icon after promoting, or the Dock tile renders blank.
            setAppIcon()
        }

        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            window.level = .normal
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        appMenu.addItem(settingsMenuItem)
        appMenu.addItem(NSMenuItem(title: "Quit Typester", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (enables Cmd+C, Cmd+V, Cmd+A, etc.)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    public func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === teachWindow {
            teachWindow = nil
        }

        // Reset to accessory policy when settings/onboarding/teach closes
        // (menu bar app behavior). The closing window itself still reports
        // isVisible == true inside willClose, so it must be excluded or the
        // Dock icon never hides.
        let closingWindow = notification.object as? NSWindow
        let remainingWindows = [settingsWindow, onboardingWindow, teachWindow].compactMap { $0 }
        let stillOpen = remainingWindows.contains { $0.isVisible && $0 !== closingWindow }
        if !stillOpen {
            DispatchQueue.main.async { [weak self] in
                self?.updateActivationPolicy()
            }
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if onboardingWindow == nil {
            let onboardingView = OnboardingView {
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                self.updateMonitoringMode()
            }
            let hostingController = NSHostingController(rootView: onboardingView)
            let window = NSWindow(contentViewController: hostingController)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.center()
            window.delegate = self
            onboardingWindow = window
        }

        // Single promotion path shared with settings/teach: promotes to
        // .regular, reapplies the Dock icon, and lets windowWillClose hand
        // the policy decision back to updateActivationPolicy() on close.
        presentUtilityWindow(onboardingWindow)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
