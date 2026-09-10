import XCTest
@testable import TypesterCore

final class OpenRouterAPITests: XCTestCase {
    func testParseModelsFiltersAndSortsByName() throws {
        let json = """
        {
          "data": [
            {
              "id": "openai/whisper-1",
              "name": "OpenAI: Whisper 1",
              "architecture": { "output_modalities": ["transcription"] }
            },
            {
              "id": "deepgram/nova-3",
              "name": "Deepgram: Nova-3",
              "architecture": { "output_modalities": ["transcription"] }
            },
            {
              "id": "",
              "name": "Empty"
            }
          ]
        }
        """.data(using: .utf8)!

        let models = try OpenRouterAPI.parseModels(from: json)
        XCTAssertEqual(models.map(\.id), ["deepgram/nova-3", "openai/whisper-1"])
        XCTAssertEqual(models.map(\.name), ["Deepgram: Nova-3", "OpenAI: Whisper 1"])
    }

    func testParseModelsFallsBackToIDWhenNameMissing() throws {
        let json = """
        {
          "data": [
            { "id": "openai/whisper-large-v3" }
          ]
        }
        """.data(using: .utf8)!

        let models = try OpenRouterAPI.parseModels(from: json)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "openai/whisper-large-v3")
        XCTAssertEqual(models[0].name, "openai/whisper-large-v3")
    }

    func testParseTranscriptText() throws {
        let json = """
        { "text": "hello from openrouter", "usage": { "seconds": 1.2 } }
        """.data(using: .utf8)!

        XCTAssertEqual(try OpenRouterAPI.parseTranscriptText(from: json), "hello from openrouter")
    }

    func testParseTranscriptTextMissingTextThrows() {
        let json = """
        { "usage": { "seconds": 1.2 } }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try OpenRouterAPI.parseTranscriptText(from: json))
    }

    func testMakeTranscriptionBodyIncludesBase64AndOptionalLanguage() {
        let wav = Data([0x01, 0x02, 0x03, 0x04])
        let body = OpenRouterAPI.makeTranscriptionBody(
            model: "openai/whisper-large-v3",
            wav: wav,
            language: "en"
        )

        XCTAssertEqual(body["model"] as? String, "openai/whisper-large-v3")
        XCTAssertEqual(body["language"] as? String, "en")
        let audio = body["input_audio"] as? [String: String]
        XCTAssertEqual(audio?["format"], "wav")
        XCTAssertEqual(audio?["data"], wav.base64EncodedString())
    }

    func testMakeTranscriptionBodyOmitsEmptyLanguage() {
        let body = OpenRouterAPI.makeTranscriptionBody(
            model: "openai/whisper-1",
            wav: Data([0xAA]),
            language: nil
        )
        XCTAssertNil(body["language"])
    }

    func testApiErrorMessagePrefersNestedError() {
        let data = """
        { "error": { "message": "Model not found" } }
        """.data(using: .utf8)!
        XCTAssertEqual(OpenRouterAPI.apiErrorMessage(from: data, statusCode: 404), "Model not found")
    }

    func testModelsURLRequestsTranscriptionModality() {
        let url = OpenRouterAPI.modelsURL.absoluteString
        XCTAssertTrue(url.contains("output_modalities=transcription"))
    }
}
