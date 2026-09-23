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

final class PillActionsLayoutTests: XCTestCase {
    private let size = CGSize(width: 356, height: 40)

    func testRectsFillTheCapsuleWithEvenInsets() {
        let rects = PillActionsLayout.actionRects(in: size)

        XCTAssertEqual(rects.stop.minX, PillActionsLayout.horizontalInset, accuracy: 0.001)
        XCTAssertEqual(rects.stop.minY, PillActionsLayout.verticalInset, accuracy: 0.001)
        XCTAssertEqual(
            size.width - rects.cancel.maxX,
            PillActionsLayout.horizontalInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            size.height - rects.stop.maxY,
            PillActionsLayout.verticalInset,
            accuracy: 0.001
        )
        XCTAssertEqual(rects.stop.width, rects.cancel.width, accuracy: 0.001)
        XCTAssertEqual(rects.stop.height, rects.cancel.height, accuracy: 0.001)
    }

    func testActionsDoNotOverlapAndStayInsideTheCapsule() {
        let rects = PillActionsLayout.actionRects(in: size)

        XCTAssertFalse(rects.stop.intersects(rects.cancel))
        XCTAssertGreaterThan(rects.cancel.minX, rects.stop.maxX - 0.001)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rects.stop))
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rects.cancel))
    }

    func testClicksRouteToTheActionUnderThePoint() {
        let rects = PillActionsLayout.actionRects(in: size)

        XCTAssertEqual(
            PillActionsLayout.action(at: CGPoint(x: rects.stop.midX, y: rects.stop.midY), in: size),
            .stop
        )
        XCTAssertEqual(
            PillActionsLayout.action(at: CGPoint(x: rects.cancel.midX, y: rects.cancel.midY), in: size),
            .cancel
        )
    }

    func testRutsAndGapsRouteNowhere() {
        let rects = PillActionsLayout.actionRects(in: size)

        // The gap between the two actions.
        XCTAssertNil(PillActionsLayout.action(at: CGPoint(x: rects.stop.maxX + 4, y: 20), in: size))
        // The inset margin along the bottom edge.
        XCTAssertNil(PillActionsLayout.action(at: CGPoint(x: rects.stop.midX, y: 2), in: size))
        XCTAssertNil(PillActionsLayout.action(at: CGPoint(x: 2, y: 20), in: size))
    }

    func testDegenerateCapsuleNeverProducesNegativeRects() {
        for width in [CGFloat(0), 8, 20, 40] {
            let rects = PillActionsLayout.actionRects(in: CGSize(width: width, height: 14))
            XCTAssertGreaterThanOrEqual(rects.stop.width, 0)
            XCTAssertGreaterThanOrEqual(rects.cancel.width, 0)
            XCTAssertGreaterThanOrEqual(rects.stop.height, 0)
            XCTAssertGreaterThanOrEqual(rects.cancel.height, 0)
        }
    }
}

final class DockReserveTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let insets = PillInsets(top: 26, left: 34, bottom: 32, right: 34)
    /// What macOS 27 actually reports for a pinned Dock with tilesize 38.
    private let observedDockBand: CGFloat = 58

    private func dock(
        autohide: Bool,
        orientation: String = "bottom",
        tile: CGFloat = 38,
        magnification: Bool = false,
        large: CGFloat = 62
    ) -> DockPreferences {
        DockPreferences(
            autohide: autohide,
            orientation: orientation,
            tileSize: tile,
            magnification: magnification,
            largeSize: large
        )
    }

    func testAutoHideOffUsesTheReportedVisibleFrame() {
        // A pinned Dock is already excluded by macOS, so nothing to add.
        let visible = CGRect(x: 0, y: observedDockBand, width: 1440, height: 812)
        let effective = DockReserve.visibleFrame(
            screenFrame: screen,
            visibleFrame: visible,
            dock: dock(autohide: false)
        )
        XCTAssertEqual(effective, visible)
    }

    func testAutoHideOnReservesTheDockBand() {
        // Measured: an auto-hidden Dock reports a bottom reserve of 0.
        let hidden = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let prefs = dock(autohide: true)
        let effective = DockReserve.visibleFrame(
            screenFrame: screen,
            visibleFrame: hidden,
            dock: prefs
        )
        XCTAssertEqual(effective.minY, DockReserve.band(prefs), accuracy: 0.001)
        XCTAssertEqual(
            effective.height,
            870 - DockReserve.band(prefs),
            accuracy: 0.001
        )
    }

    /// The reported bug: with the Dock auto-hidden the pill dropped to the
    /// bottom, so the Dock covered it the moment the user reached for it.
    func testPillClearsARevealedAutoHiddenDock() {
        let hidden = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let window = CGSize(
            width: 44 + insets.left + insets.right,
            height: 24 + insets.top + insets.bottom
        )

        let point = PillAnchorPolicy.origin(
            windowSize: window,
            screen: (frame: screen, visibleFrame: hidden),
            dock: dock(autohide: true),
            edge: .bottom,
            insets: insets
        )

        let capsuleBottom = point.y + insets.bottom
        XCTAssertGreaterThanOrEqual(
            capsuleBottom,
            observedDockBand + PillAnchorPolicy.defaultEdgeGap,
            "the pill must stay clear of a Dock that reveals itself"
        )
    }

    func testLeftAutoHiddenDockReservesHorizontally() {
        let hidden = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let prefs = dock(autohide: true, orientation: "left")
        let band = DockReserve.band(prefs)
        let effective = DockReserve.visibleFrame(
            screenFrame: screen,
            visibleFrame: hidden,
            dock: prefs
        )
        XCTAssertEqual(effective.minX, band, accuracy: 0.001)
        XCTAssertEqual(effective.width, 1440 - band, accuracy: 0.001)
    }

    func testRightAutoHiddenDockReservesHorizontally() {
        let hidden = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let prefs = dock(autohide: true, orientation: "right")
        let band = DockReserve.band(prefs)
        let effective = DockReserve.visibleFrame(
            screenFrame: screen,
            visibleFrame: hidden,
            dock: prefs
        )
        XCTAssertEqual(effective.maxX, 1440 - band, accuracy: 0.001)
        XCTAssertEqual(effective.width, 1440 - band, accuracy: 0.001)
    }

    func testMagnifiedDockReservesItsLargeSize() {
        let normal = DockReserve.band(dock(autohide: true, magnification: false, large: 62))
        let magnified = DockReserve.band(dock(autohide: true, magnification: true, large: 62))
        XCTAssertEqual(normal, 62, accuracy: 0.001)
        XCTAssertEqual(magnified, 86, accuracy: 0.001)
        XCTAssertGreaterThan(magnified, normal)
    }

    func testReserveNeverUndershootsTheObservedDock() {
        XCTAssertGreaterThanOrEqual(
            DockReserve.band(dock(autohide: true, tile: 38)),
            observedDockBand
        )
    }
}
