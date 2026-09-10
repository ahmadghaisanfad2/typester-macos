import Cocoa
import Carbon.HIToolbox

/// Pure helpers for deciding whether a `keyDown` means the modifier is being
/// used as a chord (⌘C) versus a lone hotkey tap / press-to-speak hold.
///
/// Text fields and some hosts emit `keyDown` for the modifier key itself
/// (Command/Fn/…) while the user is only holding or tapping that modifier.
/// Treating those as chords cancels the hotkey whenever a text field has focus.
public enum KeyDownChordPolicy {
    public static func isModifierKeyCode(_ keyCode: Int64) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_Function:
            return true
        default:
            return false
        }
    }

    /// True when this keyDown should cancel a pending modifier-only activation.
    public static func shouldCancelPendingActivation(keyCode: Int64) -> Bool {
        !isModifierKeyCode(keyCode)
    }
}
