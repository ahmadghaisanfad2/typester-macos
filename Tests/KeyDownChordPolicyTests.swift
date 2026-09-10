import XCTest
@testable import TypesterCore
import Carbon.HIToolbox

final class KeyDownChordPolicyTests: XCTestCase {
    func testModifierKeyCodesDoNotCancelPendingActivation() {
        XCTAssertFalse(
            KeyDownChordPolicy.shouldCancelPendingActivation(keyCode: Int64(kVK_Command))
        )
        XCTAssertFalse(
            KeyDownChordPolicy.shouldCancelPendingActivation(keyCode: Int64(kVK_RightCommand))
        )
        XCTAssertFalse(
            KeyDownChordPolicy.shouldCancelPendingActivation(keyCode: Int64(kVK_Function))
        )
        XCTAssertFalse(
            KeyDownChordPolicy.shouldCancelPendingActivation(keyCode: Int64(kVK_Shift))
        )
    }

    func testCharacterKeyCancelsPendingActivation() {
        XCTAssertTrue(
            KeyDownChordPolicy.shouldCancelPendingActivation(keyCode: Int64(kVK_ANSI_C))
        )
        XCTAssertTrue(
            KeyDownChordPolicy.shouldCancelPendingActivation(keyCode: Int64(kVK_Space))
        )
    }

    func testIsModifierKeyCode() {
        XCTAssertTrue(KeyDownChordPolicy.isModifierKeyCode(Int64(kVK_Option)))
        XCTAssertTrue(KeyDownChordPolicy.isModifierKeyCode(Int64(kVK_Control)))
        XCTAssertFalse(KeyDownChordPolicy.isModifierKeyCode(Int64(kVK_ANSI_A)))
    }
}
