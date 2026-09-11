import Foundation

/// Removes common spoken filler words and disfluencies from transcripts.
///
/// Only near-meaningless hesitation sounds and standalone fillers are removed —
/// content words that can carry meaning (e.g. "like" as a verb) stay intact.
public enum FillerWordRemover {
    /// Pure hesitation sounds. Matched as whole tokens only.
    public static let defaultSoundFillers: Set<String> = [
        "uh", "uhh", "uhhh",
        "um", "umm", "ummm", "ummmm",
        "er", "err", "erm", "ermm",
        "ah", "ahh", "ahhh",
        "hm", "hmm", "hmhm", "hmmm",
        "mhm", "mm", "mmm", "mmhm",
        "huh",
    ]

    /// Multi-word filler phrases (matched as whole phrases, word-boundary).
    public static let defaultPhraseFillers: [String] = [
        "you know",
        "i mean",
        "sort of",
        "kind of",
        "or something",
        "at the end of the day",
    ]

    /// Removes filler tokens and phrases from `text`.
    ///
    /// - Parameters:
    ///   - text: Input transcript.
    ///   - soundFillers: Single-token fillers to strip.
    ///   - phraseFillers: Multi-word fillers to strip.
    /// - Returns: Cleaned text with collapsed whitespace and trimmed edges.
    public static func removeFillers(
        from text: String,
        soundFillers: Set<String> = defaultSoundFillers,
        phraseFillers: [String] = defaultPhraseFillers
    ) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Phrases first (longest first so "at the end of the day" wins over
        // any nested single word).
        for phrase in phraseFillers.sorted(by: { $0.count > $1.count }) {
            result = removePhrase(phrase, from: result)
        }

        result = removeSoundTokens(soundFillers, from: result)
        result = collapseWhitespace(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removePhrase(_ phrase: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        // Word boundaries around the whole phrase; optional trailing comma /
        // ellipsis that STT often attaches to fillers.
        let pattern = "(?<![\\p{L}\\p{N}])(\(escaped))(?:[,.…]?)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    private static func removeSoundTokens(_ fillers: Set<String>, from text: String) -> String {
        // Tokenize on whitespace, keeping punctuation attached so "um," matches "um".
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var kept: [String] = []
        for token in tokens {
            if isFillerToken(token, fillers: fillers) {
                continue
            }
            kept.append(token)
        }
        return kept.joined(separator: " ")
    }

    private static func isFillerToken(_ token: String, fillers: Set<String>) -> Bool {
        let trimmed = token
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:…-—\"'()[]"))
            .lowercased()
        guard !trimmed.isEmpty else { return false }
        return fillers.contains(trimmed)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        // Clean up space before punctuation left by a removed filler.
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        return result
    }
}
