import XCTest
@testable import TypesterCore

final class PermissionSetupTests: XCTestCase {
    func testFreshInstallShowsOnboardingFromAPIKey() {
        XCTAssertTrue(
            PermissionSetup.shouldShowOnboarding(
                hasAPIKey: false,
                microphoneGranted: false,
                accessibilityGranted: false
            )
        )
        XCTAssertEqual(
            PermissionSetup.startStep(
                hasAPIKey: false,
                microphoneGranted: false,
                accessibilityGranted: false
            ),
            .apiKey
        )
    }

    func testAPIKeyWithoutPermissionsShowsOnboardingAtMic() {
        XCTAssertTrue(
            PermissionSetup.shouldShowOnboarding(
                hasAPIKey: true,
                microphoneGranted: false,
                accessibilityGranted: false
            )
        )
        XCTAssertEqual(
            PermissionSetup.startStep(
                hasAPIKey: true,
                microphoneGranted: false,
                accessibilityGranted: false
            ),
            .microphone
        )
    }

    func testMicGrantedWithoutAccessibilityShowsOnboardingAtAccessibility() {
        XCTAssertTrue(
            PermissionSetup.shouldShowOnboarding(
                hasAPIKey: true,
                microphoneGranted: true,
                accessibilityGranted: false
            )
        )
        XCTAssertEqual(
            PermissionSetup.startStep(
                hasAPIKey: true,
                microphoneGranted: true,
                accessibilityGranted: false
            ),
            .accessibility
        )
    }

    func testFullyConfiguredDoesNotShowOnboarding() {
        XCTAssertFalse(
            PermissionSetup.shouldShowOnboarding(
                hasAPIKey: true,
                microphoneGranted: true,
                accessibilityGranted: true
            )
        )
    }
}
