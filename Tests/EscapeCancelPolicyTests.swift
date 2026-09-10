import XCTest
@testable import TypesterCore

final class EscapeCancelPolicyTests: XCTestCase {

    func testConsumesEscapeWhileRecording() {
        let decision = EscapeCancelPolicy.decision(
            isRecording: true,
            isOverlayActive: false
        )
        XCTAssertTrue(decision.shouldCancel)
        XCTAssertTrue(decision.shouldConsumeEvent)
    }

    func testConsumesEscapeWhileOverlayActiveDuringProcessing() {
        // After stopRecording, isRecording is false but the pill still shows
        // "Transcribing…". ESC must still cancel and not reach the front app.
        let decision = EscapeCancelPolicy.decision(
            isRecording: false,
            isOverlayActive: true
        )
        XCTAssertTrue(decision.shouldCancel)
        XCTAssertTrue(decision.shouldConsumeEvent)
    }

    func testIgnoresEscapeWhenIdle() {
        let decision = EscapeCancelPolicy.decision(
            isRecording: false,
            isOverlayActive: false
        )
        XCTAssertFalse(decision.shouldCancel)
        XCTAssertFalse(decision.shouldConsumeEvent)
    }

    func testEscapeKeyCodeRecognition() {
        XCTAssertTrue(EscapeCancelPolicy.isEscapeKeyCode(53))
        XCTAssertFalse(EscapeCancelPolicy.isEscapeKeyCode(0))
        XCTAssertFalse(EscapeCancelPolicy.isEscapeKeyCode(63))
    }
}
