import XCTest
@testable import TypesterCore

final class UpdateCheckerTests: XCTestCase {

    func testNormalizeTagStripsPrefix() {
        XCTAssertEqual(UpdateVersioning.normalizeTag("v1.5.0"), "1.5.0")
        XCTAssertEqual(UpdateVersioning.normalizeTag("V1.5.0"), "1.5.0")
        XCTAssertEqual(UpdateVersioning.normalizeTag(" 1.5.0 "), "1.5.0")
    }

    func testCompareVersions() {
        XCTAssertEqual(UpdateVersioning.compare("1.4.0", "1.5.0"), .ascending)
        XCTAssertEqual(UpdateVersioning.compare("1.5.0", "1.5.0"), .same)
        XCTAssertEqual(UpdateVersioning.compare("1.5.1", "1.5.0"), .descending)
        XCTAssertEqual(UpdateVersioning.compare("1.5", "1.5.0"), .same)
        XCTAssertEqual(UpdateVersioning.compare("v1.4.0", "1.5.0"), .ascending)
    }

    func testIsNewer() {
        XCTAssertTrue(UpdateVersioning.isNewer(latest: "1.5.0", than: "1.4.0"))
        XCTAssertFalse(UpdateVersioning.isNewer(latest: "1.5.0", than: "1.5.0"))
        XCTAssertFalse(UpdateVersioning.isNewer(latest: "1.4.0", than: "1.5.0"))
    }

    func testParseReleasePrefersTypesterDMG() {
        let json: [String: Any] = [
            "tag_name": "v1.5.0",
            "html_url": "https://github.com/ahmadghaisanfad2/typester-macos/releases/tag/v1.5.0",
            "assets": [
                [
                    "name": "notes.txt",
                    "browser_download_url": "https://example.com/notes.txt"
                ],
                [
                    "name": "Other.dmg",
                    "browser_download_url": "https://example.com/Other.dmg"
                ],
                [
                    "name": "Typester-1.5.0.dmg",
                    "browser_download_url": "https://example.com/Typester-1.5.0.dmg"
                ]
            ]
        ]

        let release = GitHubReleaseInfo.parse(json: json)
        XCTAssertEqual(release?.tagName, "v1.5.0")
        XCTAssertEqual(release?.dmgDownloadURL?.absoluteString, "https://example.com/Typester-1.5.0.dmg")
    }

    func testOutcomeUpToDate() throws {
        let payload: [String: Any] = [
            "tag_name": "v1.5.0",
            "html_url": "https://example.com/release",
            "assets": [
                [
                    "name": "Typester-1.5.0.dmg",
                    "browser_download_url": "https://example.com/Typester-1.5.0.dmg"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let outcome = UpdateChecker.outcome(
            data: data,
            response: HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ),
            error: nil,
            currentVersion: "1.5.0"
        )

        guard case .upToDate(let current, let latest) = outcome else {
            return XCTFail("Expected upToDate, got \(outcome)")
        }
        XCTAssertEqual(current, "1.5.0")
        XCTAssertEqual(latest, "1.5.0")
    }

    func testOutcomeUpdateAvailable() throws {
        let payload: [String: Any] = [
            "tag_name": "v1.6.0",
            "html_url": "https://example.com/release",
            "assets": [
                [
                    "name": "Typester-1.6.0.dmg",
                    "browser_download_url": "https://example.com/Typester-1.6.0.dmg"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let outcome = UpdateChecker.outcome(
            data: data,
            response: HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ),
            error: nil,
            currentVersion: "1.5.0"
        )

        guard case .updateAvailable(let current, let latest, let dmgURL, _) = outcome else {
            return XCTFail("Expected updateAvailable, got \(outcome)")
        }
        XCTAssertEqual(current, "1.5.0")
        XCTAssertEqual(latest, "1.6.0")
        XCTAssertEqual(dmgURL.absoluteString, "https://example.com/Typester-1.6.0.dmg")
    }

    func testOutcomeNoRelease() {
        let outcome = UpdateChecker.outcome(
            data: Data(),
            response: HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            ),
            error: nil,
            currentVersion: "1.5.0"
        )
        XCTAssertEqual(outcome, .noRelease)
    }

    func testGithubConstantsPointAtFork() {
        XCTAssertTrue(githubURL.contains("ahmadghaisanfad2/typester-macos"))
        XCTAssertTrue(githubReleasesAPIURL.contains("ahmadghaisanfad2/typester-macos/releases/latest"))
    }
}
