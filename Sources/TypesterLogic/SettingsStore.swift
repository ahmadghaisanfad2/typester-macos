import Cocoa
import ServiceManagement
import Security

public extension Notification.Name {
    static let settingsChanged = Notification.Name("settingsChanged")
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

    private let shortcutKeysKey = "shortcutKeys"
    private let sttProviderKey = "sttProvider"
    private let activationModeKey = "activationMode"
    private let pressToSpeakKeyKey = "pressToSpeakKey"
    private let languageHintsKey = "languageHints"
    private let selectedMicrophoneKey = "selectedMicrophone"
    private let dictionaryTermsKey = "dictionaryTerms"
    private let correctionPairsKey = "correctionPairs"
    private let contextDomainKey = "contextDomain"
    private let contextTopicKey = "contextTopic"
    private let showStreamPreviewKey = "showStreamPreview"
    private let legacyShowStreamAnimationKey = "showStreamAnimation"
    private let playDictationSoundsKey = "playDictationSounds"
    private let keychainService = "com.typester.api"
    private let sonioxKeychainAccount = "soniox-api-key"
    private let deepgramKeychainAccount = "deepgram-api-key"

    private init() {
        loadShortcutKeys()
        loadActivationMode()
        loadPressToSpeakKey()
        loadLanguageHints()
        loadSelectedMicrophone()
        loadDictionaryTerms()
        loadCorrectionPairs()
        loadContextDomain()
        loadContextTopic()
        loadSTTProvider()
        loadFeedbackPreferences()
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

    public func applyReplacements(_ text: String) -> String {
        DictionaryHelpers.applyReplacements(text, pairs: correctionPairs)
    }

    public var sonioxTerms: [String] {
        DictionaryHelpers.mergeTerms(manual: dictionaryTerms, pairs: correctionPairs)
    }

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
            terms: sonioxTerms
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
    }

    // MARK: - API keys (Keychain)

    // Soniox API key
    public var apiKey: String? {
        get { getKeychainItem(account: sonioxKeychainAccount) }
        set {
            if let value = newValue {
                setKeychainItem(value, account: sonioxKeychainAccount)
            } else {
                deleteKeychainItem(account: sonioxKeychainAccount)
            }
            objectWillChange.send()
        }
    }

    // Deepgram API key
    public var deepgramApiKey: String? {
        get { getKeychainItem(account: deepgramKeychainAccount) }
        set {
            if let value = newValue {
                setKeychainItem(value, account: deepgramKeychainAccount)
            } else {
                deleteKeychainItem(account: deepgramKeychainAccount)
            }
            objectWillChange.send()
        }
    }

    private func getKeychainItem(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
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
