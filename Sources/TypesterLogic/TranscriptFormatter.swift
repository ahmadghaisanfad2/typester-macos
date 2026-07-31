import Foundation

/// Light local cleanup for punctuation spacing and sentence capitalization.
public enum TranscriptFormatter {
    public static func format(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Collapse runs of whitespace to a single space
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Ensure a space after ,.;:!? when the next char is alphanumeric
        result = ensureSpaceAfterPunctuation(result)

        // Capitalize start of string and after .?!
        result = capitalizeSentences(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
