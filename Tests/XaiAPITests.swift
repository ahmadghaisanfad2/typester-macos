import XCTest
@testable import TypesterCore

final class XaiAPITests: XCTestCase {
    func testMakeQueryItemsUsesStreamingDefaults() {
        let items = XaiAPI.makeQueryItems(language: nil, focusOnMyVoice: false, keyterms: [])
        let map = Dictionary(grouping: items, by: \.name).compactMapValues { $0.first?.value }

        XCTAssertEqual(map["sample_rate"], "16000")
        XCTAssertEqual(map["encoding"], "pcm")
        XCTAssertEqual(map["interim_results"], "true")
        XCTAssertNil(map["language"])
        XCTAssertNil(map["diarize"])
    }

    func testMakeQueryItemsIncludesLanguageAndDiarization() {
        let items = XaiAPI.makeQueryItems(language: "en", focusOnMyVoice: true, keyterms: [])
        let map = Dictionary(grouping: items, by: \.name).compactMapValues { $0.first?.value }

        XCTAssertEqual(map["language"], "en")
        XCTAssertEqual(map["diarize"], "true")
    }

    func testMakeQueryItemsRepeatsKeyterms() {
        let items = XaiAPI.makeQueryItems(
            language: nil,
            focusOnMyVoice: false,
            keyterms: ["Typester", "Grok"]
        )
        let keyterms = items.filter { $0.name == "keyterm" }.compactMap(\.value)
        XCTAssertEqual(keyterms, ["Typester", "Grok"])
    }

    func testSanitizedKeytermsTrimsDropsEmptyAndDeduplicates() {
        let terms = XaiAPI.sanitizedKeyterms(["  Typester ", "Typester", "", "   ", "Grok"])
        XCTAssertEqual(terms, ["Typester", "Grok"])
    }

    func testSanitizedKeytermsDropsOverlongTerms() {
        let long = String(repeating: "a", count: XaiAPI.keytermMaxLength + 1)
        XCTAssertTrue(XaiAPI.sanitizedKeyterms([long]).isEmpty)
    }

    func testMakeMultipartBodyPlacesFileLast() {
        let boundary = "Boundary-Test"
        let body = XaiAPI.makeMultipartBody(
            boundary: boundary,
            model: "grok-voice-transcribe-2",
            language: "en",
            keyterms: ["Typester"],
            wav: Data([0x01, 0x02])
        )
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("grok-voice-transcribe-2"))
        XCTAssertTrue(text.contains("name=\"language\""))
        XCTAssertTrue(text.contains("name=\"format\""))
        XCTAssertTrue(text.contains("name=\"keyterm\""))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"typester.wav\""))

        let fileIndex = try? XCTUnwrap(text.range(of: "name=\"file\""))
        let keytermIndex = try? XCTUnwrap(text.range(of: "name=\"keyterm\""))
        XCTAssertNotNil(fileIndex)
        XCTAssertNotNil(keytermIndex)
        if let fileIndex, let keytermIndex {
            XCTAssertGreaterThan(fileIndex.lowerBound, keytermIndex.lowerBound)
        }
    }

    func testMakeMultipartBodyOmitsLanguageWhenAbsent() {
        let body = XaiAPI.makeMultipartBody(
            boundary: "B",
            model: "grok-voice-transcribe-2",
            language: nil,
            keyterms: [],
            wav: Data([0x00])
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"language\""))
        XCTAssertFalse(text.contains("name=\"format\""))
    }

    func testParseRestText() throws {
        let json = """
        { "text": "hello from xai", "language": "English", "duration": 1.2 }
        """.data(using: .utf8)!

        XCTAssertEqual(try XaiAPI.parseRestText(from: json), "hello from xai")
    }

    func testParseRestTextMissingTextThrows() {
        let json = """
        { "duration": 1.2 }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try XaiAPI.parseRestText(from: json))
    }

    func testApiErrorMessagePrefersNestedError() {
        let data = """
        { "error": { "message": "Model not found" } }
        """.data(using: .utf8)!
        XCTAssertEqual(XaiAPI.apiErrorMessage(from: data, statusCode: 404), "Model not found")
    }

    func testTranscriptionsURL() {
        XCTAssertEqual(XaiAPI.transcriptionsURL.absoluteString, "https://api.x.ai/v1/stt")
    }
}
