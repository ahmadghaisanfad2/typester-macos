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

    func testLeftControlUsesDeviceDependentBit() {
        XCTAssertTrue(
            PressKeyDetection.isKeyDown(
                configured: .leftControl,
                keyCode: Int64(kVK_Control),
                flags: CGEventFlags(rawValue: 0x00000001)
            )
        )
        XCTAssertFalse(
            PressKeyDetection.isKeyDown(
                configured: .leftControl,
                keyCode: Int64(kVK_Control),
                flags: CGEventFlags(rawValue: 0x00002000) // right control
            )
        )
    }

    func testRightShiftUsesDeviceDependentBit() {
        XCTAssertTrue(
            PressKeyDetection.isKeyDown(
                configured: .rightShift,
                keyCode: Int64(kVK_RightShift),
                flags: CGEventFlags(rawValue: 0x00000004)
            )
        )
        XCTAssertFalse(
            PressKeyDetection.isKeyDown(
                configured: .rightShift,
                keyCode: Int64(kVK_RightShift),
                flags: CGEventFlags(rawValue: 0x00000002) // left shift
            )
        )
    }

    func testAllModifierPressKeysRequireChordCancellation() {
        for key in PressToSpeakKey.allCases where key != .fn {
            XCTAssertTrue(key.requiresChordCancellation, "\(key) should cancel chords")
        }
        XCTAssertFalse(PressToSpeakKey.fn.requiresChordCancellation)
    }

    func testAllCasesHaveDisplayNames() {
        for key in PressToSpeakKey.allCases {
            XCTAssertFalse(key.displayName.isEmpty, "\(key) missing display name")
        }
    }
}
