import Foundation

/// Light local cleanup for punctuation spacing and sentence capitalization,
/// plus deterministic per-style punctuation normalization.
public enum TranscriptFormatter {
    public static func format(
        _ text: String,
        removeFillers: Bool = false,
        style: TranscriptStyle = .neutral
    ) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        if removeFillers {
            result = FillerWordRemover.removeFillers(from: result)
            guard !result.isEmpty else { return result }
        }

        result = collapseWhitespace(result)
        result = applyStyle(result, style: style)
        result = collapseWhitespace(result)
        result = tidyPunctuationSpacing(result)

        // Ensure a space after ,.;:!? when the next char is alphanumeric
        result = ensureSpaceAfterPunctuation(result)

        // Capitalize start of string and after .?! — Minimal keeps the model's casing.
        if style != .minimal {
            result = capitalizeSentences(result)
        }

        if style == .formal {
            result = ensureTerminalPunctuation(result)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Style normalization

    private static func applyStyle(_ text: String, style: TranscriptStyle) -> String {
        switch style {
        case .minimal:
            return removeCharacters(".,;:…", from: text)
        case .casual:
            return stripSentencePeriods(text)
        case .neutral, .formal:
            return text
        }
    }

    /// Titles and dotted abbreviations whose period must survive Casual mode.
    private static let sentencePeriodAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "sr", "jr", "vs",
        "e.g", "i.e", "a.m", "p.m", "u.s", "u.k",
    ]

    private static func removeCharacters(_ characters: String, from text: String) -> String {
        var output = ""
        for character in text where !characters.contains(character) {
            output.append(character)
        }
        return output
    }

    /// Drops a trailing sentence period from each word, preserving abbreviations.
    /// The word after a removed period is still capitalized so the following
    /// sentence does not end up lowercase.
    private static func stripSentencePeriods(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var capitalizeNext = false
        for token in tokens {
            var current = token
            if capitalizeNext, let first = current.first, first.isLetter {
                current = String(first).uppercased() + String(current.dropFirst())
            }
            capitalizeNext = false

            guard current.hasSuffix(".") else {
                kept.append(current)
                continue
            }
            let stem = current.replacingOccurrences(of: "\\.+$", with: "", options: .regularExpression)
            if sentencePeriodAbbreviations.contains(stem.lowercased()) {
                kept.append(current)
            } else {
                if !stem.isEmpty { kept.append(stem) }
                capitalizeNext = true
            }
        }
        return kept.joined(separator: " ")
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

    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var output = ""
        let chars = Array(text)
        for i in 0..<chars.count {
            let c = chars[i]
            output.append(c)
            if ",.;:!?".contains(c), i + 1 < chars.count {
                let next = chars[i + 1]
                if next != " " && (next.isLetter || next.isNumber) {
                    output.append(" ")
                }
            }
        }
        return output
    }

    private static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = true

        for i in 0..<chars.count {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if ".?!".contains(c) {
                capitalizeNext = true
            } else if !c.isWhitespace {
                // Keep capitalizeNext for whitespace between sentence end and next word
            }
        }

        return String(chars)
    }
}
