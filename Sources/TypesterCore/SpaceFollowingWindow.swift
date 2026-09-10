import AppKit

/// Shared AppKit settings so floating HUD windows stay on the active Space.
///
/// A plain `.floating` + `.canJoinAllSpaces` borderless `NSWindow` can get
/// pinned to the Space where it was first ordered front in an `LSUIElement`
/// app. This helper applies the flags that keep HUD overlays Space-sticky.
enum SpaceFollowingWindow {
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .stationary,
        .fullScreenAuxiliary,
        .ignoresCycle,
    ]

    static func configure(_ window: NSWindow) {
        window.level = .statusBar
        window.collectionBehavior = collectionBehavior
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
    }

    /// Re-assert Space membership and force presentation from a non-activating app.
    static func reaffirm(_ window: NSWindow) {
        window.collectionBehavior = collectionBehavior
        window.level = .statusBar
        window.orderFrontRegardless()
    }

    /// Observe Space switches while `shouldReassert` returns true.
    /// Call the returned token's `invalidate()` when the window is ordered out.
    final class SpaceObserver {
        private var token: NSObjectProtocol?

        func start(shouldReassert: @escaping () -> Bool, handler: @escaping () -> Void) {
            stop()
            token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                guard shouldReassert() else { return }
                handler()
            }
        }

        func stop() {
            if let token {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
            token = nil
        }

        deinit {
            stop()
        }
    }
}
