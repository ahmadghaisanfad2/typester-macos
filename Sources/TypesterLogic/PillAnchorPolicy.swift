import CoreGraphics
import Foundation

/// Screen edge the floating pill rests against. The pill is always centered
/// along the chosen edge.
public enum PillEdge: String, Codable, CaseIterable {
    case bottom
    case top
    case left
    case right

    public var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Distance from each window edge to the visible capsule drawn inside it.
/// Borderless HUD windows carry a transparent shadow bleed; anchoring must
/// account for it so the *capsule* keeps a constant gap from the Dock/edge,
/// and so the morph does not shift the anchored edge.
public struct PillInsets: Equatable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = PillInsets(top: 0, left: 0, bottom: 0, right: 0)
}

/// The Dock's user preferences, as needed to reason about its footprint.
public struct DockPreferences: Equatable {
    public var autohide: Bool
    /// `bottom`, `left` or `right`.
    public var orientation: String
    public var tileSize: CGFloat
    public var magnification: Bool
    public var largeSize: CGFloat

    public init(
        autohide: Bool,
        orientation: String,
        tileSize: CGFloat,
        magnification: Bool,
        largeSize: CGFloat
    ) {
        self.autohide = autohide
        self.orientation = orientation
        self.tileSize = tileSize
        self.magnification = magnification
        self.largeSize = largeSize
    }

    public static let fallback = DockPreferences(
        autohide: false,
        orientation: "bottom",
        tileSize: 38,
        magnification: false,
        largeSize: 62
    )
}

/// How much screen the Dock takes, in points.
public enum DockReserve {
    /// Dock chrome around the tiles: padding plus the running-app indicators.
    public static let chrome: CGFloat = 24

    /// Thickness of a revealed Dock with these preferences.
    public static func band(_ dock: DockPreferences) -> CGFloat {
        let tile = dock.magnification ? max(dock.tileSize, dock.largeSize) : dock.tileSize
        return max(0, tile) + chrome
    }

    /// Screen area no Dock can cover.
    ///
    /// `NSScreen.visibleFrame` reports an *auto-hidden* Dock as if it were not
    /// there — measured on macOS 27: with the Dock hidden the bottom reserve
    /// collapses to 0, and it does **not** update when the Dock is revealed.
    /// No notification fires either, and `CGWindowList` needs Screen Recording.
    /// A pill anchored to the raw frame therefore sits exactly where the Dock
    /// appears and is covered the moment the user reaches for it.
    ///
    /// So when auto-hide is on we reserve the Dock's configured band instead,
    /// which keeps the pill clear of the Dock whether it is showing or not.
    public static func visibleFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        dock: DockPreferences
    ) -> CGRect {
        guard dock.autohide else { return visibleFrame }

        var frame = visibleFrame
        let band = band(dock)
        switch dock.orientation {
        case "left":
            let minX = screenFrame.minX + band
            if frame.minX < minX {
                frame.size.width -= minX - frame.minX
                frame.origin.x = minX
            }
        case "right":
            let maxX = screenFrame.maxX - band
            if frame.maxX > maxX {
                frame.size.width = maxX - frame.minX
            }
        default:
            let minY = screenFrame.minY + band
            if frame.minY < minY {
                frame.size.height -= minY - frame.minY
                frame.origin.y = minY
            }
        }
        return frame
    }
}

/// Where the two hover actions sit inside the expanded capsule.
///
/// The capsule is one interactive surface: hover and taps are handled by a
/// single view, and a tap is routed to Stop or Cancel by point. That only works
/// if the layout and the router agree on the same rects, so they are computed
/// here — once, and unit-tested.
public enum PillActionsLayout {
    public static let horizontalInset: CGFloat = 10
    public static let verticalInset: CGFloat = 5
    public static let spacing: CGFloat = 8

