import Foundation

/// How provider transcript deltas should be joined when neither side is padded.
public enum TranscriptTokenJoinStyle: Equatable, Sendable {
    /// Tokens already include spaces at word boundaries (Soniox realtime tokens).
    /// Concatenate as-is; only insert a space when a speaker-filter skip sat
    /// between kept spans.
    case concatenate
    /// Provider emits unpadded word/spans (Deepgram diarized runs). Insert a
    /// single space between consecutive unpadded pieces so words do not glue.
    case spaceBetweenUnpadded
}

public enum TranscriptJoinPolicy {
    /// Joins `left` and `right` transcript pieces for `style`.
    public static func join(left: String, right: String, style: TranscriptTokenJoinStyle) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        switch style {
        case .concatenate:
            return left + right
        case .spaceBetweenUnpadded:
            if left.hasSuffix(" ") || right.hasPrefix(" ") { return left + right }
            return left + " " + right
        }
    }

    /// Join after speaker-filter dropped tokens between `left` and `right`.
    /// Always ensure a single boundary space so kept spans never glue.
    public static func joinAcrossFilterSkip(left: String, right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if left.hasSuffix(" ") || right.hasPrefix(" ") { return left + right }
        return left + " " + right
    }
}
