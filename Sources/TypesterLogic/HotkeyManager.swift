import Cocoa
import Carbon.HIToolbox

public class HotkeyManager {
    public static let shared = HotkeyManager()

    private var hotkeyRef: EventHotKeyRef?

    // Modifier-tap tracking
    private var modifierPressTimestamps: [String: [Date]] = [:]
    private let tapWindow: TimeInterval = 0.5
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var previousModifierFlags: NSEvent.ModifierFlags = []

    /// Armed single-tap: fire on release if not used as a chord modifier.
    private var pendingSingleTapIdentity: String?
    private var pendingSingleTapUsedAsModifier = false

    public var onHotkeyTriggered: (() -> Void)?
    /// Fired when Escape is pressed (global or local). Used to cancel dictation.
    public var onEscapePressed: (() -> Void)?

    private init() {
        installCarbonHandler()
        installModifierTapMonitors()
    }

    // MARK: - Carbon hotkeys (works without accessibility permission)

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )

                HotkeyManager.shared.handleHotkey()
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    private func handleHotkey() {
        guard SettingsStore.shared.activationMode == .hotkey else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onHotkeyTriggered?()
        }
    }

    public func registerHotkey() {
        unregisterHotkey()

        let keys = SettingsStore.shared.shortcutKeys
        guard !keys.isTripleTap else { return }

        let hotkeyID = EventHotKeyID(signature: OSType(0x5459_5053), id: 1) // "TYPS"

        let modifiers = carbonModifiers(from: NSEvent.ModifierFlags(rawValue: keys.modifiers))

        _ = RegisterEventHotKey(
            UInt32(keys.keyCode),
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
    }

    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    // MARK: - Modifier-tap monitors (single or multi tap)

    private func installModifierTapMonitors() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            DispatchQueue.main.async { [weak self] in
                self?.onEscapePressed?()
            }
        }
        noteKeyDownWhilePending()
    }

    private func noteKeyDownWhilePending() {
        guard pendingSingleTapIdentity != nil else { return }
        pendingSingleTapUsedAsModifier = true
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let keys = SettingsStore.shared.shortcutKeys
        guard keys.isTripleTap, let configured = keys.tapModifier else {
            previousModifierFlags = event.modifierFlags
            return
        }

        guard let identity = Self.modifierIdentity(keyCode: event.keyCode) else {
            previousModifierFlags = event.modifierFlags
            return
        }

        let flags = event.modifierFlags
        let wasDown = Self.isIdentityDown(identity, flags: previousModifierFlags)
        let isDown = Self.isIdentityDown(identity, flags: flags)
        defer { previousModifierFlags = flags }

        let matches = Self.matchesConfigured(identity: identity, configured: configured)

        if keys.tapCount <= 1 {
            handleSingleTap(
                identity: identity,
                matches: matches,
                wasDown: wasDown,
                isDown: isDown
            )
            return
        }

        // Multi-tap (legacy triple-tap): count presses within the window.
        guard matches, isDown, !wasDown else { return }

        let now = Date()
        var timestamps = modifierPressTimestamps[configured] ?? []
        timestamps.append(now)
        timestamps = timestamps.filter { now.timeIntervalSince($0) < tapWindow }
        modifierPressTimestamps[configured] = timestamps

        if timestamps.count >= keys.tapCount {
            modifierPressTimestamps[configured] = []
            handleHotkey()
        }
    }

    private func handleSingleTap(identity: String, matches: Bool, wasDown: Bool, isDown: Bool) {
        if matches, isDown, !wasDown {
            pendingSingleTapIdentity = identity
            pendingSingleTapUsedAsModifier = false
            return
        }

        if matches, !isDown, wasDown, pendingSingleTapIdentity == identity {
            let shouldFire = !pendingSingleTapUsedAsModifier
            pendingSingleTapIdentity = nil
            pendingSingleTapUsedAsModifier = false
            if shouldFire {
                handleHotkey()
            }
        }
    }

    /// Maps a flagsChanged keyCode to a side-specific modifier identity.
    public static func modifierIdentity(keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Command: return "leftCommand"
        case kVK_RightCommand: return "rightCommand"
        case kVK_Option: return "leftOption"
        case kVK_RightOption: return "rightOption"
        case kVK_Control: return "leftControl"
        case kVK_RightControl: return "rightControl"
        case kVK_Shift: return "leftShift"
        case kVK_RightShift: return "rightShift"
        default: return nil
        }
    }

    public static func matchesConfigured(identity: String, configured: String) -> Bool {
        if identity == configured { return true }
        switch configured {
        case "command":
            return identity == "leftCommand" || identity == "rightCommand"
        case "option":
            return identity == "leftOption" || identity == "rightOption"
        case "control":
            return identity == "leftControl" || identity == "rightControl"
        case "shift":
            return identity == "leftShift" || identity == "rightShift"
        default:
            return false
        }
    }

    /// Side-aware down check using device-dependent modifier bits.
    public static func isIdentityDown(_ identity: String, flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch identity {
        case "leftCommand": return raw & 0x00000008 != 0
        case "rightCommand": return raw & 0x00000010 != 0
        case "leftOption": return raw & 0x00000020 != 0
        case "rightOption": return raw & 0x00000040 != 0
        case "leftShift": return raw & 0x00000002 != 0
        case "rightShift": return raw & 0x00000004 != 0
        case "leftControl": return raw & 0x00000001 != 0
        case "rightControl": return raw & 0x00002000 != 0
        case "command": return flags.contains(.command)
        case "option": return flags.contains(.option)
        case "control": return flags.contains(.control)
        case "shift": return flags.contains(.shift)
        default: return false
        }
    }

    deinit {
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalEventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyDownMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalKeyDownMonitor { NSEvent.removeMonitor(monitor) }
    }
}
