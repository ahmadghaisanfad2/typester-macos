import Foundation

/// How provider transcript deltas should be joined when neither side is padded.
public enum TranscriptTokenJoinStyle: Equatable, Sendable {
    /// Tokens already include spaces at word boundaries (Soniox realtime tokens).
    /// Concatenate as-is, even across a speaker-filter skip — the kept tokens
    /// already carry their own spacing, so forcing one would split words.
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
    ///
    /// For `.spaceBetweenUnpadded` the kept spans are unpadded word runs, so a
    /// single boundary space is inserted. For `.concatenate` the kept tokens
    /// already carry their own word-boundary spacing (Soniox), so a forced
    /// space here would split a word that a dropped token interrupted.
    public static func joinAcrossFilterSkip(
        left: String,
        right: String,
        style: TranscriptTokenJoinStyle
    ) -> String {
        join(left: left, right: right, style: style)
    }
}
