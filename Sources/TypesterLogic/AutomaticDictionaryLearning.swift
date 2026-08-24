import Cocoa
import ApplicationServices

public struct DetectedCorrection: Equatable {
    public let wrong: String
    public let right: String

    public init(wrong: String, right: String) {
        self.wrong = wrong
        self.right = right
    }
}

public enum AutomaticCorrectionDetector {
    public static let maxPhraseWords = 4
    public static let maxPhraseCharacters = 64
    public static let maxTranscriptWords = 500

    public static func detect(original: String, corrected: String) -> [DetectedCorrection] {
        let originalWords = words(in: original)
        let correctedWords = words(in: corrected)
        guard !originalWords.isEmpty,
              !correctedWords.isEmpty,
              originalWords.count <= maxTranscriptWords,
              correctedWords.count <= maxTranscriptWords,
              originalWords != correctedWords else {
            return []
        }

        let rows = originalWords.count + 1
        let columns = correctedWords.count + 1
        var lcs = Array(repeating: Array(repeating: 0, count: columns), count: rows)

        for i in stride(from: originalWords.count - 1, through: 0, by: -1) {
            for j in stride(from: correctedWords.count - 1, through: 0, by: -1) {
                if originalWords[i] == correctedWords[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var candidates: [DetectedCorrection] = []
        var removed: [String] = []
        var inserted: [String] = []
        var i = 0
        var j = 0

        func appendCandidate() {
            defer {
                removed.removeAll(keepingCapacity: true)
                inserted.removeAll(keepingCapacity: true)
            }
            guard !removed.isEmpty,
                  !inserted.isEmpty,
                  removed.count <= maxPhraseWords,
                  inserted.count <= maxPhraseWords else {
                return
            }
            let wrong = removed.joined(separator: " ")
            let right = inserted.joined(separator: " ")
            guard wrong != right,
                  wrong.count <= maxPhraseCharacters,
                  right.count <= maxPhraseCharacters else {
                return
            }
            candidates.append(DetectedCorrection(wrong: wrong, right: right))
        }

        while i < originalWords.count || j < correctedWords.count {
            if i < originalWords.count,
               j < correctedWords.count,
               originalWords[i] == correctedWords[j] {
                appendCandidate()
                i += 1
                j += 1
            } else if j < correctedWords.count,
                      (i == originalWords.count || lcs[i][j + 1] >= lcs[i + 1][j]) {
                inserted.append(correctedWords[j])
                j += 1
            } else if i < originalWords.count {
                removed.append(originalWords[i])
                i += 1
            }
        }
        appendCandidate()

        let changedWordCount = candidates.reduce(0) {
            $0 + $1.wrong.split(separator: " ").count + $1.right.split(separator: " ").count
        }
        guard candidates.count <= 4, changedWordCount <= 16 else { return [] }
        return candidates
    }

    private static func words(in text: String) -> [String] {
        let pattern = #"[\p{L}\p{N}]+(?:['’._-][\p{L}\p{N}]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).map { nsText.substring(with: $0.range) }
    }
}

public enum TextTrackingUpdate: Equatable {
    case irrelevant
    case relevant
    case invalid
}

/// Tracks the UTF-16 range inserted by Typester while surrounding text changes.
public struct PastedTextTracker {
    public let originalText: String
    public private(set) var currentValue: String
    public private(set) var range: NSRange

    public init(originalText: String, currentValue: String, range: NSRange) {
        self.originalText = originalText
        self.currentValue = currentValue
        self.range = range
    }

    public var correctedText: String? {
        let value = currentValue as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= value.length else {
            return nil
        }
        return value.substring(with: range)
    }

    public mutating func update(to newValue: String) -> TextTrackingUpdate {
        guard newValue != currentValue else { return .irrelevant }

        let oldUnits = Array(currentValue.utf16)
        let newUnits = Array(newValue.utf16)
        var prefix = 0
        while prefix < oldUnits.count,
              prefix < newUnits.count,
              oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldUnits.count - prefix,
              suffix < newUnits.count - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }

        let oldChanged = NSRange(
            location: prefix,
            length: oldUnits.count - prefix - suffix
        )
        let newChangedLength = newUnits.count - prefix - suffix
        let delta = newChangedLength - oldChanged.length
        let trackedStart = range.location
        let trackedEnd = NSMaxRange(range)
        let changedEnd = NSMaxRange(oldChanged)

        defer { currentValue = newValue }

        if changedEnd <= trackedStart, !(oldChanged.length == 0 && prefix == trackedStart) {
            range.location += delta
            return .irrelevant
        }

        // Insertion at the exact end is ordinary continued typing, not a correction.
        if oldChanged.location >= trackedEnd {
            return .irrelevant
        }

        guard oldChanged.location >= trackedStart,
              changedEnd <= trackedEnd else {
            return .invalid
        }

        range.length += delta
        guard range.length >= 0 else { return .invalid }
        return .relevant
    }
}

public struct AccessibilityPasteTarget {
    public let element: AXUIElement
    public let processID: pid_t
    public let valueBeforePaste: String
    public let selectedRange: NSRange

    public static func captureFocused() -> AccessibilityPasteTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef else {
            return nil
        }

        let element = focusedRef as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        guard !isSecureField(role: role, subrole: subrole) else {
            Debug.log("Automatic learning skipped for secure field")
            return nil
        }
        guard let value = stringAttribute(kAXValueAttribute, from: element),
              let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute, from: element),
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= (value as NSString).length else {
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return AccessibilityPasteTarget(
            element: element,
            processID: pid,
            valueBeforePaste: value,
            selectedRange: selectedRange
        )
    }

    public static func isSecureField(role: String?, subrole: String?) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return role == secure || subrole == secure
    }

