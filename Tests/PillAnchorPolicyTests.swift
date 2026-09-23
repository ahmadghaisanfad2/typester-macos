import XCTest
@testable import TypesterCore

final class PillAnchorPolicyTests: XCTestCase {
    /// 1440×900 display, 90pt bottom Dock, menu bar not modeled in visibleFrame height.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let capsule = CGSize(width: 56, height: 34)
    /// Shadow bleed matching the collapsed pill's view padding.
    private let insets = PillInsets(top: 12, left: 16, bottom: 16, right: 16)
    private let gap: CGFloat = 12

    private var windowSize: CGSize {
        CGSize(
            width: capsule.width + insets.left + insets.right,
            height: capsule.height + insets.top + insets.bottom
        )
    }

    private func origin(visibleFrame: CGRect, edge: PillEdge) -> CGPoint {
        PillAnchorPolicy.origin(
            windowSize: windowSize,
            screenFrame: screen,
            visibleFrame: visibleFrame,
            edge: edge,
            insets: insets,
            edgeGap: gap
        )
    }

    // MARK: - Bottom

    func testBottomRestsAbovePinnedDock() {
        let visible = CGRect(x: 0, y: 90, width: 1440, height: 810)
        let point = origin(visibleFrame: visible, edge: .bottom)

        // Capsule bottom (window origin + shadow bleed) sits `gap` above the Dock.
        XCTAssertEqual(point.y + insets.bottom, visible.minY + gap, accuracy: 0.001)
        // Centered horizontally.
        XCTAssertEqual(point.x + insets.left + capsule.width / 2, visible.midX, accuracy: 0.001)
    }

    func testBottomDropsWhenDockIsHidden() {
        let pinned = origin(visibleFrame: CGRect(x: 0, y: 90, width: 1440, height: 810), edge: .bottom)
        // Dock hidden: visibleFrame == frame.
        let hidden = origin(visibleFrame: screen, edge: .bottom)

        XCTAssertLessThan(hidden.y, pinned.y, "hidden Dock must let the pill drop toward the edge")
        XCTAssertEqual(hidden.y + insets.bottom, screen.minY + gap, accuracy: 0.001)
    }

    func testBottomFollowsSideDockInset() {
        // Dock pinned to the right: visibleFrame loses width on that side.
        let visible = CGRect(x: 0, y: 0, width: 1360, height: 900)
        let point = origin(visibleFrame: visible, edge: .bottom)

        XCTAssertEqual(point.x + insets.left + capsule.width / 2, 680, accuracy: 0.001)
    }

    // MARK: - Top

    func testTopClearsMenuBar() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let point = origin(visibleFrame: visible, edge: .top)

        // Capsule top (window origin + height - shadow bleed) sits `gap` below the menu bar.
        XCTAssertEqual(point.y + windowSize.height - insets.top, visible.maxY - gap, accuracy: 0.001)
        XCTAssertEqual(point.x + insets.left + capsule.width / 2, visible.midX, accuracy: 0.001)
    }

    // MARK: - Left / Right

    func testLeftIsVerticallyCentered() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let point = origin(visibleFrame: visible, edge: .left)

        XCTAssertEqual(point.x + insets.left, visible.minX + gap, accuracy: 0.001)
        XCTAssertEqual(point.y + insets.bottom + capsule.height / 2, visible.midY, accuracy: 0.001)
    }

    func testRightIsVerticallyCentered() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let point = origin(visibleFrame: visible, edge: .right)

        XCTAssertEqual(point.x + insets.right + capsule.width, visible.maxX - gap, accuracy: 0.001)
        XCTAssertEqual(point.y + insets.bottom + capsule.height / 2, visible.midY, accuracy: 0.001)
    }

    // MARK: - Morph stability

    func testBottomAnchoredEdgeStaysFixedAcrossMorph() {
        // The window grows upward during the pill → caption morph; the capsule's
        // bottom edge must not move.
        let visible = CGRect(x: 0, y: 90, width: 1440, height: 810)
        let collapsed = origin(visibleFrame: visible, edge: .bottom)

        let expandedWindow = CGSize(width: 700, height: 160)
        let expandedInsets = PillInsets(top: 36, left: 44, bottom: 44, right: 44)
        let expanded = PillAnchorPolicy.origin(
            windowSize: expandedWindow,
            screenFrame: screen,
            visibleFrame: visible,
            edge: .bottom,
            insets: expandedInsets,
            edgeGap: gap
        )

        XCTAssertEqual(collapsed.y + insets.bottom, expanded.y + expandedInsets.bottom, accuracy: 0.001)
        XCTAssertEqual(expanded.x + expandedInsets.left + (expandedWindow.width - expandedInsets.left - expandedInsets.right) / 2,
                       visible.midX, accuracy: 0.001)
    }

    // MARK: - Safety net

    func testOversizedWindowIsClampedOnScreen() {
        let visible = CGRect(x: 0, y: 90, width: 1440, height: 810)
        let huge = CGSize(width: 2000, height: 200)
        let point = PillAnchorPolicy.origin(
            windowSize: huge,
            screenFrame: screen,
            visibleFrame: visible,
            edge: .bottom,
            insets: insets,
            edgeGap: gap
        )

        // A window wider than the display is pushed as far left as allowed, so
        // the capsule's left edge stays on screen.
        XCTAssertEqual(point.x, screen.minX - insets.left, accuracy: 0.001)
        // The anchored edge is preserved while it still fits.
        XCTAssertEqual(point.y + insets.bottom, visible.minY + gap, accuracy: 0.001)
    }

    func testZeroInsetDefaultsToWindowEdge() {
        let visible = CGRect(x: 0, y: 90, width: 1440, height: 810)
        let point = PillAnchorPolicy.origin(
            windowSize: CGSize(width: 56, height: 34),
            screenFrame: screen,
            visibleFrame: visible,
            edge: .bottom
        )

        XCTAssertEqual(point.y, visible.minY + PillAnchorPolicy.defaultEdgeGap, accuracy: 0.001)
        XCTAssertEqual(point.x, visible.midX - 28, accuracy: 0.001)
    }

    func testPillEdgeRoundTripsThroughRawValue() {
        for edge in PillEdge.allCases {
            XCTAssertEqual(PillEdge(rawValue: edge.rawValue), edge)
            XCTAssertFalse(edge.displayName.isEmpty)
        }
    }
}
