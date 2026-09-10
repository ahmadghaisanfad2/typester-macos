import Foundation

/// Pure helpers for deciding when to surface the one-click Accessibility recovery UI.
///
/// macOS ties Accessibility grants to the code signature's designated requirement.
/// Ad-hoc signed updates (e.g. an unconfigured CI build) get a new identity, so TCC
/// silently drops the grant and press-to-speak / paste stop working. Once the app
/// is stably signed again, this only needs to happen once.
public enum PermissionRecovery {
    public static let lastKnownAccessibilityTrustedKey = "lastKnownAccessibilityTrusted"
    public static let recoveryDismissedForSessionKey = "permissionRecoveryDismissedForSession"

    /// True when Accessibility was trusted on a previous launch and is missing now
    /// — the classic post-update reset. First install (never trusted) is handled
    /// by onboarding instead.
    public static func shouldOfferRecoveryAfterUpdate(
        lastKnownTrusted: Bool,
        currentlyTrusted: Bool
    ) -> Bool {
        lastKnownTrusted && !currentlyTrusted
    }

    /// True when the user tried to activate dictation but Accessibility is missing.
    public static func shouldShowRecoveryOnFailedActivation(
        currentlyTrusted: Bool,
        alreadyDismissedThisSession: Bool
    ) -> Bool {
        !currentlyTrusted && !alreadyDismissedThisSession
    }

    public static func markAccessibilityTrusted(_ trusted: Bool) {
        UserDefaults.standard.set(trusted, forKey: lastKnownAccessibilityTrustedKey)
    }

    public static func lastKnownAccessibilityTrusted() -> Bool {
        UserDefaults.standard.bool(forKey: lastKnownAccessibilityTrustedKey)
    }

    public static func markRecoveryDismissedForSession() {
        UserDefaults.standard.set(true, forKey: recoveryDismissedForSessionKey)
    }

    public static func resetSessionDismissal() {
        UserDefaults.standard.set(false, forKey: recoveryDismissedForSessionKey)
    }

    public static func recoveryDismissedForSession() -> Bool {
        UserDefaults.standard.bool(forKey: recoveryDismissedForSessionKey)
    }
}

/// Posted when Accessibility trust flips, so monitors can re-arm without a relaunch.
public extension Notification.Name {
    static let accessibilityTrustChanged = Notification.Name("accessibilityTrustChanged")
}

/// Lightweight poller around `AXIsProcessTrusted` that fires when trust changes.
public final class AccessibilityTrustMonitor {
    public static let shared = AccessibilityTrustMonitor()

    public private(set) var isTrusted = TextPaster.checkAccessibilityPermission()

    private var timer: Timer?

    private init() {}

    public func start(interval: TimeInterval = 1.0) {
        stop()
        // Seed only the live bit. Do not write lastKnown here — that value is the
        // previous-session signal used to detect a post-update TCC reset, and
        // overwriting it at launch would hide the recovery sheet.
        isTrusted = TextPaster.checkAccessibilityPermission()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func poll() {
        let trusted = TextPaster.checkAccessibilityPermission()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        PermissionRecovery.markAccessibilityTrusted(trusted)
        NotificationCenter.default.post(name: .accessibilityTrustChanged, object: trusted)
    }
}
