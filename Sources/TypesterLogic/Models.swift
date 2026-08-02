import Cocoa

public let appVersion = "1.12.0"

public struct CorrectionPair: Codable, Equatable, Identifiable {
    public var id: UUID
    public var wrong: String
    public var right: String
    public var createdAt: Date

    public init(id: UUID = UUID(), wrong: String, right: String, createdAt: Date = Date()) {
        self.id = id
        self.wrong = wrong
        self.right = right
        self.createdAt = createdAt
    }
}

public enum DictionaryHelpers {
    public static let maxCorrectionPairs = 200
    public static let maxContextCharacters = 8000

    /// Apply correction pairs longest-`wrong` first (case-sensitive).
    public static func applyReplacements(_ text: String, pairs: [CorrectionPair]) -> String {
        let sorted = pairs
            .filter { !$0.wrong.isEmpty && $0.wrong != $0.right }
            .sorted { $0.wrong.count > $1.wrong.count }

        var result = text
        for pair in sorted {
            result = result.replacingOccurrences(of: pair.wrong, with: pair.right)
        }
        return result
    }

    /// Merge manual dictionary terms with correction `right` values (unique, order preserved).
    public static func mergeTerms(manual: [String], pairs: [CorrectionPair]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in manual + pairs.map(\.right) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Upsert by `wrong`; enforce max pairs by dropping oldest.
    public static func upsertCorrection(
        wrong: String,
        right: String,
        into pairs: [CorrectionPair],
        maxPairs: Int = maxCorrectionPairs
    ) -> [CorrectionPair]? {
        let wrongTrimmed = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrongTrimmed.isEmpty, !rightTrimmed.isEmpty, wrongTrimmed != rightTrimmed else {
            return nil
        }

        var updated = pairs
        if let index = updated.firstIndex(where: { $0.wrong == wrongTrimmed }) {
            updated[index].right = rightTrimmed
            updated[index].createdAt = Date()
        } else {
            updated.append(CorrectionPair(wrong: wrongTrimmed, right: rightTrimmed))
        }

        if updated.count > maxPairs {
            updated.sort { $0.createdAt < $1.createdAt }
            updated = Array(updated.suffix(maxPairs))
        }
        return updated
    }

    /// Build Soniox `context` object; trim terms if over character budget.
    public static func buildSonioxContext(
        domain: String,
        topic: String,
        terms: [String]
    ) -> [String: Any]? {
        var context: [String: Any] = [:]
        var general: [[String: String]] = []

        let domainTrimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let topicTrimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !domainTrimmed.isEmpty {
            general.append(["key": "domain", "value": domainTrimmed])
        }
        if !topicTrimmed.isEmpty {
            general.append(["key": "topic", "value": topicTrimmed])
        }
        if !general.isEmpty {
            context["general"] = general
        }

        var workingTerms = terms
        if !workingTerms.isEmpty {
            context["terms"] = workingTerms
        }

        guard !context.isEmpty else { return nil }

        // Trim terms from the end until under budget (prefer keeping general).
        while contextCharacterCount(context) > maxContextCharacters, !workingTerms.isEmpty {
            workingTerms.removeLast()
            if workingTerms.isEmpty {
                context.removeValue(forKey: "terms")
            } else {
                context["terms"] = workingTerms
            }
        }

        return context.isEmpty ? nil : context
    }

    private static func contextCharacterCount(_ context: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: context),
              let string = String(data: data, encoding: .utf8) else {
            return Int.max
        }
        return string.count
    }
}

public enum ActivationMode: String, Codable, CaseIterable {
    case hotkey = "hotkey"
    case pressToSpeak = "pressToSpeak"
}

public enum PressToSpeakKey: String, Codable, CaseIterable {
    case fn, leftCommand, rightCommand, leftOption, rightOption

    public var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .leftCommand: return "Left ⌘"
        case .rightCommand: return "Right ⌘"
        case .leftOption: return "Left ⌥"
        case .rightOption: return "Right ⌥"
        }
    }
}

