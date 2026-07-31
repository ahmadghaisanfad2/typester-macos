import Cocoa
import Carbon.HIToolbox
import ApplicationServices

public class TextPaster {
    public init() {}

    /// Optional hook invoked around synthetic ⌘V so press-to-speak monitors can ignore it.
    public var onPasteSimulationBegin: (() -> Void)?
    public var onPasteSimulationEnd: (() -> Void)?

    // MARK: - Accessibility

    public static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunch so a newly granted Accessibility toggle is picked up by AXIsProcessTrusted().
    public static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Paste

    /// Pastes text into the focused field. Returns false if accessibility is missing or text is empty.
    @discardableResult
    public func paste(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        guard TextPaster.checkAccessibilityPermission() else {
            TextPaster.requestAccessibilityPermission()
            return false
        }

        // Electron/Cursor often reports AX success without inserting — skip AX there.
        if !prefersCommandVPaste(), insertTextViaAccessibility(text) {
            return true
        }

        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict.isEmpty ? nil : dict
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        onPasteSimulationBegin?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.simulatePaste()
            self.onPasteSimulationEnd?()

            // Electron (Cursor) needs a longer window than native AppKit fields.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let previousItems, !previousItems.isEmpty else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                for itemDict in previousItems {
                    let item = NSPasteboardItem()
                    for (type, data) in itemDict {
                        item.setData(data, forType: type)
                    }
                    pb.writeObjects([item])
                }
            }
        }
        return true
    }

    private func insertTextViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return false
        }

        let element = focused as! AXUIElement

        var isSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSettable) == .success,
              isSettable.boolValue else {
            return false
        }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }

        // Verify — Electron/Cursor can return success without changing the field.
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              !needle.isEmpty,
              value.contains(needle) else {
            return false
        }
        return true
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post exactly once — multiple taps caused triple paste in Cursor.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Electron/Chromium hosts often lie about AX text insertion.
    private func prefersCommandVPaste() -> Bool {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else {
            return false
        }
        return bundle.hasPrefix("com.todesktop.")
            || bundle.contains("electron")
            || bundle.hasPrefix("com.microsoft.vscode")
            || bundle.hasPrefix("com.github.atom")
    }
}
