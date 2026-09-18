import AppKit

public extension Notification.Name {
    /// Posted after `NSApp.setActivationPolicy` so HUD windows can re-pin to the active Space.
    static let typesterActivationPolicyDidChange = Notification.Name("typesterActivationPolicyDidChange")
}

/// Shared AppKit settings so floating HUD windows stay on the active Space.
///
/// A plain `.floating` + `.canJoinAllSpaces` borderless `NSWindow` can get
/// pinned to the Space where it was first ordered front in an `LSUIElement`
/// app. Activation-policy flips (Dock / settings windows) can re-pin them again.
/// This helper applies sticky flags and multi-pass reassert across Space transitions.
enum SpaceFollowingWindow {
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .stationary,
        .fullScreenAuxiliary,
        .ignoresCycle,
        // Relocate on orderFrontRegardless when AppKit pinned the window elsewhere.
        .moveToActiveSpace,
    ]

    /// Above plain `.floating` / `.statusBar`; still below screensaver.
    static var hudWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    }

    /// Delays for post-transition reassert passes (Space swipe animation).
    static let transitionPassDelays: [TimeInterval] = [0.05, 0.20, 0.45]

    static func configure(_ window: NSWindow) {
        window.level = hudWindowLevel
        window.collectionBehavior = collectionBehavior
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
    }

    /// Re-assert Space membership and force presentation from a non-activating app.
    static func reaffirm(_ window: NSWindow) {
        window.collectionBehavior = collectionBehavior
        window.level = hudWindowLevel
        window.orderFrontRegardless()
    }

    /// Immediate reassert plus delayed passes so mid-transition pinning is undone.
    static func reaffirmWithTransitionPasses(_ window: NSWindow, reposition: @escaping () -> Void) {
        reaffirm(window)
        reposition()

        for delay in transitionPassDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Skip if ordered out OR faded; OR would resurrect a hidden HUD
                // that still has alpha 1 (SubtitleOverlay hide path).
                guard window.isVisible, window.alphaValue > 0.01 else { return }
                reaffirm(window)
                reposition()
            }
        }
    }

    /// Posted by AppDelegate after activation-policy changes.
    static func notifyActivationPolicyDidChange() {
        NotificationCenter.default.post(name: .typesterActivationPolicyDidChange, object: nil)
    }

    /// Observe Space switches and activation-policy flips while `shouldReassert` returns true.
    /// Call `stop()` when the window is ordered out.
    final class SpaceObserver {
        private var spaceToken: NSObjectProtocol?
        private var policyToken: NSObjectProtocol?

        func start(shouldReassert: @escaping () -> Bool, handler: @escaping () -> Void) {
            stop()
            spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                guard shouldReassert() else { return }
                handler()
            }
            policyToken = NotificationCenter.default.addObserver(
                forName: .typesterActivationPolicyDidChange,
                object: nil,
                queue: .main
            ) { _ in
                guard shouldReassert() else { return }
                handler()
            }
        }

        func stop() {
            if let spaceToken {
                NSWorkspace.shared.notificationCenter.removeObserver(spaceToken)
            }
            if let policyToken {
                NotificationCenter.default.removeObserver(policyToken)
            }
            spaceToken = nil
            policyToken = nil
        }

        deinit {
            stop()
        }
    }
}
