import XCTest
@testable import TypesterCore

final class AudioRecordingLifecycleTests: XCTestCase {
    func testStopCancelsPendingPermissionAndIgnoresLateGrant() {
        var lifecycle = AudioRecordingLifecycle()
        XCTAssertTrue(lifecycle.begin())
        XCTAssertTrue(lifecycle.stop())
        XCTAssertFalse(lifecycle.resolvePermission(granted: true))
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testFailedStartReturnsToIdleForSafeRetry() {
        var lifecycle = AudioRecordingLifecycle()
        XCTAssertTrue(lifecycle.begin())
        XCTAssertTrue(lifecycle.resolvePermission(granted: true))
        lifecycle.failStarting()
        XCTAssertTrue(lifecycle.begin())
    }

    func testPermissionDenialCompletesTheCurrentAttempt() {
        var lifecycle = AudioRecordingLifecycle()
        XCTAssertTrue(lifecycle.begin())
        XCTAssertTrue(lifecycle.resolvePermission(granted: false))
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testSecondStartIsRejectedUntilRecordingStops() {
        var lifecycle = AudioRecordingLifecycle()
        XCTAssertTrue(lifecycle.begin())
        XCTAssertFalse(lifecycle.begin())
        XCTAssertTrue(lifecycle.resolvePermission(granted: true))
        lifecycle.finishStarting()
        XCTAssertTrue(lifecycle.stop())
        XCTAssertTrue(lifecycle.begin())
    }
}
