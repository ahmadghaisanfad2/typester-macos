import XCTest
@testable import TypesterCore

final class PermissionRecoveryTests: XCTestCase {
    func testOffersRecoveryOnlyWhenTrustWasLost() {
        XCTAssertTrue(
            PermissionRecovery.shouldOfferRecoveryAfterUpdate(lastKnownTrusted: true, currentlyTrusted: false)
        )
        XCTAssertFalse(
            PermissionRecovery.shouldOfferRecoveryAfterUpdate(lastKnownTrusted: true, currentlyTrusted: true)
        )
        XCTAssertFalse(
            PermissionRecovery.shouldOfferRecoveryAfterUpdate(lastKnownTrusted: false, currentlyTrusted: false)
        )
        XCTAssertFalse(
            PermissionRecovery.shouldOfferRecoveryAfterUpdate(lastKnownTrusted: false, currentlyTrusted: true)
        )
    }

    func testFailedActivationRecoveryRespectsSessionDismissal() {
        XCTAssertTrue(
            PermissionRecovery.shouldShowRecoveryOnFailedActivation(
                currentlyTrusted: false,
                alreadyDismissedThisSession: false
            )
        )
        XCTAssertFalse(
            PermissionRecovery.shouldShowRecoveryOnFailedActivation(
                currentlyTrusted: false,
                alreadyDismissedThisSession: true
            )
        )
        XCTAssertFalse(
            PermissionRecovery.shouldShowRecoveryOnFailedActivation(
                currentlyTrusted: true,
                alreadyDismissedThisSession: false
            )
        )
    }

    func testMarkAndReadLastKnownTrusted() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: PermissionRecovery.lastKnownAccessibilityTrustedKey)
        defer {
            if let original {
                defaults.set(original, forKey: PermissionRecovery.lastKnownAccessibilityTrustedKey)
            } else {
                defaults.removeObject(forKey: PermissionRecovery.lastKnownAccessibilityTrustedKey)
            }
        }

        PermissionRecovery.markAccessibilityTrusted(true)
        XCTAssertTrue(PermissionRecovery.lastKnownAccessibilityTrusted())

        PermissionRecovery.markAccessibilityTrusted(false)
        XCTAssertFalse(PermissionRecovery.lastKnownAccessibilityTrusted())
    }

    func testSessionDismissalRoundTrip() {
        PermissionRecovery.resetSessionDismissal()
        XCTAssertFalse(PermissionRecovery.recoveryDismissedForSession())

        PermissionRecovery.markRecoveryDismissedForSession()
        XCTAssertTrue(PermissionRecovery.recoveryDismissedForSession())

        PermissionRecovery.resetSessionDismissal()
        XCTAssertFalse(PermissionRecovery.recoveryDismissedForSession())
    }
}
