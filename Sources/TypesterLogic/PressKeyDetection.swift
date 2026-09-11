import Cocoa
import Carbon.HIToolbox

/// Pure detection helpers for press-to-speak keys (testable without a live event tap).
public enum PressKeyDetection {
    /// Whether a `flagsChanged` event should update press-to-speak state.
    /// Fn must be filtered to keyCode 63 — F-keys and other modifiers also
    /// touch `maskSecondaryFn` / can arrive while Fn is held and would
    /// otherwise look like spurious Fn up/down edges.
    public static func shouldApplyFlagsChanged(configured: PressToSpeakKey, keyCode: Int64) -> Bool {
        switch configured {
        case .fn:
            return keyCode == Int64(kVK_Function)
        case .leftCommand, .rightCommand, .leftOption, .rightOption,
             .leftControl, .rightControl, .leftShift, .rightShift:
            return true
        }
    }

    public static func isKeyDown(
        configured: PressToSpeakKey,
        keyCode: Int64,
        flags: CGEventFlags
    ) -> Bool {
        switch configured {
        case .fn:
            guard keyCode == Int64(kVK_Function) else { return false }
            return flags.contains(.maskSecondaryFn)
        case .leftCommand:
            return flags.rawValue & 0x00000008 != 0
        case .rightCommand:
            return flags.rawValue & 0x00000010 != 0
        case .leftOption:
            return flags.rawValue & 0x00000020 != 0
        case .rightOption:
            return flags.rawValue & 0x00000040 != 0
        case .leftControl:
            return flags.rawValue & 0x00000001 != 0
        case .rightControl:
            return flags.rawValue & 0x00002000 != 0
        case .leftShift:
            return flags.rawValue & 0x00000002 != 0
        case .rightShift:
            return flags.rawValue & 0x00000004 != 0
        }
    }
}
