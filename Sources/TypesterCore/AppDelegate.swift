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
    private let historyStore = TranscriptHistoryStore.shared
    private var sttProvider: STTProvider!
    private var lastTranscript = ""

    private func createSTTProvider() -> STTProvider {
        switch SettingsStore.shared.sttProvider {
        case .soniox:
            return SonioxClient()
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
    private var sessionAudioPCM = Data()
    private var sessionAppName = ""
    private var sessionSampleRate: Double = 16_000
    private var sessionPastedText = ""
    private var isRetranscribing = false
    private var retranscribeEntryID: UUID?
    private var pendingFinalizeWorkItem: DispatchWorkItem?
    private var normalIcon: NSImage?
    private var recordingIcon: NSImage?
    private let subtitleOverlay = SubtitleOverlay.shared

    public override init() {
        super.init()
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

        // Show onboarding if selected provider has no API key
        if !hasAPIKeyForCurrentProvider() {
            showOnboarding()
        } else {
            updateMonitoringMode()
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

    @objc private func settingsChanged() {
        HotkeyManager.shared.registerHotkey()
        updateMonitoringMode()
        updateSTTProvider()
        rebuildMenu()
    }

    private func updateSTTProvider() {
        switch SettingsStore.shared.sttProvider {
        case .soniox:
            if sttProvider is SonioxClient { return }
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
            self.subtitleOverlay.hide()
            self.audioRecorder.stopRecording()
            if self.isRetranscribing {
                self.finishRetranscribe(success: false)
                return
            }
            guard self.isRecording else { return }
            self.isRecording = false
            self.statusItem.button?.image = self.normalIcon
            self.rebuildMenu()
        }

        sttProvider.onTranscript = { [weak self] text, isFinal in
            guard let self = self else { return }
            Debug.log("onTranscript: \"\(text)\" isFinal=\(isFinal)")
            if isFinal {
                self.accumulatedText += text
                self.lastInterimText = ""
                if !self.isRetranscribing {
                    self.subtitleOverlay.updateFinal(text)
                }
            } else {
                self.lastInterimText = text
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
            if self.isRetranscribing {
                self.handleRetranscribeFinalized()
                return
            }
            if self.sessionDiscarded {
                self.sessionDiscarded = false
                self.subtitleOverlay.hide()
                self.sttProvider.disconnect()
                return
            }
            self.pasteAccumulatedTranscript(saveHistory: true)
            self.subtitleOverlay.hide()
            self.sttProvider.disconnect()
        }

        sttProvider.onError = { [weak self] error in
            guard let self = self else { return }
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
            self.accumulatedText = ""
            self.lastInterimText = ""
            self.sessionPastedText = ""
            self.rebuildMenu()
            self.showError(error)
        }
    }

    private func onSTTConnected() {
        guard isRetranscribing, let id = retranscribeEntryID,
              let entry = historyStore.entries.first(where: { $0.id == id }),
              let url = historyStore.audioURL(for: entry),
              let pcm = try? Data(contentsOf: url), !pcm.isEmpty else {
            return
        }
        replayPCM(pcm, sampleRate: entry.sampleRate)
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
            return image
        }
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

        menu.addItem(makeRecentMenuItem())

        let teachItem = NSMenuItem(
            title: "Teach last transcript…",
            action: #selector(openTeachDictionary),
            keyEquivalent: ""
        )
        teachItem.target = self
        teachItem.isEnabled = !lastTranscript.isEmpty
        menu.addItem(teachItem)

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Typester",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        ))

        statusItem.menu = menu
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
            accumulatedText = ""
            lastInterimText = ""
        }

        if let text = raw {
            lastTranscript = text
            let replaced = SettingsStore.shared.applyReplacements(text)
            let formatted = TranscriptFormatter.format(replaced)
            let pasteText = formatted.hasSuffix(" ") ? formatted : formatted + " "
            textPaster.paste(pasteText)
            let stored = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
            if sessionPastedText.isEmpty {
                sessionPastedText = stored
            } else {
                sessionPastedText += " " + stored
            }
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
        let pcm = sessionAudioPCM
        let appName = sessionAppName
        let sampleRate = sessionSampleRate
        sessionAudioPCM = Data()

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
        textPaster.paste(pasteText)
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
        NSApp.setActivationPolicy(.accessory)
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
        accumulatedText = ""
        lastInterimText = ""
        rebuildMenu()

        sttProvider.connect()
    }

    private func replayPCM(_ pcm: Data, sampleRate: Double) {
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
        accumulatedText = ""
        lastInterimText = ""

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
        textPaster.paste(pasteText)

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

        audioRecorder.onAudioBuffer = { [weak self] data in
            guard let self else { return }
            if !self.isRetranscribing {
                self.sessionAudioPCM.append(data)
            }
            self.sttProvider.sendAudio(data)
        }

        audioRecorder.onAudioLevel = { [weak self] level in
            self?.subtitleOverlay.updateAudioLevel(level)
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
        } else {
            // Reset to accessory policy if not opening settings
            NSApp.setActivationPolicy(.accessory)
        }
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
        statusItem.button?.image = recordingIcon
        accumulatedText = ""
        lastInterimText = ""
        sessionAudioPCM = Data()
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
        isRecording = false
        sessionDiscarded = false
        statusItem.button?.image = normalIcon
        rebuildMenu()

        FeedbackSoundPlayer.playStop()

        audioRecorder.stopRecording()

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

        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil

        sessionDiscarded = true
        isRecording = false
        accumulatedText = ""
        lastInterimText = ""
        sessionAudioPCM = Data()
        sessionPastedText = ""
        statusItem.button?.image = normalIcon
        rebuildMenu()

        FeedbackSoundPlayer.playStop()
        audioRecorder.stopRecording()
        subtitleOverlay.hide()
        sttProvider.disconnect()
        sessionDiscarded = false
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

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 580, height: 500)
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

        // Reset to accessory policy when settings/onboarding/teach closes (menu bar app behavior)
        let remainingWindows = [settingsWindow, onboardingWindow, teachWindow].compactMap { $0 }
        let stillOpen = remainingWindows.contains { $0.isVisible }
        if !stillOpen, NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
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
            window.title = "Welcome to Typester"
            window.styleMask = [.titled, .closable]
            window.center()
            window.delegate = self
            onboardingWindow = window
        }

        setupMainMenu()

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        // Set icon after activation policy change
        setAppIcon()

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