public struct SupportedLanguage {
    public let code: String
    public let name: String
    public let flag: String
    public let isPopular: Bool

    public init(code: String, name: String, flag: String, isPopular: Bool = false) {
        self.code = code
        self.name = name
        self.flag = flag
        self.isPopular = isPopular
    }
}

public let supportedLanguages: [SupportedLanguage] = {
    let popular: [SupportedLanguage] = [
        SupportedLanguage(code: "en", name: "English", flag: "🇺🇸", isPopular: true),
        SupportedLanguage(code: "es", name: "Spanish", flag: "🇪🇸", isPopular: true),
        SupportedLanguage(code: "zh", name: "Chinese", flag: "🇨🇳", isPopular: true),
        SupportedLanguage(code: "fr", name: "French", flag: "🇫🇷", isPopular: true),
        SupportedLanguage(code: "de", name: "German", flag: "🇩🇪", isPopular: true),
        SupportedLanguage(code: "pt", name: "Portuguese", flag: "🇵🇹", isPopular: true),
    ]

    let others: [SupportedLanguage] = [
        SupportedLanguage(code: "af", name: "Afrikaans", flag: "🇿🇦"),
        SupportedLanguage(code: "sq", name: "Albanian", flag: "🇦🇱"),
        SupportedLanguage(code: "ar", name: "Arabic", flag: "🇸🇦"),
        SupportedLanguage(code: "az", name: "Azerbaijani", flag: "🇦🇿"),
        SupportedLanguage(code: "eu", name: "Basque", flag: "🇪🇸"),
        SupportedLanguage(code: "be", name: "Belarusian", flag: "🇧🇾"),
        SupportedLanguage(code: "bn", name: "Bengali", flag: "🇧🇩"),
        SupportedLanguage(code: "bs", name: "Bosnian", flag: "🇧🇦"),
        SupportedLanguage(code: "bg", name: "Bulgarian", flag: "🇧🇬"),
        SupportedLanguage(code: "ca", name: "Catalan", flag: "🇪🇸"),
        SupportedLanguage(code: "hr", name: "Croatian", flag: "🇭🇷"),
        SupportedLanguage(code: "cs", name: "Czech", flag: "🇨🇿"),
        SupportedLanguage(code: "da", name: "Danish", flag: "🇩🇰"),
        SupportedLanguage(code: "nl", name: "Dutch", flag: "🇳🇱"),
        SupportedLanguage(code: "et", name: "Estonian", flag: "🇪🇪"),
        SupportedLanguage(code: "fi", name: "Finnish", flag: "🇫🇮"),
        SupportedLanguage(code: "gl", name: "Galician", flag: "🇪🇸"),
        SupportedLanguage(code: "el", name: "Greek", flag: "🇬🇷"),
        SupportedLanguage(code: "gu", name: "Gujarati", flag: "🇮🇳"),
        SupportedLanguage(code: "he", name: "Hebrew", flag: "🇮🇱"),
        SupportedLanguage(code: "hi", name: "Hindi", flag: "🇮🇳"),
        SupportedLanguage(code: "hu", name: "Hungarian", flag: "🇭🇺"),
        SupportedLanguage(code: "id", name: "Indonesian", flag: "🇮🇩"),
        SupportedLanguage(code: "it", name: "Italian", flag: "🇮🇹"),
        SupportedLanguage(code: "ja", name: "Japanese", flag: "🇯🇵"),
        SupportedLanguage(code: "kn", name: "Kannada", flag: "🇮🇳"),
        SupportedLanguage(code: "kk", name: "Kazakh", flag: "🇰🇿"),
        SupportedLanguage(code: "ko", name: "Korean", flag: "🇰🇷"),
        SupportedLanguage(code: "lv", name: "Latvian", flag: "🇱🇻"),
        SupportedLanguage(code: "lt", name: "Lithuanian", flag: "🇱🇹"),
        SupportedLanguage(code: "mk", name: "Macedonian", flag: "🇲🇰"),
        SupportedLanguage(code: "ms", name: "Malay", flag: "🇲🇾"),
        SupportedLanguage(code: "ml", name: "Malayalam", flag: "🇮🇳"),
        SupportedLanguage(code: "mr", name: "Marathi", flag: "🇮🇳"),
        SupportedLanguage(code: "no", name: "Norwegian", flag: "🇳🇴"),
        SupportedLanguage(code: "fa", name: "Persian", flag: "🇮🇷"),
        SupportedLanguage(code: "pl", name: "Polish", flag: "🇵🇱"),
        SupportedLanguage(code: "pa", name: "Punjabi", flag: "🇮🇳"),
        SupportedLanguage(code: "ro", name: "Romanian", flag: "🇷🇴"),
        SupportedLanguage(code: "ru", name: "Russian", flag: "🇷🇺"),
        SupportedLanguage(code: "sr", name: "Serbian", flag: "🇷🇸"),
        SupportedLanguage(code: "sk", name: "Slovak", flag: "🇸🇰"),
        SupportedLanguage(code: "sl", name: "Slovenian", flag: "🇸🇮"),
        SupportedLanguage(code: "sw", name: "Swahili", flag: "🇰🇪"),
        SupportedLanguage(code: "sv", name: "Swedish", flag: "🇸🇪"),
        SupportedLanguage(code: "tl", name: "Tagalog", flag: "🇵🇭"),
        SupportedLanguage(code: "ta", name: "Tamil", flag: "🇱🇰"),
        SupportedLanguage(code: "te", name: "Telugu", flag: "🇮🇳"),
        SupportedLanguage(code: "th", name: "Thai", flag: "🇹🇭"),
        SupportedLanguage(code: "tr", name: "Turkish", flag: "🇹🇷"),
        SupportedLanguage(code: "uk", name: "Ukrainian", flag: "🇺🇦"),
        SupportedLanguage(code: "ur", name: "Urdu", flag: "🇵🇰"),
        SupportedLanguage(code: "vi", name: "Vietnamese", flag: "🇻🇳"),
        SupportedLanguage(code: "cy", name: "Welsh", flag: "🏴󠁧󠁢󠁷󠁬󠁳󠁿"),
    ]

    return popular + others
}()
public let githubOwner = "ahmadghaisanfad2"
public let githubRepo = "typester-macos"
public let githubURL = "https://github.com/\(githubOwner)/\(githubRepo)"
public let githubReleasesAPIURL = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest"
public let githubReleasesPageURL = "\(githubURL)/releases"

