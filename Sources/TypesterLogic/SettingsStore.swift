import Cocoa
import ServiceManagement
import Security

public extension Notification.Name {
    static let settingsChanged = Notification.Name("settingsChanged")
    static let automaticDictionaryLearningChanged = Notification.Name("automaticDictionaryLearningChanged")
    static let floatingPillVisibilityChanged = Notification.Name("floatingPillVisibilityChanged")
}

public class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var launchAtLogin: Bool = false {
        didSet {
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    @Published public var shortcutKeys: ShortcutKeys = .defaultTripleCmd {
        didSet {
            saveShortcutKeys()
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published public var activationMode: ActivationMode = .pressToSpeak {
        didSet {
            saveActivationMode()
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published public var pressToSpeakKey: PressToSpeakKey = .fn {
        didSet {
            savePressToSpeakKey()
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published public var languageHints: [String] = [] {
        didSet {
            saveLanguageHints()
        }
    }

    @Published public var selectedMicrophoneID: String? = nil {
        didSet {
            saveSelectedMicrophone()
        }
    }

    @Published public var dictionaryTerms: [String] = [] {
        didSet {
            saveDictionaryTerms()
        }
    }

    @Published public var correctionPairs: [CorrectionPair] = [] {
        didSet {
            saveCorrectionPairs()
        }
    }

    @Published public var automaticDictionaryLearningEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                automaticDictionaryLearningEnabled,
                forKey: automaticDictionaryLearningEnabledKey
            )
            NotificationCenter.default.post(name: .automaticDictionaryLearningChanged, object: nil)
        }
    }

    @Published public var showLearningHUD: Bool = true {
        didSet {
            UserDefaults.standard.set(showLearningHUD, forKey: showLearningHUDKey)
        }
    }

    @Published public var contextDomain: String = "" {
        didSet {
            saveContextDomain()
        }
    }

    @Published public var contextTopic: String = "" {
        didSet {
            saveContextTopic()
        }
    }

    @Published public var sttProvider: STTProviderType = .soniox {
        didSet {
            saveSTTProvider()
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published public var openaiModel: OpenAITranscribeModel = .gptLiveTranscribe {
        didSet {
            UserDefaults.standard.set(openaiModel.rawValue, forKey: openaiModelKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published public var sonioxMode: SonioxTranscribeMode = .realtime {
        didSet {
            UserDefaults.standard.set(sonioxMode.rawValue, forKey: sonioxModeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Selected OpenRouter transcription model slug (e.g. `openai/whisper-large-v3`).
    @Published public var openrouterModelID: String = OpenRouterAPI.defaultModelID {
        didSet {
            let trimmed = openrouterModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != openrouterModelID {
                openrouterModelID = trimmed.isEmpty ? OpenRouterAPI.defaultModelID : trimmed
                return
            }
            UserDefaults.standard.set(openrouterModelID, forKey: openrouterModelIDKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Selected xAI transcription mode (real-time WebSocket vs async HTTP).
    @Published public var xaiMode: XaiTranscribeMode = .realtime {
        didSet {
            UserDefaults.standard.set(xaiMode.rawValue, forKey: xaiModeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    @Published public var showStreamPreview: Bool = true {
        didSet {
            UserDefaults.standard.set(showStreamPreview, forKey: showStreamPreviewKey)
        }
    }

    @Published public var playDictationSounds: Bool = false {
        didSet {
            UserDefaults.standard.set(playDictationSounds, forKey: playDictationSoundsKey)
        }
    }

    /// Playback level for dictation start/stop sounds, 0...1.
    @Published public var dictationSoundVolume: Float = 0.75 {
        didSet {
            let clamped = min(1, max(0, dictationSoundVolume))
            if clamped != dictationSoundVolume {
                dictationSoundVolume = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: dictationSoundVolumeKey)
        }
    }

    /// When true, keep Typester in the Dock with a regular activation policy.
    /// When false (default), it runs from the menu bar and only appears in the
    /// Dock while one of its windows is open.
    @Published public var showInDock: Bool = false {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: showInDockKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// When true, paste each time the STT provider detects a pause (endpoint).
    /// When false (default), keep streaming in the overlay and paste only when you stop.
    @Published public var pasteOnPause: Bool = false {
        didSet {
            UserDefaults.standard.set(pasteOnPause, forKey: pasteOnPauseKey)
        }
    }

    /// When true, leave the final transcript on the clipboard after pasting so it
    /// can be re-pasted manually with ⌘V into a different field. When false
    /// (default), the previous clipboard contents are restored after every paste.
    @Published public var copyTranscriptToClipboard: Bool = false {
        didSet {
            UserDefaults.standard.set(copyTranscriptToClipboard, forKey: copyTranscriptToClipboardKey)
        }
    }

    /// Strip hesitation fillers (uh, um, you know, …) before pasting.
    @Published public var removeFillerWords: Bool = true {
        didSet {
            UserDefaults.standard.set(removeFillerWords, forKey: removeFillerWordsKey)
        }
    }

    /// How much punctuation to keep in the finalized transcript. Steers the
    /// Soniox model through a context instruction and normalizes the text
    /// locally for every provider.
    @Published public var transcriptStyle: TranscriptStyle = .neutral {
        didSet {
            UserDefaults.standard.set(transcriptStyle.rawValue, forKey: transcriptStyleKey)
        }
    }

    /// Persistent Wispr-style floating pill that starts/stops dictation on click.
    @Published public var showFloatingPill: Bool = false {
        didSet {
            UserDefaults.standard.set(showFloatingPill, forKey: showFloatingPillKey)
            NotificationCenter.default.post(name: .floatingPillVisibilityChanged, object: nil)
        }
    }

    /// Screen edge the floating pill rests against (centered along it).
    @Published public var pillEdge: PillEdge = .bottom {
        didSet {
            UserDefaults.standard.set(pillEdge.rawValue, forKey: pillEdgeKey)
            NotificationCenter.default.post(name: .floatingPillVisibilityChanged, object: nil)
        }
    }

    /// Prefer the dictating user’s voice: keep only the first speaker after you
    /// start dictating (Soniox/Deepgram diarization). Noise isolation is left to
    /// the macOS mic mode — Apple voice processing on the mic path captures
    /// all-zero audio on some Macs, so Typester never enables it itself.
    /// Default off.
    @Published public var focusOnMyVoice: Bool = false {
        didSet {
            UserDefaults.standard.set(focusOnMyVoice, forKey: focusOnMyVoiceKey)
        }
    }

    private let shortcutKeysKey = "shortcutKeys"
    private let sttProviderKey = "sttProvider"
    private let openaiModelKey = "openaiModel"
    private let sonioxModeKey = "sonioxMode"
    private let openrouterModelIDKey = "openrouterModelID"
    private let xaiModeKey = "xaiMode"
    private let activationModeKey = "activationMode"
    private let pressToSpeakKeyKey = "pressToSpeakKey"
    private let languageHintsKey = "languageHints"
    private let selectedMicrophoneKey = "selectedMicrophone"
    private let dictionaryTermsKey = "dictionaryTerms"
    private let correctionPairsKey = "correctionPairs"
    private let automaticDictionaryLearningEnabledKey = "automaticDictionaryLearningEnabled"
    private let showLearningHUDKey = "showLearningHUD"
    private let contextDomainKey = "contextDomain"
    private let contextTopicKey = "contextTopic"
    private let showStreamPreviewKey = "showStreamPreview"
    private let legacyShowStreamAnimationKey = "showStreamAnimation"
    private let playDictationSoundsKey = "playDictationSounds"
    private let dictationSoundVolumeKey = "dictationSoundVolume"
    private let pasteOnPauseKey = "pasteOnPause"
    private let copyTranscriptToClipboardKey = "copyTranscriptToClipboard"
    private let removeFillerWordsKey = "removeFillerWords"
    private let transcriptStyleKey = "transcriptStyle"
    private let showFloatingPillKey = "showFloatingPill"
    private let pillEdgeKey = "pillEdge"
    private let showInDockKey = "showInDock"
    private let focusOnMyVoiceKey = "focusOnMyVoice"
    private let keychainService = "com.typester.api"
    /// Every provider key lives in this one item now, as a JSON payload.
    private let combinedKeychainAccount = "api-keys"
    /// Accounts holding a key, so the UI can answer without reading a secret.
    private let configuredAccountsKey = "configuredProviders"
    /// Set once the per-provider items have been folded into the payload.
    /// v2 on purpose: 1.25.6's first attempt marked the migration done even when
    /// macOS refused the reads, so it has to be attempted again for anyone who
    /// ran that build.
    private let keyStorageMigratedKey = "keyStorageMigratedV2"
    /// Set while stored keys exist but macOS has not authorised reading them.
    private let keychainAccessBlockedKey = "keychainAccessBlocked"
    private let sonioxKeychainAccount = "soniox-api-key"
    private let deepgramKeychainAccount = "deepgram-api-key"
    private let openaiKeychainAccount = "openai-api-key"
    private let openrouterKeychainAccount = "openrouter-api-key"
    private let xaiKeychainAccount = "xai-api-key"
    /// Process-lifetime cache: the Keychain is read at most once per launch.
    private var loadedPayload: APIKeyPayload?
    /// Legacy accounts that exist but could not be read in this session, so the
    /// fallback does not re-prompt on every dictation start.
    private var unreadableAccounts: Set<String> = []

    private init() {
        loadShortcutKeys()
        loadActivationMode()
        loadPressToSpeakKey()
        loadLanguageHints()
        loadSelectedMicrophone()
        loadDictionaryTerms()
        loadCorrectionPairs()
        loadAutomaticDictionaryLearningPreference()
        loadShowLearningHUDPreference()
        loadContextDomain()
        loadContextTopic()
        loadSTTProvider()
        loadOpenAIModel()
        loadSonioxMode()
        loadOpenRouterModelID()
        loadXaiMode()
        loadFeedbackPreferences()
        loadFocusOnMyVoicePreference()
        loadTranscriptStyle()
        syncLaunchAtLoginStatus()
    }

    // MARK: - Dictionary / Soniox context

    @discardableResult
    public func addCorrection(wrong: String, right: String) -> Bool {
        guard let updated = DictionaryHelpers.upsertCorrection(
            wrong: wrong,
            right: right,
            into: correctionPairs
        ) else {
            return false
        }
        correctionPairs = updated
        return true
    }

    public func removeCorrection(id: UUID) {
        correctionPairs.removeAll { $0.id == id }
    }

    @discardableResult
    public func addAutomaticCorrection(wrong: String, right: String) -> Bool {
        guard automaticDictionaryLearningEnabled,
              let updated = DictionaryHelpers.upsertCorrection(
                wrong: wrong,
                right: right,
                into: correctionPairs,
                source: .automatic,
                matchMode: .wordOrPhrase
              ),
              updated != correctionPairs else {
            return false
        }
        correctionPairs = updated
        return true
    }

    public func clearAutomaticCorrections() {
        correctionPairs.removeAll { $0.source == .automatic }
    }

    public func applyReplacements(_ text: String) -> String {
        DictionaryHelpers.applyReplacements(text, pairs: correctionPairs)
    }

    public var sonioxTerms: [String] {
        DictionaryHelpers.mergeTerms(manual: dictionaryTerms, pairs: correctionPairs)
    }

    /// Dictionary terms for providers that accept key-term hints (Soniox context / xAI keyterm).
    public var providerKeyterms: [String] { sonioxTerms }

    public var sonioxGeneral: [[String: String]] {
        var general: [[String: String]] = []
        let domain = contextDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = contextTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !domain.isEmpty {
            general.append(["key": "domain", "value": domain])
        }
        if !topic.isEmpty {
            general.append(["key": "topic", "value": topic])
        }
        return general
    }

    public func sonioxContext() -> [String: Any]? {
        DictionaryHelpers.buildSonioxContext(
            domain: contextDomain,
            topic: contextTopic,
            terms: sonioxTerms,
            instructions: transcriptStyle.sonioxInstructions
        )
    }

    public func syncLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Shortcut keys (UserDefaults)

    private func loadShortcutKeys() {
        guard let data = UserDefaults.standard.data(forKey: shortcutKeysKey),
              let keys = try? JSONDecoder().decode(ShortcutKeys.self, from: data) else {
            return
        }
        shortcutKeys = keys
    }

    private func saveShortcutKeys() {
        guard let data = try? JSONEncoder().encode(shortcutKeys) else { return }
        UserDefaults.standard.set(data, forKey: shortcutKeysKey)
    }

    private func loadActivationMode() {
        guard let rawValue = UserDefaults.standard.string(forKey: activationModeKey),
              let mode = ActivationMode(rawValue: rawValue) else {
            return
        }
        activationMode = mode
    }

    private func saveActivationMode() {
        UserDefaults.standard.set(activationMode.rawValue, forKey: activationModeKey)
    }

    private func loadPressToSpeakKey() {
        guard let rawValue = UserDefaults.standard.string(forKey: pressToSpeakKeyKey),
              let key = PressToSpeakKey(rawValue: rawValue) else {
            return
        }
        pressToSpeakKey = key
    }

    private func savePressToSpeakKey() {
        UserDefaults.standard.set(pressToSpeakKey.rawValue, forKey: pressToSpeakKeyKey)
    }

    private func loadLanguageHints() {
        if let hints = UserDefaults.standard.stringArray(forKey: languageHintsKey) {
            languageHints = hints
        }
    }

    private func saveLanguageHints() {
        UserDefaults.standard.set(languageHints, forKey: languageHintsKey)
    }

    private func loadSelectedMicrophone() {
        selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneKey)
    }

    private func saveSelectedMicrophone() {
        UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneKey)
    }

    private func loadDictionaryTerms() {
        if let terms = UserDefaults.standard.stringArray(forKey: dictionaryTermsKey) {
            dictionaryTerms = terms
        }
    }

    private func saveDictionaryTerms() {
        UserDefaults.standard.set(dictionaryTerms, forKey: dictionaryTermsKey)
    }

    private func loadCorrectionPairs() {
        guard let data = UserDefaults.standard.data(forKey: correctionPairsKey),
              let pairs = try? JSONDecoder().decode([CorrectionPair].self, from: data) else {
            return
        }
        correctionPairs = pairs
    }

    private func saveCorrectionPairs() {
        guard let data = try? JSONEncoder().encode(correctionPairs) else { return }
        UserDefaults.standard.set(data, forKey: correctionPairsKey)
    }

    private func loadAutomaticDictionaryLearningPreference() {
        if UserDefaults.standard.object(forKey: automaticDictionaryLearningEnabledKey) != nil {
            automaticDictionaryLearningEnabled = UserDefaults.standard.bool(
                forKey: automaticDictionaryLearningEnabledKey
            )
        }
    }

    private func loadShowLearningHUDPreference() {
        if UserDefaults.standard.object(forKey: showLearningHUDKey) != nil {
            showLearningHUD = UserDefaults.standard.bool(forKey: showLearningHUDKey)
        }
    }

    private func loadFocusOnMyVoicePreference() {
        if UserDefaults.standard.object(forKey: focusOnMyVoiceKey) != nil {
            focusOnMyVoice = UserDefaults.standard.bool(forKey: focusOnMyVoiceKey)
        }
    }

    private func loadTranscriptStyle() {
        guard let rawValue = UserDefaults.standard.string(forKey: transcriptStyleKey),
              let style = TranscriptStyle(rawValue: rawValue) else {
            return
        }
        transcriptStyle = style
    }

    private func loadContextDomain() {
        contextDomain = UserDefaults.standard.string(forKey: contextDomainKey) ?? ""
    }

    private func saveContextDomain() {
        UserDefaults.standard.set(contextDomain, forKey: contextDomainKey)
    }

    private func loadContextTopic() {
        contextTopic = UserDefaults.standard.string(forKey: contextTopicKey) ?? ""
    }

    private func saveContextTopic() {
        UserDefaults.standard.set(contextTopic, forKey: contextTopicKey)
    }

    private func loadSTTProvider() {
        guard let rawValue = UserDefaults.standard.string(forKey: sttProviderKey),
              let provider = STTProviderType(rawValue: rawValue) else {
            return
        }
        sttProvider = provider
    }

    private func saveSTTProvider() {
        UserDefaults.standard.set(sttProvider.rawValue, forKey: sttProviderKey)
    }

    private func loadOpenAIModel() {
        guard let rawValue = UserDefaults.standard.string(forKey: openaiModelKey),
              let model = OpenAITranscribeModel(rawValue: rawValue) else {
            return
        }
        openaiModel = model
    }

    private func loadSonioxMode() {
        guard let rawValue = UserDefaults.standard.string(forKey: sonioxModeKey),
              let mode = SonioxTranscribeMode(rawValue: rawValue) else {
            return
        }
        sonioxMode = mode
    }

    private func loadOpenRouterModelID() {
        guard let rawValue = UserDefaults.standard.string(forKey: openrouterModelIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return
        }
        openrouterModelID = rawValue
    }

    private func loadXaiMode() {
        guard let rawValue = UserDefaults.standard.string(forKey: xaiModeKey),
              let mode = XaiTranscribeMode(rawValue: rawValue) else {
            return
        }
        xaiMode = mode
    }

    private func loadFeedbackPreferences() {
        if UserDefaults.standard.object(forKey: showStreamPreviewKey) != nil {
            showStreamPreview = UserDefaults.standard.bool(forKey: showStreamPreviewKey)
        } else if UserDefaults.standard.object(forKey: legacyShowStreamAnimationKey) != nil {
            // Migrate previous toggle key.
            showStreamPreview = UserDefaults.standard.bool(forKey: legacyShowStreamAnimationKey)
        }
        if UserDefaults.standard.object(forKey: playDictationSoundsKey) != nil {
            playDictationSounds = UserDefaults.standard.bool(forKey: playDictationSoundsKey)
        }
        if UserDefaults.standard.object(forKey: dictationSoundVolumeKey) != nil {
            dictationSoundVolume = UserDefaults.standard.float(forKey: dictationSoundVolumeKey)
        }
        if UserDefaults.standard.object(forKey: pasteOnPauseKey) != nil {
            pasteOnPause = UserDefaults.standard.bool(forKey: pasteOnPauseKey)
        }
        if UserDefaults.standard.object(forKey: copyTranscriptToClipboardKey) != nil {
            copyTranscriptToClipboard = UserDefaults.standard.bool(forKey: copyTranscriptToClipboardKey)
        }
        if UserDefaults.standard.object(forKey: removeFillerWordsKey) != nil {
            removeFillerWords = UserDefaults.standard.bool(forKey: removeFillerWordsKey)
        }
        if UserDefaults.standard.object(forKey: showFloatingPillKey) != nil {
            showFloatingPill = UserDefaults.standard.bool(forKey: showFloatingPillKey)
        }
        if let raw = UserDefaults.standard.string(forKey: pillEdgeKey),
           let edge = PillEdge(rawValue: raw) {
            pillEdge = edge
        }
        if UserDefaults.standard.object(forKey: showInDockKey) != nil {
            showInDock = UserDefaults.standard.bool(forKey: showInDockKey)
        }
    }

    // MARK: - API keys (Keychain)

    /// Accounts holding a key, persisted so `hasAPIKey(for:)` never has to read
    /// a secret — reading one is what raises the login-password prompt.
    private var configuredAccounts: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: configuredAccountsKey) ?? [])
    }

    private func setConfiguredAccounts(_ accounts: Set<String>) {
        UserDefaults.standard.set(Array(accounts).sorted(), forKey: configuredAccountsKey)
    }

    /// True when a key is stored for `provider`, answered without Keychain
    /// access. The UI asks this on every render.
    public func hasAPIKey(for provider: STTProviderType) -> Bool {
        configuredAccounts.contains(keychainAccount(for: provider))
    }

    /// True when stored keys exist but macOS has not authorised this build to
    /// read them, so the UI can tell the user why a field looks empty instead
    /// of implying the key was lost.
    public var keychainAccessBlocked: Bool {
        get { UserDefaults.standard.bool(forKey: keychainAccessBlockedKey) }
        set { UserDefaults.standard.set(newValue, forKey: keychainAccessBlockedKey) }
    }

    private func keychainAccount(for provider: STTProviderType) -> String {
        switch provider {
        case .soniox: return sonioxKeychainAccount
        case .deepgram: return deepgramKeychainAccount
        case .openai: return openaiKeychainAccount
        case .openrouter: return openrouterKeychainAccount
        case .xai: return xaiKeychainAccount
        }
    }

    private var legacyKeychainAccounts: [String] {
        STTProviderType.allCases.map(keychainAccount(for:))
    }

    /// The keys, read from the Keychain at most once per process and then held.
    ///
    /// The configured-account list is reconciled from whatever is loaded: that
    /// list is what the UI reads, and leaving it stale — or empty, as happened
    /// when the payload was first written by a different process — makes stored
    /// keys look like they have vanished.
    private var keyPayload: APIKeyPayload {
        if let loadedPayload { return loadedPayload }

        let loaded = loadKeyPayload()
        loadedPayload = loaded.payload

        if loaded.readable {
            if configuredAccounts != loaded.payload.accounts {
                setConfiguredAccounts(loaded.payload.accounts)
            }
            // Now that macOS has handed the payload over, rewrite it so the
            // item's ACL belongs to this build. Replacing the item is what makes
            // the prompts stop for good.
            if keychainAccessBlocked {
                keychainAccessBlocked = false
                writePayload(loaded.payload)
            }
        } else {
            keychainAccessBlocked = true
        }
        return loaded.payload
    }

    private func loadKeyPayload() -> (payload: APIKeyPayload, readable: Bool) {
        switch readKeychainItem(account: combinedKeychainAccount) {
        case .value(let json):
            return (APIKeyPayload(json: json) ?? APIKeyPayload(), true)
        case .missing:
            return (APIKeyPayload(), true)
        case .unavailable:
            // A payload exists but macOS will not hand it over. That is not the
            // same as "no keys", and must never be recorded as such.
            return (APIKeyPayload(), false)
        }
    }

    /// Answers "which providers have keys" at launch, without ever raising a
    /// dialog, and records whether macOS refused so the UI can say so instead of
    /// pretending the key is gone.
    private func reconcileConfiguredAccounts() {
        switch readKeychainItem(account: combinedKeychainAccount, allowingPrompt: false) {
        case .value(let json):
            let payload = APIKeyPayload(json: json) ?? APIKeyPayload()
            loadedPayload = payload
            setConfiguredAccounts(payload.accounts)
            keychainAccessBlocked = false
        case .missing:
            loadedPayload = APIKeyPayload()
            setConfiguredAccounts([])
            keychainAccessBlocked = false
        case .unavailable:
            keychainAccessBlocked = true
        }
    }

    private func storeKey(_ value: String?, for account: String) {
        var payload = keyPayload
        payload.setKey(value, for: account)
        writePayload(payload)
        objectWillChange.send()
    }

    /// The key for `account`, falling back to the pre-1.25.6 per-provider item.
    ///
    /// The fallback is the safety net that keeps a denied or deferred migration
    /// from losing anything: the value is folded in the first time it is
    /// actually needed, which is also the only moment macOS can ask.
    private func storedKey(account: String) -> String? {
        if let value = keyPayload.key(for: account) { return value }
        guard !unreadableAccounts.contains(account) else { return nil }
        switch readKeychainItem(account: account) {
        case .value(let legacy) where !legacy.isEmpty:
            var payload = keyPayload
            payload.setKey(legacy, for: account)
            writePayload(payload)
            deleteKeychainItem(account: account)
            return legacy
        case .value, .missing:
            return nil
        case .unavailable:
            // Remember for this session only: retrying here would prompt on
            // every dictation start.
            unreadableAccounts.insert(account)
            return nil
        }
    }

    private func writePayload(_ payload: APIKeyPayload) {
        loadedPayload = payload
        setConfiguredAccounts(payload.accounts)
        guard let json = payload.json else { return }
        setKeychainItem(json, account: combinedKeychainAccount)
    }

    /// Folds the old one-item-per-provider storage into the single payload.
    ///
    /// Returns `false` when something exists but could not be read, meaning the
    /// caller must try again rather than record the keys as gone. Only the
    /// accounts actually read are deleted — an unreadable item is left alone.
    /// Every read here is prompt-free, because this runs at launch.
    /// The decision itself lives in `LegacyKeyMigration`, which is pure.
    @discardableResult
    private func migrateLegacyKeys() -> Bool {
        var existing = APIKeyPayload()
        var combinedReadable = true
        switch readKeychainItem(account: combinedKeychainAccount, allowingPrompt: false) {
        case .value(let json):
            existing = APIKeyPayload(json: json) ?? APIKeyPayload()
        case .missing:
            break
        case .unavailable:
            combinedReadable = false
        }

        let plan = LegacyKeyMigration.plan(
            existing: existing,
            accounts: legacyKeychainAccounts
        ) { account in
            self.readKeychainItem(account: account, allowingPrompt: false)
        }

        guard !plan.migratedAccounts.isEmpty else { return plan.complete && combinedReadable }

        // Merge, so a key entered since the last attempt is never overwritten.
        writePayload(plan.payload)
        for account in plan.migratedAccounts {
            deleteKeychainItem(account: account)
        }
        return plan.complete && combinedReadable
    }

    /// Re-reads the payload with the Keychain prompt allowed.
    ///
    /// Called from Settings when a background read was refused, so the user can
    /// hand over access deliberately. Without it they would be stuck: the
    /// configured-account list stays empty, dictation refuses to start for want
    /// of a key, and nothing would ever ask again.
    public func requestKeychainAccess() {
        let loaded = loadKeyPayload()
        loadedPayload = loaded.payload
        objectWillChange.send()

        guard loaded.readable else {
            keychainAccessBlocked = true
            return
        }

        keychainAccessBlocked = false
        setConfiguredAccounts(loaded.payload.accounts)
        // Rewrite so the item's ACL belongs to this build — replacing the item
        // is what stops the prompts for good from here on.
        guard !loaded.payload.keys.isEmpty else { return }
        writePayload(loaded.payload)
    }

    /// Runs once per install. A fresh install finds no legacy item, so it reads
    /// nothing that exists and raises no prompt at all.
    ///
    /// Called explicitly by the app at launch rather than from `load()`, and
    /// skipped under XCTest, because a test process touching the real Keychain
    /// does real damage: an earlier version of this ran from `load()`, a test run
    /// folded and deleted the user's items, and the bookkeeping landed in the
    /// test bundle's defaults domain where the app never saw it.
    public func migrateAPIKeyStorageIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !UserDefaults.standard.bool(forKey: keyStorageMigratedKey) else { return }

        let legacyComplete = migrateLegacyKeys()
        // Never prompt here: this runs while the app is starting.
        reconcileConfiguredAccounts()
        guard legacyComplete, !keychainAccessBlocked else { return }
        UserDefaults.standard.set(true, forKey: keyStorageMigratedKey)
    }

    // Soniox API key
    public var apiKey: String? {
        get { keyPayload.key(for: sonioxKeychainAccount) }
        set { storeKey(newValue, for: sonioxKeychainAccount) }
    }

    // Deepgram API key
    public var deepgramApiKey: String? {
        get { keyPayload.key(for: deepgramKeychainAccount) }
        set { storeKey(newValue, for: deepgramKeychainAccount) }
    }

    // OpenAI API key
    public var openaiApiKey: String? {
        get { keyPayload.key(for: openaiKeychainAccount) }
        set { storeKey(newValue, for: openaiKeychainAccount) }
    }

    // OpenRouter API key
    public var openrouterApiKey: String? {
        get { keyPayload.key(for: openrouterKeychainAccount) }
        set { storeKey(newValue, for: openrouterKeychainAccount) }
    }

    // xAI API key
    public var xaiApiKey: String? {
        get { keyPayload.key(for: xaiKeychainAccount) }
        set { storeKey(newValue, for: xaiKeychainAccount) }
    }

    /// Reads a generic-password item, keeping the difference between "there is
    /// no such item" and "there is one but macOS would not let us read it".
    /// Treating those the same is what silently dropped every stored key when
    /// the legacy items needed authorising.
    ///
    /// `allowingPrompt` must be false for anything that runs without the user
    /// waiting on it. Measured: a read of an item whose ACL does not authorise
    /// the build otherwise blocks behind a Keychain dialog — which left the app
    /// stuck at launch behind a prompt. With interaction off the same read
    /// returns `errSecInteractionNotAllowed` (-25293) immediately, while an
    /// absent item still reports `errSecItemNotFound` (-25300).
    private func readKeychainItem(
        account: String,
        allowingPrompt: Bool = true
    ) -> LegacyKeyMigration.ReadOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var previousInteraction = DarwinBoolean(true)
        if !allowingPrompt {
            SecKeychainGetUserInteractionAllowed(&previousInteraction)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer {
            if !allowingPrompt {
                SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue)
            }
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return .unavailable
            }
            return .value(string)
        case errSecItemNotFound:
            return .missing
        default:
            Debug.log("Keychain read for \(account) failed with status \(status)")
            return .unavailable
        }
    }

    private func setKeychainItem(_ value: String, account: String) {
        deleteKeychainItem(account: account)

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
