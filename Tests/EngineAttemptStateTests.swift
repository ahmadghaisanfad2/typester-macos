import XCTest
@testable import TypesterCore

final class EngineAttemptStateTests: XCTestCase {
    func testCompletionClaimsExactlyOnce() {
        let state = EngineAttemptState()
        XCTAssertTrue(state.claimCompletion())
        XCTAssertFalse(state.claimCompletion())
        XCTAssertFalse(state.claimAbandonment())
        XCTAssertFalse(state.wasAbandoned)
    }

    func testAbandonmentExcludesLateCompletion() {
        let state = EngineAttemptState()
        XCTAssertTrue(state.claimAbandonment())
        XCTAssertTrue(state.wasAbandoned)
        XCTAssertFalse(state.claimCompletion())
        XCTAssertFalse(state.claimAbandonment())
    }

    func testCompletionExcludesLateAbandonment() {
        let state = EngineAttemptState()
        XCTAssertTrue(state.claimCompletion())
        XCTAssertFalse(state.claimAbandonment())
        XCTAssertFalse(state.wasAbandoned)
    }
}
