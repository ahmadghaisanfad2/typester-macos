import SwiftUI
import AVFoundation
import Carbon.HIToolbox
import AppKit
import TypesterCore

// MARK: - Sections

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case provider
    case dictation
    case dictionary
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .provider: return "Provider"
        case .dictation: return "Dictation"
        case .dictionary: return "Dictionary"
        case .permissions: return "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .provider: return "waveform"
        case .dictation: return "keyboard"
        case .dictionary: return "text.book.closed"
        case .permissions: return "checkmark.shield"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedSection: SettingsPane = .general
    @State private var sonioxKeyInput: String = ""
    @State private var deepgramKeyInput: String = ""
    @State private var openaiKeyInput: String = ""
    @State private var showSonioxKey = false
    @State private var showDeepgramKey = false
    @State private var showOpenAIKey = false
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var showingAddTerm = false
    @State private var updateStatus: String?
    @State private var isCheckingUpdate = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(Codex.hairline)
                .frame(width: 1)

            contentPane
        }
        .background(Codex.background)
        .tint(Codex.green)
        .frame(minWidth: 700, minHeight: 520)
        .sheet(isPresented: $showingAddTerm) {
            AddTermView { term in
                if !settings.dictionaryTerms.contains(term) {
                    settings.dictionaryTerms.append(term)
                }
            }
        }
        .onAppear {
            if let key = settings.apiKey {
                sonioxKeyInput = key
            }
            if let key = settings.deepgramApiKey {
                deepgramKeyInput = key
            }
            if let key = settings.openaiApiKey {
                openaiKeyInput = key
            }
            if let pane = ProcessInfo.processInfo.environment["TYPESTER_PANE"],
               let parsed = SettingsPane(rawValue: pane) {
                selectedSection = parsed
            }
            checkPermissions()
            settings.syncLaunchAtLoginStatus()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateCheckRequested)) { _ in
            checkForUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateInstallRequested)) { _ in
            if let pending = AppUpdater.shared.pending {
                confirmInstall(latest: pending.latest, dmgURL: pending.dmgURL, current: appVersion)
            } else {
                checkForUpdates()
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Codex.charcoal)
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Codex.mist)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Typester")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Codex.text)
                    Text("v\(appVersion)")
                        .font(.mono(10.5))
                        .foregroundStyle(Codex.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 20)

            ForEach(SettingsPane.allCases) { section in
                sidebarButton(for: section)
            }

            Spacer(minLength: 12)
        }
        .frame(width: 196)
        .padding(.bottom, 10)
        .background(Codex.sidebar)
    }

    private func sidebarButton(for section: SettingsPane) -> some View {
        let isActive = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 17)

                Text(section.title)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))

                Spacer()

                if isActive {
                    Circle()
                        .fill(Codex.green)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isActive ? Codex.text : Codex.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? Codex.surface : Color.clear)
            )
            .overlay(
                HairlineBorder(cornerRadius: 7, color: isActive ? Codex.hairline : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainFocusless)
        .padding(.horizontal, 8)
    }

    // MARK: Content pane

    private var contentPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch selectedSection {
                    case .general: generalSection
                    case .provider: providerSection
                    case .dictation: dictationSection
                    case .dictionary: dictionarySection
                    case .permissions: permissionsSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle()
                .fill(Codex.hairline)
                .frame(height: 1)

            statusBar
        }
        .background(Codex.background)
    }

    // MARK: General

    private var generalSection: some View {
        SettingsSection("General") {
            SettingsRow("Open at login", help: "Start Typester automatically when you sign in.") {
                Toggle("", isOn: $settings.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Codex.green)
            }

            SettingsRow("Show in Dock", help: "Keep the Typester icon in the Dock. Turn off to run from the menu bar only.") {
                Toggle("", isOn: $settings.showInDock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Codex.green)
            }

            SettingsRow("Live preview", help: "Stream interim text in the caption pill while you speak.") {
                Toggle("", isOn: $settings.showStreamPreview)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Codex.green)
            }

            SettingsRow("Dictation sounds", help: "Short tones when a dictation starts and stops.") {
                Toggle("", isOn: $settings.playDictationSounds)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Codex.green)
            }

            SettingsRow(
                "Sound volume",
                showsDivider: false,
                control: {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { Double(settings.dictationSoundVolume) },
                            set: { settings.dictationSoundVolume = Float($0) }
                        ), in: 0...1)
                        .frame(width: 130)

                        Text("\(Int((settings.dictationSoundVolume * 100).rounded()))%")
                            .font(.mono(11))
                            .foregroundStyle(Codex.textSecondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .opacity(settings.playDictationSounds ? 1 : 0.45)
                    .disabled(!settings.playDictationSounds)
                }
            )
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Speech-to-text provider") {
                VStack(alignment: .leading, spacing: 12) {
                    CodexSegmented(
                        options: STTProviderType.allCases.map {
                            (label: $0.displayName, value: $0)
                        },
                        selection: $settings.sttProvider
                    )

                    modelRow
                }
                .padding(14)
            }

            apiKeySection
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch settings.sttProvider {
        case .openai:
            HStack {
                Picker("Model", selection: $settings.openaiModel) {
                    ForEach(OpenAITranscribeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Spacer()

                Text(settings.openaiModel.rawValue)
                    .font(.mono(11))
                    .foregroundStyle(Codex.textTertiary)
            }
        case .soniox:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Mode", selection: $settings.sonioxMode) {
                        ForEach(SonioxTranscribeMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Spacer()

                    Text(settings.sonioxMode.modelID)
                        .font(.mono(11))
                        .foregroundStyle(Codex.textTertiary)
                }

                Text(settings.sonioxMode == .realtime
                     ? "Real-time streams live text while you speak."
                     : "Async records locally, then transcribes after you stop (no live text).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Codex.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .deepgram:
            HStack {
                Text("Model")
                    .font(.system(size: 13))
                    .foregroundStyle(Codex.textSecondary)

                Spacer()

                Text(settings.sttProvider.modelID)
                    .font(.mono(11))
                    .foregroundStyle(Codex.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var apiKeySection: some View {
        let (input, showKey, savedKey, onSave, link): (Binding<String>, Binding<Bool>, String?, (String?) -> Void, URL) = {
            switch settings.sttProvider {
            case .soniox:
                return ($sonioxKeyInput, $showSonioxKey, settings.apiKey, { settings.apiKey = $0 }, URL(string: "https://soniox.com")!)
            case .deepgram:
                return ($deepgramKeyInput, $showDeepgramKey, settings.deepgramApiKey, { settings.deepgramApiKey = $0 }, URL(string: "https://console.deepgram.com")!)
            case .openai:
                return ($openaiKeyInput, $showOpenAIKey, settings.openaiApiKey, { settings.openaiApiKey = $0 }, URL(string: "https://platform.openai.com/api-keys")!)
            }
        }()

        SettingsSection(
            "\(settings.sttProvider.displayName) API key",
            headerLink: ("Get key", link)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                apiKeyField(key: input, showKey: showKey, savedKey: savedKey, onSave: onSave)

                Text("Stored in your macOS Keychain — never leaves this Mac except to call the provider.")
                    .font(.system(size: 11))
                    .foregroundStyle(Codex.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Activation") {
                SettingsRow("Mode") {
                    CodexSegmented(
                        options: [
                            (label: "Hold key", value: ActivationMode.pressToSpeak),
                            (label: "Hotkey", value: ActivationMode.hotkey)
                        ],
                        selection: $settings.activationMode
                    )
                    .frame(width: 210)
                }

                if settings.activationMode == .pressToSpeak {
                    SettingsRow(
                        "Push key",
                        help: "Hold this key and speak; release to paste.",
                        showsDivider: false
                    ) {
                        Picker("Key", selection: $settings.pressToSpeakKey) {
                            ForEach(PressToSpeakKey.allCases, id: \.self) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 160)
                    }
                } else {
                    SettingsRow(
                        "Shortcut",
                        help: "Press to start recording; press again to stop.",
                        showsDivider: false
                    ) {
                        ShortcutRecorderView(
                            shortcut: Binding(
                                get: { shortcutDescription },
                                set: { _ in }
                            ),
                            shortcutKeys: Binding(
                                get: { settings.shortcutKeys },
                                set: { if let keys = $0 { settings.shortcutKeys = keys } }
                            )
                        )
                    }
                }
            }

            SettingsSection(
                "Transcription",
                footer: settings.sttProvider == .soniox && settings.sonioxMode == .async
                    ? "Paste on pause is unavailable in Soniox Async mode (no live endpoints while recording)."
                    : "Off (recommended): keep streaming while you speak and paste only when you stop. On: paste each time a short pause is detected."
            ) {
                SettingsRow(
                    "Paste on pause",
                    help: "Paste each utterance as soon as you pause.",
                    showsDivider: false
                ) {
                    Toggle("", isOn: $settings.pasteOnPause)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Codex.green)
                        .disabled(settings.sttProvider == .soniox && settings.sonioxMode == .async)
                        .opacity(settings.sttProvider == .soniox && settings.sonioxMode == .async ? 0.45 : 1)
                }
            }
        }
    }

    // MARK: Dictionary

    @ViewBuilder
    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(
                "Automatic learning",
                footer: "Typester watches only the text range it just pasted, for up to 30 seconds. Corrections stay on this Mac. Password and other secure fields are never observed."
            ) {
                SettingsRow(
                    "Learn from corrections",
                    help: "Automatically save short word or phrase corrections you make immediately after dictation.",
                    showsDivider: settings.showLearningHUD
                ) {
                    Toggle("", isOn: $settings.automaticDictionaryLearningEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Codex.green)
                }

                if settings.automaticDictionaryLearningEnabled {
                    SettingsRow(
                        "Show learned toast",
                        help: "Briefly show a small confirmation when a correction is saved.",
                        showsDivider: false
                    ) {
                        Toggle("", isOn: $settings.showLearningHUD)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(Codex.green)
                    }
                }
            }

            if settings.sttProvider == .deepgram {
                SettingsSection("Deepgram behavior") {
                    HStack(spacing: 10) {
                        Image(systemName: "info")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Codex.textTertiary)
                            .frame(width: 17)

                        Text("Learned corrections still replace matching words locally before paste. Deepgram does not receive Typester dictionary hints.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Codex.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(14)
                }
            } else {
                SettingsSection(
                    "Context",
                    footer: settings.sttProvider == .openai
                        ? "Optional domain and topic are sent as transcription context to OpenAI."
                        : "Optional domain and topic help Soniox bias recognition toward your subject matter."
                ) {
                    SettingsRow("Domain") {
                        TextField("e.g. Healthcare", text: $settings.contextDomain)
                            .textFieldStyle(.plain)
                            .fieldCard()
                            .frame(width: 240)
                    }

                    SettingsRow("Topic", showsDivider: false) {
                        TextField("e.g. Product standup", text: $settings.contextTopic)
                            .textFieldStyle(.plain)
                            .fieldCard()
                            .frame(width: 240)
                    }
                }

                dictionaryTermsSection
            }

            if !settings.correctionPairs.isEmpty {
                SettingsSection(
                    "Corrections",
                    footer: correctionFooter
                ) {
                    ForEach(Array(settings.correctionPairs.enumerated()), id: \.element.id) { index, pair in
                        correctionRow(
                            pair,
                            showsDivider: index < settings.correctionPairs.count - 1
                                || settings.correctionPairs.contains(where: { $0.source == .automatic })
                        )
                    }

                    if settings.correctionPairs.contains(where: { $0.source == .automatic }) {
                        HStack {
                            Spacer()
                            Button("Clear automatic corrections") {
                                settings.clearAutomaticCorrections()
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var dictionaryTermsSection: some View {
        SettingsSection(
            "Dictionary terms",
            footer: "Add domain-specific words, names, or technical terms to improve recognition accuracy."
        ) {
            if settings.dictionaryTerms.isEmpty {
                HStack {
                    Text("No terms yet. Add the names and jargon you dictate often.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Codex.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(14)

                Rectangle()
                    .fill(Codex.hairline)
                    .frame(height: 1)
                    .padding(.leading, 14)
            } else {
                ForEach(Array(settings.dictionaryTerms.enumerated()), id: \.element) { index, term in
                    termRow(term, showsDivider: index < settings.dictionaryTerms.count - 1)
                }
            }

            HStack {
                Spacer()
                Button {
                    showingAddTerm = true
                } label: {
                    Label("Add term", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .controlSize(.small)
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
        }
    }

    private var correctionFooter: String {
        switch settings.sttProvider {
        case .openai:
            return "Words are replaced locally before paste; correct terms are also sent as OpenAI keywords."
        case .soniox:
            return "Words are replaced locally before paste; correct terms are also sent to Soniox."
        case .deepgram:
            return "Words are replaced locally before paste. Deepgram does not receive dictionary hints."
        }
    }

    private func termRow(_ term: String, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(term)
                    .font(.mono(12))
                    .foregroundStyle(Codex.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                deleteButton {
                    settings.dictionaryTerms.removeAll { $0 == term }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if showsDivider {
                Rectangle()
                    .fill(Codex.hairline)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }

    private func correctionRow(_ pair: CorrectionPair, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(pair.wrong)
                        .strikethrough(true, color: Codex.textTertiary)
                        .foregroundStyle(Codex.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Codex.textTertiary)
                    Text(pair.right)
                        .foregroundStyle(Codex.text)
                }
                .font(.mono(12))
                .lineLimit(1)

                Text(pair.source == .automatic ? "Automatic" : "Taught")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(pair.source == .automatic ? Codex.green : Codex.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(pair.source == .automatic ? Codex.green.opacity(0.12) : Codex.surface)
                    )

                Spacer()

                deleteButton {
                    settings.removeCorrection(id: pair.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if showsDivider {
                Rectangle()
                    .fill(Codex.hairline)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }

    private func deleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Codex.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainFocusless)
        .help("Remove")
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        SettingsSection(
            "Permissions",
            footer: "Typester records audio locally and streams it to your provider for transcription. Audio never touches any other server."
        ) {
            SettingsRow("Microphone", help: "Needed to hear you speak.") {
                HStack(spacing: 8) {
                    StatusDot(ok: micPermissionGranted)

                    if micPermissionGranted {
                        Text("Granted")
                            .font(.system(size: 12))
                            .foregroundStyle(Codex.textSecondary)
                    } else {
                        Button("Request access") {
                            requestMicPermission()
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsRow(
                "Accessibility",
                help: accessibilityGranted
                    ? "Needed to paste text into other apps. Later updates keep this grant."
                    : "Drag the Typester icon into Privacy & Security → Accessibility. If the toggle is already on, remove Typester first, drop the icon in, then Relaunch — macOS does not apply a new grant until Typester restarts.",
                showsDivider: false
            ) {
                HStack(spacing: 8) {
                    StatusDot(ok: accessibilityGranted)

                    if accessibilityGranted {
                        Text("Granted")
                            .font(.system(size: 12))
                            .foregroundStyle(Codex.textSecondary)
                    } else {
                        DraggableAppIconTile()

                        Button("Open System Settings") {
                            TextPaster.openAccessibilitySettings()
                        }
                        .controlSize(.small)

                        Button("Relaunch") {
                            TextPaster.relaunchApp()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("v\(appVersion)")
                .font(.mono(11))
                .foregroundStyle(Codex.textTertiary)

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(Codex.textTertiary)

            Link("GitHub", destination: URL(string: githubURL)!)
                .font(.system(size: 11.5))
                .foregroundStyle(Codex.azure)

            if let updateStatus {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Codex.textTertiary)

                Text(updateStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(Codex.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                checkForUpdates()
            } label: {
                if isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Check for Updates")
                }
            }
            .controlSize(.small)
            .disabled(isCheckingUpdate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Codex.sidebar)
    }

    // MARK: Update checking

    private func checkForUpdates() {
        isCheckingUpdate = true
        updateStatus = "Checking for updates…"

        UpdateChecker.shared.checkForUpdates { outcome in
            isCheckingUpdate = false
            handleUpdateOutcome(outcome)
        }
    }

    private func handleUpdateOutcome(_ outcome: UpdateCheckOutcome) {
        switch outcome {
        case .upToDate(let current, let latest):
            updateStatus = "You're up to date (\(current); latest \(latest))."
            presentAlert(
                title: "You're up to date",
                message: "Typester \(current) is the latest release."
            )

        case .updateAvailable(let current, let latest, let dmgURL, _):
            updateStatus = "Update \(latest) available."
            AppUpdater.shared.pending = PendingUpdate(latest: latest, dmgURL: dmgURL)
            confirmInstall(latest: latest, dmgURL: dmgURL, current: current)

        case .noRelease:
            updateStatus = "No releases found on GitHub yet."
            presentAlert(
                title: "No releases found",
                message: "This fork has no published GitHub releases yet. Build a DMG locally and publish with scripts/publish-release.sh."
            )

        case .noDMGAsset(let latest):
            updateStatus = "Release \(latest) has no DMG asset."
            presentAlert(
                title: "DMG not found",
                message: "Release \(latest) exists but has no .dmg asset. Open \(githubReleasesPageURL) to inspect the release."
            )

        case .failure(let message):
            updateStatus = "Update check failed."
            presentAlert(title: "Update check failed", message: message)
        }
    }

    /// In-app update: download, replace the running app, relaunch. Permissions
    /// and settings carry over because every build shares one signing identity.
    private func confirmInstall(latest: String, dmgURL: URL, current: String) {
        guard AppUpdater.shared.isUpdateSupportedForCurrentInstall() else {
            updateStatus = "Update \(latest) available — manual install needed."
            let alert = NSAlert()
            alert.messageText = "Update available"
            alert.informativeText = "Typester \(latest) is available (you have \(current)), but Typester is running from a folder it cannot update in place. Download the DMG and move Typester to /Applications."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: githubReleasesPageURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Update to Typester \(latest)?"
        if StableSigningMigration.crossesSigningIdentityBoundary(
            current: current,
            target: latest
        ) {
            alert.informativeText = "Typester downloads the update, installs it in place, and relaunches. This update introduces a stable signing identity, so the old authorization does not transfer automatically. \(StableSigningMigration.keychainAuthorizationGuidance) Then remove and re-add /Applications/Typester.app in Privacy & Security → Accessibility. Future updates keep these grants."
        } else {
            alert.informativeText = "Typester downloads the update, installs it in place, and relaunches. Your settings and API keys stay on this Mac."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else {
            updateStatus = "Update \(latest) available — postponed."
            return
        }
        installUpdate(from: dmgURL, latest: latest)
    }

    private func installUpdate(from url: URL, latest: String) {
        isCheckingUpdate = true
        updateStatus = "Downloading update…"
        AppUpdater.shared.install(
            from: url,
            status: { text in
                updateStatus = text
            },
            completion: { result in
                isCheckingUpdate = false
                switch result {
                case .success:
                    updateStatus = "Update \(latest) installed — relaunching…"
                case .failure(let error):
                    updateStatus = "Update failed."
                    presentAlert(
                        title: "Update failed",
                        message: error.localizedDescription + "\n\nYou can also install manually from the releases page."
                    )
                }
            }
        )
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Permissions

    private func checkPermissions() {
        checkMicPermission()
        accessibilityGranted = TextPaster.checkAccessibilityPermission()
    }

    @ViewBuilder
    private func apiKeyField(
        key: Binding<String>,
        showKey: Binding<Bool>,
        savedKey: String?,
        onSave: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    if showKey.wrappedValue {
                        SingleLineTextField(text: key)
                    } else {
                        SecureField("", text: key)
                            .textFieldStyle(.plain)
                            .font(.mono(12.5))
                    }
                }
                .fieldCard()

                Button {
                    showKey.wrappedValue.toggle()
                } label: {
                    Image(systemName: showKey.wrappedValue ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(Codex.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plainFocusless)
                .help(showKey.wrappedValue ? "Hide key" : "Show key")

                if savedKey != nil && key.wrappedValue == savedKey {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Codex.green)
                        .help("Saved to Keychain")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if key.wrappedValue != (savedKey ?? "") {
                HStack(spacing: 8) {
                    Spacer()

                    Button("Cancel") {
                        key.wrappedValue = savedKey ?? ""
                    }
                    .controlSize(.small)

                    Button("Save") {
                        onSave(key.wrappedValue.isEmpty ? nil : key.wrappedValue)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var shortcutDescription: String {
        let keys = settings.shortcutKeys
        if keys.isTripleTap {
            return KeyboardUtils.formatModifierTapDisplay(
                modifier: keys.tapModifier ?? "command",
                tapCount: keys.tapCount
            )
        }
        let modifiers = NSEvent.ModifierFlags(rawValue: keys.modifiers)
        return KeyboardUtils.formatShortcutDisplay(modifiers: modifiers, keyCode: keys.keyCode)
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micPermissionGranted = granted
            }
        }
    }
}

// MARK: - Mono key input

private struct SingleLineTextField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .none
        if let cell = textField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
            cell.lineBreakMode = .byTruncatingHead
        }
        textField.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textField.textColor = .labelColor
        textField.placeholderString = "sk-…"
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: SingleLineTextField

        init(_ parent: SingleLineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }
    }
}

// MARK: - Add term

struct AddTermView: View {
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        term.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add term")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Codex.text)

                TextField("Word or phrase", text: $term)
                    .textFieldStyle(.plain)
                    .font(.mono(12.5))
                    .fieldCard(focused: focused)
                    .focused($focused)
                    .onSubmit(save)
            }
            .padding(16)

            Rectangle()
                .fill(Codex.hairline)
                .frame(height: 1)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 320)
        .background(Codex.background)
        .tint(Codex.green)
        .onAppear {
            focused = true
        }
    }

    private func save() {
        if !trimmed.isEmpty {
            onSave(trimmed)
        }
        dismiss()
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorderView: View {
    @Binding var shortcut: String
    @Binding var shortcutKeys: ShortcutKeys?
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording.toggle()
            } label: {
                HStack(spacing: 8) {
                    if isRecording {
                        Circle()
                            .fill(Color(hex: 0xD99431))
                            .frame(width: 6, height: 6)
                        Text("Press keys…")
                            .font(.system(size: 12))
                            .foregroundStyle(Codex.textSecondary)
                    } else if shortcut.isEmpty {
                        Text("Record shortcut")
                            .font(.system(size: 12))
                            .foregroundStyle(Codex.textSecondary)
                    } else {
                        KeyToken(text: shortcut)
                    }
                }
                .frame(width: 168, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainFocusless)
            .fieldCard(focused: isRecording)
            .background(
                ShortcutRecorderHelper(
                    isRecording: $isRecording,
                    shortcut: $shortcut,
                    shortcutKeys: $shortcutKeys
                )
            )

            if !shortcut.isEmpty {
                Button {
                    shortcut = ""
                    shortcutKeys = .defaultTripleCmd
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Codex.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plainFocusless)
                .help("Reset to triple ⌘")
            }
        }
    }
}

struct ShortcutRecorderHelper: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var shortcut: String
    @Binding var shortcutKeys: ShortcutKeys?

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutRecorderNSView()
        view.onShortcutRecorded = { keys, displayString in
            shortcut = displayString
            shortcutKeys = keys
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? ShortcutRecorderNSView {
            view.isRecording = isRecording
        }
    }
}

class ShortcutRecorderNSView: NSView {
    var isRecording = false
    var onShortcutRecorded: ((ShortcutKeys, String) -> Void)?

    private var monitor: Any?
    private var pendingModifierIdentity: String?
    private var pendingUsedAsChord = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupMonitor()
    }

    private func setupMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }

            if event.type == .flagsChanged {
                guard let identity = HotkeyManager.modifierIdentity(keyCode: event.keyCode) else {
                    return event
                }

                let isDown = HotkeyManager.isIdentityDown(identity, flags: event.modifierFlags)

                if isDown {
                    // Start a single-modifier capture; finalize on release if unused as a chord.
                    self.pendingModifierIdentity = identity
                    self.pendingUsedAsChord = false
                    return nil
                }

                if let pending = self.pendingModifierIdentity, pending == identity, !self.pendingUsedAsChord {
                    self.pendingModifierIdentity = nil
                    let keys = ShortcutKeys(
                        modifiers: 0,
                        keyCode: 0,
                        isTripleTap: true,
                        tapModifier: identity,
                        tapCount: 1
                    )
                    let display = KeyboardUtils.formatModifierTapDisplay(modifier: identity, tapCount: 1)
                    self.onShortcutRecorded?(keys, display)
                    return nil
                }

                self.pendingModifierIdentity = nil
                self.pendingUsedAsChord = false
                return event
            }

            if event.type == .keyDown {
                if self.pendingModifierIdentity != nil {
                    // Modifier+key chord while capturing a lone modifier — treat as combo instead.
                    self.pendingUsedAsChord = true
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    let keyCode = event.keyCode
                    let displayString = KeyboardUtils.formatShortcutDisplay(modifiers: modifiers, keyCode: keyCode)
                    let keys = ShortcutKeys(
                        modifiers: modifiers.rawValue,
                        keyCode: keyCode,
                        isTripleTap: false,
                        tapModifier: nil,
                        tapCount: 1
                    )
                    self.pendingModifierIdentity = nil
                    self.pendingUsedAsChord = false
                    self.onShortcutRecorded?(keys, displayString)
                    return nil
                }

                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let keyCode = event.keyCode
                let displayString = KeyboardUtils.formatShortcutDisplay(modifiers: modifiers, keyCode: keyCode)
                let keys = ShortcutKeys(
                    modifiers: modifiers.rawValue,
                    keyCode: keyCode,
                    isTripleTap: false,
                    tapModifier: nil,
                    tapCount: 1
                )
                self.onShortcutRecorded?(keys, displayString)
                return nil
            }

            return event
        }
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
