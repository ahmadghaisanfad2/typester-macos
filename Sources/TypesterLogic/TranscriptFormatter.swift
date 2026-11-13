import Foundation

/// Light local cleanup for punctuation spacing and sentence capitalization,
/// plus deterministic per-style punctuation normalization.
///
/// Capitalization follows punctuation: a word is capitalized only at the start
/// of a dictation and after a `.`, `?` or `!` that survives into the output.
/// When Casual drops a sentence period, the capital that went with it is
/// dropped too, unless the word looks like a name, acronym or dictionary term.
public enum TranscriptFormatter {
    /// - Parameters:
    ///   - preservedTerms: words whose casing must never be lowered (dictionary
    ///     terms, learned corrections), matched case-sensitively.
    ///   - continuesSentence: `true` when this text is pasted right after
    ///     earlier text from the same session that did not end a sentence, so
    ///     its first word is not a sentence start.
    public static func format(
        _ text: String,
        removeFillers: Bool = false,
        style: TranscriptStyle = .neutral,
        preservedTerms: [String] = [],
        continuesSentence: Bool = false
    ) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        if removeFillers {
            result = FillerWordRemover.removeFillers(from: result)
            guard !result.isEmpty else { return result }
        }

        result = collapseWhitespace(result)
        result = applyStyle(
            result,
            style: style,
            continuesSentence: continuesSentence,
            preservedTerms: preservedTerms
        )
        result = collapseWhitespace(result)
        result = tidyPunctuationSpacing(result)

        // Ensure a space after ,.;:!? when the next char is alphanumeric
        result = ensureSpaceAfterPunctuation(result)

        // Capitalize start of string and after .?! — Minimal keeps the model's casing.
        if style != .minimal {
            result = capitalizeSentences(result, capitalizeStart: !continuesSentence)
        }

        if style == .formal {
            result = ensureTerminalPunctuation(result)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether text pasted after `previous` (earlier output of the same
    /// dictation session) continues its sentence rather than starting a new one.
    public static func continuesSentence(after previous: String) -> Bool {
        let closers = CharacterSet(charactersIn: "\"'”’)]»").union(.whitespacesAndNewlines)
        let trimmed = previous.trimmingCharacters(in: closers)
        guard let last = trimmed.last else { return false }
        return !sentenceEnders.contains(last)
    }

    // MARK: - Style normalization

    private static let sentenceEnders: Set<Character> = [".", "?", "!"]

    private static func applyStyle(
        _ text: String,
        style: TranscriptStyle,
        continuesSentence: Bool,
        preservedTerms: [String]
    ) -> String {
        switch style {
        case .minimal:
            return removeCharacters(".,;:…", from: text)
        case .casual:
            // Built before stripping, while sentence boundaries are still visible.
            let protected = ProtectedWords(text: text, preservedTerms: preservedTerms)
            return stripSentencePeriods(text, lowercaseFirst: continuesSentence, protected: protected)
        case .neutral, .formal:
            return text
        }
    }

    /// Titles and dotted abbreviations whose period must survive Casual mode.
    private static let sentencePeriodAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "sr", "jr", "vs",
        "e.g", "i.e", "a.m", "p.m", "u.s", "u.k",
    ]

    /// Abbreviations that sit mid-sentence, so the word after them stays lowercase.
    private static let midSentenceAbbreviations: Set<String> = ["e.g", "i.e", "vs", "cf"]

    private static func removeCharacters(_ characters: String, from text: String) -> String {
        var output = ""
        for character in text where !characters.contains(character) {
            output.append(character)
        }
        return output
    }

    /// Drops a trailing sentence period from each word, preserving abbreviations.
    /// The word after a removed period loses its sentence-start capital (there
    /// is no longer a period to justify it) unless it is a protected word.
    private static func stripSentencePeriods(
        _ text: String,
        lowercaseFirst: Bool,
        protected: ProtectedWords
    ) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var lowercaseNext = lowercaseFirst
        for token in tokens {
            var current = token
            if lowercaseNext, !protected.keepsCapital(current) {
                current = lowercasingFirstLetter(current)
            }
            lowercaseNext = false

            guard current.hasSuffix(".") else {
                kept.append(current)
                continue
            }
            let stem = current.replacingOccurrences(of: "\\.+$", with: "", options: .regularExpression)
            if sentencePeriodAbbreviations.contains(stem.lowercased()) {
                kept.append(current)
            } else {
                if !stem.isEmpty { kept.append(stem) }
                lowercaseNext = true
            }
        }
        return kept.joined(separator: " ")
    }

