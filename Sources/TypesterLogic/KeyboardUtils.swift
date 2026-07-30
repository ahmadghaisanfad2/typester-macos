import Carbon.HIToolbox
import AppKit

/// Utilities for converting key codes to displayable strings.
public enum KeyboardUtils {
    /// Converts a key code to a human-readable character using the current keyboard layout.
    /// Returns nil for special keys (use `keyCodeToString` for complete display).
    public static func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let result = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard result == noErr && length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Converts a key code to a display string, handling special keys.
    public static func keyCodeToString(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let char = keyCodeToCharacter(keyCode) {
                return char.uppercased()
            }
            return "?"
        }
    }

    /// Formats a keyboard shortcut with modifiers for display.
    /// Modifiers are displayed in standard order: ⌃⌥⇧⌘
    public static func formatShortcutDisplay(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += keyCodeToString(keyCode)
        return result
    }

    /// Formats a modifier-tap display string.
    /// - Single tap: "Right ⌥", "⌘", etc.
    /// - Multi tap: "⌘⌘⌘"
    public static func formatModifierTapDisplay(modifier: String, tapCount: Int = 1) -> String {
        let count = max(1, tapCount)

        switch modifier {
        case "leftCommand": return count == 1 ? "Left ⌘" : String(repeating: "⌘", count: count)
        case "rightCommand": return count == 1 ? "Right ⌘" : String(repeating: "⌘", count: count)
        case "leftOption": return count == 1 ? "Left ⌥" : String(repeating: "⌥", count: count)
        case "rightOption": return count == 1 ? "Right ⌥" : String(repeating: "⌥", count: count)
        case "leftControl": return count == 1 ? "Left ⌃" : String(repeating: "⌃", count: count)
        case "rightControl": return count == 1 ? "Right ⌃" : String(repeating: "⌃", count: count)
        case "leftShift": return count == 1 ? "Left ⇧" : String(repeating: "⇧", count: count)
        case "rightShift": return count == 1 ? "Right ⇧" : String(repeating: "⇧", count: count)
        case "command": return String(repeating: "⌘", count: count)
        case "option": return String(repeating: "⌥", count: count)
        case "control": return String(repeating: "⌃", count: count)
        case "shift": return String(repeating: "⇧", count: count)
        default: return ""
        }
    }

    /// Formats a triple-tap modifier display string (e.g., "⌘⌘⌘").
    public static func formatTripleTapDisplay(modifier: String) -> String {
        formatModifierTapDisplay(modifier: modifier, tapCount: 3)
    }
}
