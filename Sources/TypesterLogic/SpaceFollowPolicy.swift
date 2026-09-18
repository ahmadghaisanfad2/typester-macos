import Foundation

/// Pure policy for HUD window Space-following collection-behavior flags.
///
/// AppKit's `-[NSWindow _validateCollectionBehavior:]` aborts the process when
/// mutually exclusive bits are combined (observed on macOS 27 in Typester 1.22.0
/// when Accessibility onboarding presented a helper HUD):
/// - `.canJoinAllSpaces` + `.moveToActiveSpace`
/// - `.stationary` + `.moveToActiveSpace`
///
/// HUDs follow the active Space by relocating on `orderFrontRegardless()` via
/// `.moveToActiveSpace`, not by joining every Space up front.
public enum SpaceFollowPolicy {
    public enum Flag: String, CaseIterable, Equatable {
        case canJoinAllSpaces
        case stationary
        case fullScreenAuxiliary
        case ignoresCycle
        case moveToActiveSpace
    }

    /// Valid HUD set: auxiliary + out of cycle + move to active Space on reassert.
    public static let hudFlags: [Flag] = [
        .fullScreenAuxiliary,
        .ignoresCycle,
        .moveToActiveSpace,
    ]

    /// True when the flag combination is accepted by AppKit collection-behavior validation.
    public static func isValid(_ flags: [Flag]) -> Bool {
        guard flags.contains(.moveToActiveSpace) else { return true }
        return !flags.contains(.canJoinAllSpaces) && !flags.contains(.stationary)
    }
}

/// Product rule for Accessibility grant UX: one Typester window + System Settings.
public enum AccessibilityGrantPresentation {
    /// Never present a second floating drag-helper window beside onboarding,
    /// Settings, or permission recovery.
    public static let presentsFloatingDragHelper = false
}