    private static func lowercasingFirstLetter(_ token: String) -> String {
        guard let index = token.firstIndex(where: \.isLetter) else { return token }
        return token.replacingCharacters(
            in: index...index,
            with: token[index...index].lowercased()
        )
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        return text + "."
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    /// Removes a space left before a punctuation mark (e.g. after style stripping).
    private static func tidyPunctuationSpacing(_ text: String) -> String {
        var result = text
        for mark in [",", ".", "?", "!", ";", ":"] {
            result = result.replacingOccurrences(of: " \(mark)", with: mark)
        }
        return result
    }

    /// Leaves `3.5`, `1,000`, `10:30` and dotted abbreviations (`e.g.`, `a.m.`) intact.
    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var output = ""
        let chars = Array(text)
        for i in 0..<chars.count {
            let c = chars[i]
            output.append(c)
            guard ",.;:!?".contains(c), i + 1 < chars.count else { continue }
            let next = chars[i + 1]
            guard next != " ", next.isLetter || next.isNumber else { continue }
            let previous = i > 0 ? chars[i - 1] : " "
            let joinsNumber = ",.:".contains(c) && previous.isNumber && next.isNumber
            let dottedAbbreviation = c == "." && previous.isLetter && next.isLetter
                && i + 2 < chars.count && chars[i + 2] == "."
            if !joinsNumber && !dottedAbbreviation {
                output.append(" ")
            }
        }
        return output
    }

    /// Capitalizes the first letter of each sentence. A `.?!` ends a sentence
    /// only when followed by whitespace (so `3.5` does not), and the pending
    /// capital is cleared by the next word even if it starts with a digit.
    private static func capitalizeSentences(_ text: String, capitalizeStart: Bool) -> String {
        let chars = Array(text)
        var output = ""
        var capitalizeNext = capitalizeStart

        for i in chars.indices {
            let c = chars[i]
            if c.isLetter || c.isNumber {
                output += capitalizeNext && c.isLetter ? c.uppercased() : String(c)
                capitalizeNext = false
                continue
            }
            output.append(c)
            guard sentenceEnders.contains(c) else { continue }
            let atBoundary = i + 1 >= chars.count || chars[i + 1].isWhitespace
            if atBoundary && !(c == "." && endsMidSentenceAbbreviation(chars, periodIndex: i)) {
                capitalizeNext = true
            }
        }

        return output
    }

    private static func endsMidSentenceAbbreviation(_ chars: [Character], periodIndex: Int) -> Bool {
        var start = periodIndex
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        let word = String(chars[start..<periodIndex]).lowercased()
        return midSentenceAbbreviations.contains(word)
    }
}

/// Words whose capital must survive when Casual lowers a sentence-start capital.
private struct ProtectedWords {
    /// Dictionary terms plus names seen capitalized mid-sentence in this text.
    private var names: Set<String>

    init(text: String, preservedTerms: [String]) {
        names = Set(preservedTerms.flatMap { $0.split(separator: " ").map(Self.core) })

        // A word capitalized after a non-sentence-ending token is a name.
        let tokens = text.split(separator: " ")
        for (previous, token) in zip(tokens, tokens.dropFirst()) {
            guard let last = previous.last, !".?!".contains(last) else { continue }
            let word = Self.core(token)
            if word.first?.isUppercase == true { names.insert(word) }
        }
    }

    /// `true` when lowering this token's first letter would be wrong (or a no-op).
    func keepsCapital(_ token: String) -> Bool {
        let word = Self.core(token)
        guard let first = word.first, first.isUppercase else { return true }
        if names.contains(word) { return true }
        // Acronyms ("NASA") and mixed case ("iPhone", "McDonald").
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        // English first-person pronoun: I, I'm, I'll, I'd, I've.
        return word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
    }

    /// Strips surrounding punctuation, keeping inner apostrophes and hyphens.
    private static func core<S: StringProtocol>(_ token: S) -> String {
        token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
