import XCTest
@testable import TypesterCore

final class SpaceFollowPolicyTests: XCTestCase {
    func testHUDFlagsAreValid() {
        XCTAssertTrue(SpaceFollowPolicy.isValid(SpaceFollowPolicy.hudFlags))
        XCTAssertEqual(
            SpaceFollowPolicy.hudFlags,
            [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        )
        // Must not reintroduce the AppKit-invalid moveToActiveSpace pairings.
        XCTAssertFalse(SpaceFollowPolicy.hudFlags.contains(.moveToActiveSpace))
        XCTAssertFalse(SpaceFollowPolicy.hudFlags.contains(.stationary))
    }

    func test1220CollectionBehaviorIsRejected() {
        // Flags shipped in 1.22.0 that aborted AppKit in AccessibilityDragHelper.show().
        let shipped: [SpaceFollowPolicy.Flag] = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .moveToActiveSpace,
        ]
        XCTAssertFalse(SpaceFollowPolicy.isValid(shipped))
    }

    func testMutuallyExclusivePairsAreRejected() {
        XCTAssertFalse(SpaceFollowPolicy.isValid([.canJoinAllSpaces, .moveToActiveSpace]))
        XCTAssertFalse(SpaceFollowPolicy.isValid([.stationary, .moveToActiveSpace]))
        XCTAssertFalse(SpaceFollowPolicy.isValid([.canJoinAllSpaces, .stationary, .moveToActiveSpace]))
    }

    func testMoveToActiveSpaceAloneIsValid() {
        XCTAssertTrue(SpaceFollowPolicy.isValid([.moveToActiveSpace]))
        XCTAssertTrue(SpaceFollowPolicy.isValid([.fullScreenAuxiliary, .ignoresCycle]))
        XCTAssertTrue(SpaceFollowPolicy.isValid([.canJoinAllSpaces, .fullScreenAuxiliary]))
        XCTAssertTrue(SpaceFollowPolicy.isValid([.stationary, .ignoresCycle]))
    }
}

final class AccessibilityGrantPresentationTests: XCTestCase {
    func testGrantUXDoesNotPresentFloatingDragHelper() {
        XCTAssertFalse(AccessibilityGrantPresentation.presentsFloatingDragHelper)
    }
}