public struct ShortcutKeys: Codable, Equatable {
    public var modifiers: UInt
    public var keyCode: UInt16
    /// True when the shortcut is a modifier-only tap (not a Carbon key combo).
    public var isTripleTap: Bool
    /// Modifier identity: "command"/"option"/… or side-specific "rightOption"/"leftCommand"/…
    public var tapModifier: String?
    /// How many taps are required in the window (1 = single press). Defaults to 3 for legacy triple-tap saves.
    public var tapCount: Int

    public init(
        modifiers: UInt,
        keyCode: UInt16,
        isTripleTap: Bool,
        tapModifier: String? = nil,
        tapCount: Int = 1
    ) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.isTripleTap = isTripleTap
        self.tapModifier = tapModifier
        self.tapCount = max(1, tapCount)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try container.decode(UInt.self, forKey: .modifiers)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        isTripleTap = try container.decode(Bool.self, forKey: .isTripleTap)
        tapModifier = try container.decodeIfPresent(String.self, forKey: .tapModifier)
        // Legacy saves had no tapCount; triple-tap mode implied 3 presses.
        if let count = try container.decodeIfPresent(Int.self, forKey: .tapCount) {
            tapCount = max(1, count)
        } else {
            tapCount = isTripleTap ? 3 : 1
        }
    }

    public static let defaultTripleCmd = ShortcutKeys(
        modifiers: 0,
        keyCode: 0,
        isTripleTap: true,
        tapModifier: "command",
        tapCount: 3
    )
}
