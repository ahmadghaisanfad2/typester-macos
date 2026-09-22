import Foundation

/// Assembles provider transcript deltas for one dictation session.
///
/// Final text is append-only because Soniox final tokens are deltas. Interim
/// text is a replacement snapshot and is cleared whenever final text arrives.
/// Keeping this state session-scoped prevents a reconnect or a new dictation
/// from inheriting text from the previous socket.
public final class TranscriptSessionAssembler {
    public private(set) var finalText = ""
    public private(set) var interimText = ""
    public var joinStyle: TranscriptTokenJoinStyle

    public init(joinStyle: TranscriptTokenJoinStyle = SettingsStore.shared.sttProvider.transcriptJoinStyle) {
        self.joinStyle = joinStyle
    }

    public func reset() {
        finalText = ""
        interimText = ""
    }

    /// Updates the join style when the active provider changes at runtime.
    public func updateJoinStyle(_ style: TranscriptTokenJoinStyle) {
        joinStyle = style
    }

    public func appendFinal(_ text: String) {
        guard !text.isEmpty else { return }
        finalText = TranscriptJoinPolicy.join(left: finalText, right: text, style: joinStyle)
        interimText = ""
    }

    public func replaceInterim(_ text: String) {
        interimText = text
    }

    public var resolvedText: String? {
        TranscriptPastePayload.resolve(
            accumulatedText: finalText,
            lastInterimText: interimText
        )
    }
}
