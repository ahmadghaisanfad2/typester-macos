import Cocoa

/// Intercepts Escape via a consuming CGEvent tap while Typester's session is
/// active. NSEvent global monitors cannot swallow keys, so without this ESC
/// always reaches the frontmost app.
public final class EscapeInterceptor {
    public static let shared = EscapeInterceptor()

    /// Called on the main queue when Escape should cancel the session.
    public var onEscapePressed: (() -> Void)?

    private let armLock = NSLock()
    private var _isArmed = false
    /// When true, Escape is consumed and `onEscapePressed` fires.
    public var isArmed: Bool {
        armLock.lock()
        defer { armLock.unlock() }
        return _isArmed
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    public func arm() {
        armLock.lock()
        _isArmed = true
        armLock.unlock()
        startTapIfNeeded()
    }

    public func disarm() {
        armLock.lock()
        _isArmed = false
        armLock.unlock()
    }

    public func start() {
        startTapIfNeeded()
    }

    public func stop() {
        disarm()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func startTapIfNeeded() {
        guard eventTap == nil else {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<EscapeInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[EscapeInterceptor] Failed to create event tap - check Accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard EscapeCancelPolicy.isEscapeKeyCode(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        let armed = isArmed
        let decision = EscapeCancelPolicy.decision(
            isRecording: armed,
            isOverlayActive: armed
        )
        guard decision.shouldCancel else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            self?.onEscapePressed?()
        }

        return decision.shouldConsumeEvent ? nil : Unmanaged.passUnretained(event)
    }
}