    /// Action rects in the capsule's own coordinate space (origin top-left).
    public static func actionRects(in size: CGSize) -> (stop: CGRect, cancel: CGRect) {
        let available = size.width - horizontalInset * 2 - spacing
        let width = max(0, available / 2)
        let height = max(0, size.height - verticalInset * 2)
        let stop = CGRect(x: horizontalInset, y: verticalInset, width: width, height: height)
        let cancel = CGRect(
            x: horizontalInset + width + spacing,
            y: verticalInset,
            width: width,
            height: height
        )
        return (stop, cancel)
    }

    /// Which action a tap at `point` means, if any.
    public enum Action: Equatable {
        case stop
        case cancel
    }

    public static func action(at point: CGPoint, in size: CGSize) -> Action? {
        let rects = actionRects(in: size)
        if rects.stop.contains(point) { return .stop }
        if rects.cancel.contains(point) { return .cancel }
        return nil
    }
}

/// Pure policy for anchoring the floating pill window.
///
/// Uses the *effective* visible frame (see `DockReserve.visibleFrame`) rather
/// than the window's frame: the menu bar and a pinned Dock inset it, a
/// left/right Dock insets it horizontally, and an auto-hiding Dock is reserved
/// out because macOS never reports when it reveals. Re-evaluating this whenever
/// the screen parameters change is what makes the position dynamic instead of
/// hardcoded.
public enum PillAnchorPolicy {
    /// Gap kept between the capsule and the Dock / screen edge.
    public static let defaultEdgeGap: CGFloat = 12

    /// Anchor using the raw screen geometry, applying the Dock reserve first.
    public static func origin(
        windowSize: CGSize,
        screen: (frame: CGRect, visibleFrame: CGRect),
        dock: DockPreferences,
        edge: PillEdge,
        insets: PillInsets = .zero,
        edgeGap: CGFloat = PillAnchorPolicy.defaultEdgeGap
    ) -> CGPoint {
        origin(
            windowSize: windowSize,
            screenFrame: screen.frame,
            visibleFrame: DockReserve.visibleFrame(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                dock: dock
            ),
            edge: edge,
            insets: insets,
            edgeGap: edgeGap
        )
    }

    public static func origin(
        windowSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edge: PillEdge,
        insets: PillInsets = .zero,
        edgeGap: CGFloat = PillAnchorPolicy.defaultEdgeGap
    ) -> CGPoint {
        // Center the *capsule*, not the window: the shadow bleed is asymmetric
        // (deeper below than above), so centering the window would offset the
        // visible pill along the edge.
        let capsuleWidth = windowSize.width - insets.left - insets.right
        let capsuleHeight = windowSize.height - insets.top - insets.bottom

        let x: CGFloat
        let y: CGFloat

        switch edge {
        case .bottom:
            x = visibleFrame.midX - capsuleWidth / 2 - insets.left
            y = visibleFrame.minY + edgeGap - insets.bottom
        case .top:
            x = visibleFrame.midX - capsuleWidth / 2 - insets.left
            y = visibleFrame.maxY - windowSize.height - edgeGap + insets.top
        case .left:
            x = visibleFrame.minX + edgeGap - insets.left
            y = visibleFrame.midY - capsuleHeight / 2 - insets.bottom
        case .right:
            x = visibleFrame.maxX - windowSize.width - edgeGap + insets.right
            y = visibleFrame.midY - capsuleHeight / 2 - insets.bottom
        }

        // Safety net: keep the visible capsule on screen even if the window's
        // shadow bleed would otherwise push it past an edge.
        let minX = screenFrame.minX - insets.left
        let maxX = screenFrame.maxX - windowSize.width + insets.right
        let minY = screenFrame.minY - insets.bottom
        let maxY = screenFrame.maxY - windowSize.height + insets.top

        return CGPoint(
            x: min(max(x, minX), Swift.max(minX, maxX)),
            y: min(max(y, minY), Swift.max(minY, maxY))
        )
    }
}
