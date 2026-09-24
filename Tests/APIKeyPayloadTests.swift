import XCTest
@testable import TypesterCore

final class APIKeyPayloadTests: XCTestCase {
    func testRoundTripsThroughJSON() {
        var payload = APIKeyPayload()
        payload.setKey("soniox-secret", for: "soniox-api-key")
        payload.setKey("deepgram-secret", for: "deepgram-api-key")

        let json = payload.json
        XCTAssertNotNil(json)

        let decoded = APIKeyPayload(json: json!)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded?.key(for: "soniox-api-key"), "soniox-secret")
        XCTAssertEqual(decoded?.key(for: "deepgram-api-key"), "deepgram-secret")
    }

    func testAccountsDriveTheConfiguredAnswer() {
        var payload = APIKeyPayload()
        XCTAssertTrue(payload.accounts.isEmpty)

        payload.setKey("a", for: "soniox-api-key")
        XCTAssertEqual(payload.accounts, ["soniox-api-key"])

        // Removing drops the account, which is what `hasAPIKey` reports.
        payload.setKey(nil, for: "soniox-api-key")
        XCTAssertTrue(payload.accounts.isEmpty)
        XCTAssertNil(payload.key(for: "soniox-api-key"))
    }

    func testEmptyValueRemovesInsteadOfStoringAnEmptyKey() {
        var payload = APIKeyPayload()
        payload.setKey("a", for: "openai-api-key")
        payload.setKey("", for: "openai-api-key")

        XCTAssertTrue(payload.accounts.isEmpty)
        XCTAssertNil(payload.key(for: "openai-api-key"))

        // And an empty value never counts as a key on the way in either.
        let fromJSON = APIKeyPayload(keys: ["openai-api-key": ""])
        XCTAssertTrue(fromJSON.accounts.isEmpty)
    }

    func testMalformedJSONIsRejectedSoCallersCanMigrate() {
        XCTAssertNil(APIKeyPayload(json: "not json at all"))
        XCTAssertNil(APIKeyPayload(json: "{\"a\": 1}"))
        XCTAssertNil(APIKeyPayload(json: ""))
    }

    func testEmptyPayloadStillEncodes() {
        // The store writes an empty payload after the last key is removed, so
        // this must not be confused with "no payload".
        let json = APIKeyPayload().json
        XCTAssertNotNil(json)
        XCTAssertEqual(APIKeyPayload(json: json!), APIKeyPayload())
    }
}
