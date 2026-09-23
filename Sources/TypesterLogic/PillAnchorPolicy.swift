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

/// Pure policy for anchoring the floating pill window.
///
/// Uses `visibleFrame` (not `frame`) so the Dock and menu bar are always
/// respected: a pinned bottom Dock insets `visibleFrame.minY` and the pill
/// rises above it; a hidden Dock grows `visibleFrame` and the pill drops with
/// it; a left/right Dock insets the horizontal frame and the centered pill
/// shifts accordingly. Re-evaluating this whenever the screen parameters
/// change is what makes the position dynamic instead of hardcoded.
public enum PillAnchorPolicy {
    /// Gap kept between the capsule and the Dock / screen edge.
    public static let defaultEdgeGap: CGFloat = 12

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