    public func makeObservation(insertedText: String) -> PasteObservation? {
        let before = valueBeforePaste as NSString
        let expected = before.replacingCharacters(in: selectedRange, with: insertedText)
        guard let current = Self.stringAttribute(kAXValueAttribute, from: element),
              current == expected else {
            return nil
        }
        return PasteObservation(
            element: element,
            processID: processID,
            insertedText: insertedText,
            valueAfterPaste: current,
            insertedRange: NSRange(
                location: selectedRange.location,
                length: (insertedText as NSString).length
            )
        )
    }

    fileprivate static func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static func rangeAttribute(_ name: String, from element: AXUIElement) -> NSRange? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &valueRef) == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = valueRef as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

public struct PasteObservation {
    public let element: AXUIElement
    public let processID: pid_t
    public let insertedText: String
    public let valueAfterPaste: String
    public let insertedRange: NSRange
}

public final class AutomaticCorrectionMonitor {
    public var onCorrections: (([DetectedCorrection]) -> Void)?

    private var observation: PasteObservation?
    private var tracker: PastedTextTracker?
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var debounceWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?
    private var lastEmitted: [DetectedCorrection] = []

    public init() {}

    deinit {
        cancel()
    }

    public func begin(_ observation: PasteObservation) {
        cancel()
        Debug.log("Automatic learning observation started for pid=\(observation.processID)")
        self.observation = observation
        tracker = PastedTextTracker(
            originalText: observation.insertedText,
            currentValue: observation.valueAfterPaste,
            range: observation.insertedRange
        )

        var createdObserver: AXObserver?
        let result = AXObserverCreate(observation.processID, { _, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AutomaticCorrectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.handle(notification: notification as String)
            }
        }, &createdObserver)
        guard result == .success, let createdObserver else {
            Debug.log("Automatic learning observer creation failed: \(result.rawValue)")
            cancel()
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let valueResult = AXObserverAddNotification(
            createdObserver,
            observation.element,
            kAXValueChangedNotification as CFString,
            refcon
        )
        guard valueResult == .success else {
            Debug.log("Automatic learning value notification unsupported: \(valueResult.rawValue)")
            cancel()
            return
        }

        let appElement = AXUIElementCreateApplication(observation.processID)
        _ = AXObserverAddNotification(
            createdObserver,
            appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            refcon
        )

        observer = createdObserver
        applicationElement = appElement
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )

        let timeout = DispatchWorkItem { [weak self] in
            self?.finishAndCancel()
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    public func cancel() {
        debounceWorkItem?.cancel()
        timeoutWorkItem?.cancel()
        debounceWorkItem = nil
        timeoutWorkItem = nil

        if let observer {
            if let observation {
                _ = AXObserverRemoveNotification(
                    observer,
                    observation.element,
                    kAXValueChangedNotification as CFString
                )
            }
            if let applicationElement {
                _ = AXObserverRemoveNotification(
                    observer,
                    applicationElement,
                    kAXFocusedUIElementChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        observer = nil
        applicationElement = nil
        observation = nil
        tracker = nil
        lastEmitted = []
    }

    private func handle(notification: String) {
        if notification == (kAXFocusedUIElementChangedNotification as String) {
            guard let observation else {
                cancel()
                return
            }
            let systemWide = AXUIElementCreateSystemWide()
            var focusedRef: CFTypeRef?
            let sameElement = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success && focusedRef.map { CFEqual($0, observation.element) } == true
            if !sameElement {
                finishAndCancel()
            }
            return
        }

        guard notification == (kAXValueChangedNotification as String),
              let observation,
              var tracker,
              let value = AccessibilityPasteTarget.stringAttribute(
                kAXValueAttribute,
                from: observation.element
              ) else {
            return
        }

        let update = tracker.update(to: value)
        self.tracker = tracker
        switch update {
        case .irrelevant:
            return
        case .invalid:
            // The edit crossed the observed range boundary, so its intent is
            // ambiguous. Discard the session without learning anything.
            cancel()
        case .relevant:
            scheduleDetection()
        }
    }

    private func scheduleDetection() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.emitCurrentCorrections()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func emitCurrentCorrections() {
        guard let tracker, let corrected = tracker.correctedText else { return }
        let candidates = AutomaticCorrectionDetector.detect(
            original: tracker.originalText,
            corrected: corrected
        )
        guard !candidates.isEmpty, candidates != lastEmitted else { return }
        lastEmitted = candidates
        Debug.log("Automatic learning detected \(candidates.count) correction(s)")
        onCorrections?(candidates)
    }

    private func finishAndCancel() {
        emitCurrentCorrections()
        cancel()
    }
}
