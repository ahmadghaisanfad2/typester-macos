import Foundation

/// Decides whether first-run / incomplete-permission setup should be shown
/// and which onboarding step to land on.
///
/// Goal: after install (or a reinstall that keeps the API key), users finish
/// Microphone and Accessibility in the app — not by hunting through System
/// Settings after the hotkey already failed.
public enum PermissionSetup {
    public enum StartStep: Int, Comparable {
        case apiKey = 1
        case microphone = 2
        case accessibility = 3

        public static func < (lhs: StartStep, rhs: StartStep) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public static func shouldShowOnboarding(
        hasAPIKey: Bool,
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        !hasAPIKey || !microphoneGranted || !accessibilityGranted
    }

    /// First incomplete step. Call only when `shouldShowOnboarding` is true.
    public static func startStep(
        hasAPIKey: Bool,
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) -> StartStep {
        if !hasAPIKey { return .apiKey }
        if !microphoneGranted { return .microphone }
        return .accessibility
    }
}
