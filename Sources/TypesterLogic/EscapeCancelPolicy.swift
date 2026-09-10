import Carbon.HIToolbox

/// Decides whether Escape should cancel Typester and be swallowed so the
/// frontmost app does not also receive it.
public enum EscapeCancelPolicy {
    public struct Decision: Equatable {
        public let shouldCancel: Bool
        public let shouldConsumeEvent: Bool

        public init(shouldCancel: Bool, shouldConsumeEvent: Bool) {
            self.shouldCancel = shouldCancel
            self.shouldConsumeEvent = shouldConsumeEvent
        }
    }

    /// Overlay stays active during post-stop "Transcribing…" even after
    /// `isRecording` flips false — ESC must still work in that window.
    public static func decision(isRecording: Bool, isOverlayActive: Bool) -> Decision {
        let active = isRecording || isOverlayActive
        return Decision(shouldCancel: active, shouldConsumeEvent: active)
    }

    public static func isEscapeKeyCode(_ keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_Escape)
    }
}
