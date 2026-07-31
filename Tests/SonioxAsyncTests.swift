import XCTest
@testable import TypesterCore

final class SonioxAsyncTests: XCTestCase {

    // MARK: - SonioxTranscribeMode

    func testSonioxTranscribeModeRawValues() {
        XCTAssertEqual(SonioxTranscribeMode.realtime.rawValue, "realtime")
        XCTAssertEqual(SonioxTranscribeMode.async.rawValue, "async")
    }

    func testSonioxTranscribeModeDisplayNames() {
        XCTAssertEqual(SonioxTranscribeMode.realtime.displayName, "Real-time")
        XCTAssertEqual(SonioxTranscribeMode.async.displayName, "Async")
    }

    func testSonioxTranscribeModeModelIDs() {
        XCTAssertEqual(SonioxTranscribeMode.realtime.modelID, "stt-rt-v5")
        XCTAssertEqual(SonioxTranscribeMode.async.modelID, "stt-async-v5")
    }

    func testSonioxTranscribeModeAllCases() {
        XCTAssertEqual(SonioxTranscribeMode.allCases.count, 2)
    }

    func testSTTProviderTypeModelIDFollowsSonioxMode() {
        let store = SettingsStore.shared
        let previous = store.sonioxMode
        defer { store.sonioxMode = previous }

        store.sonioxMode = .realtime
        XCTAssertEqual(STTProviderType.soniox.modelID, "stt-rt-v5")

        store.sonioxMode = .async
        XCTAssertEqual(STTProviderType.soniox.modelID, "stt-async-v5")
    }

    // MARK: - Realtime session config (endpoint gating)

    func testRealtimeConfigDisablesEndpointWhenPasteOnPauseOff() {
        let config = SonioxRealtimeSessionConfig.build(
            apiKey: "key",
            model: "stt-rt-v5",
            pasteOnPause: false,
            languageHints: [],
            context: nil
        )
        XCTAssertEqual(config["enable_endpoint_detection"] as? Bool, false)
        XCTAssertNil(config["endpoint_sensitivity"])
        XCTAssertNil(config["max_endpoint_delay_ms"])
    }

    func testRealtimeConfigEnablesConservativeEndpointWhenPasteOnPauseOn() {
        let config = SonioxRealtimeSessionConfig.build(
            apiKey: "key",
            model: "stt-rt-v5",
            pasteOnPause: true,
            languageHints: ["en"],
            context: ["general": [["key": "domain", "value": "Test"]]]
        )
        XCTAssertEqual(config["enable_endpoint_detection"] as? Bool, true)
        XCTAssertEqual(config["endpoint_sensitivity"] as? Double, -0.7)
        XCTAssertEqual(config["max_endpoint_delay_ms"] as? Int, 3000)
        XCTAssertEqual(config["language_hints"] as? [String], ["en"])
        XCTAssertNotNil(config["context"])
    }

    // MARK: - WAV encoder

    func testPCMWavEncoderHeaderAndSize() {
        let pcm = Data(repeating: 0, count: 320) // 160 samples @ 16-bit
        let wav = PCMWavEncoder.wavData(pcm: pcm, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + pcm.count)

        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data")

        let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(dataSize, UInt32(pcm.count))

        let sampleRate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(sampleRate, 16_000)
    }

    // MARK: - Async API parsing

    func testParseFileID() throws {
        let data = #"{"id":"file-123","filename":"typester.wav"}"#.data(using: .utf8)!
        XCTAssertEqual(try SonioxAsyncAPI.parseFileID(from: data), "file-123")
    }

    func testParseTranscriptionStatusCompleted() throws {
        let data = #"{"id":"t1","status":"completed"}"#.data(using: .utf8)!
        let parsed = try SonioxAsyncAPI.parseTranscriptionStatus(from: data)
        XCTAssertEqual(parsed.status, "completed")
        XCTAssertNil(parsed.errorMessage)
    }

    func testParseTranscriptionStatusError() throws {
        let data = #"{"id":"t1","status":"error","error_message":"bad audio"}"#.data(using: .utf8)!
        let parsed = try SonioxAsyncAPI.parseTranscriptionStatus(from: data)
        XCTAssertEqual(parsed.status, "error")
        XCTAssertEqual(parsed.errorMessage, "bad audio")
    }

    func testParseTranscriptText() throws {
        let data = #"{"id":"t1","text":"Hello world"}"#.data(using: .utf8)!
        XCTAssertEqual(try SonioxAsyncAPI.parseTranscriptText(from: data), "Hello world")
    }

    func testApiErrorMessagePrefersMessageField() {
        let data = #"{"message":"Invalid model","status_code":400}"#.data(using: .utf8)!
        XCTAssertEqual(SonioxAsyncAPI.apiErrorMessage(from: data, statusCode: 400), "Invalid model")
    }
}
