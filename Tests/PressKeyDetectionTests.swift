import XCTest
import Carbon.HIToolbox
@testable import TypesterCore

final class PressKeyDetectionTests: XCTestCase {

    func testFnDownRequiresPhysicalFnKeyCode() {
        let flags = CGEventFlags.maskSecondaryFn
        XCTAssertTrue(
            PressKeyDetection.isKeyDown(
                configured: .fn,
                keyCode: Int64(kVK_Function),
                flags: flags
            )
        )
    }

    func testFnIgnoresFunctionFlagFromOtherKeys() {
        // F-keys also set SecondaryFn; without a keyCode filter they look like Fn.
        let flags = CGEventFlags.maskSecondaryFn
        XCTAssertFalse(
            PressKeyDetection.isKeyDown(
                configured: .fn,
                keyCode: Int64(kVK_F5),
                flags: flags
            )
        )
    }

    func testFnUpWhenPhysicalFnReleased() {
        XCTAssertFalse(
            PressKeyDetection.isKeyDown(
                configured: .fn,
                keyCode: Int64(kVK_Function),
                flags: []
            )
        )
    }

    func testFnFlagsChangedFromUnrelatedKeyDoesNotClaimFnDown() {
        XCTAssertFalse(
            PressKeyDetection.isKeyDown(
                configured: .fn,
                keyCode: Int64(kVK_Shift),
                flags: .maskSecondaryFn
            )
        )
    }

    func testShouldApplyFlagsChangedOnlyForMatchingFnKeyCode() {
        XCTAssertTrue(
            PressKeyDetection.shouldApplyFlagsChanged(
                configured: .fn,
                keyCode: Int64(kVK_Function)
            )
        )
        XCTAssertFalse(
            PressKeyDetection.shouldApplyFlagsChanged(
                configured: .fn,
                keyCode: Int64(kVK_Shift)
            )
        )
        XCTAssertFalse(
            PressKeyDetection.shouldApplyFlagsChanged(
                configured: .fn,
                keyCode: Int64(kVK_F1)
            )
        )
    }

    func testOtherPressKeysStillApplyAnyFlagsChanged() {
        XCTAssertTrue(
            PressKeyDetection.shouldApplyFlagsChanged(
                configured: .leftCommand,
                keyCode: Int64(kVK_Shift)
            )
        )
    }

    func testLeftCommandUsesDeviceDependentBit() {
        XCTAssertTrue(
            PressKeyDetection.isKeyDown(
                configured: .leftCommand,
                keyCode: Int64(kVK_Command),
                flags: CGEventFlags(rawValue: 0x00000008)
            )
        )
        XCTAssertFalse(
            PressKeyDetection.isKeyDown(
                configured: .leftCommand,
                keyCode: Int64(kVK_Command),
                flags: CGEventFlags(rawValue: 0x00000010) // right command
            )
        )
    }
}
