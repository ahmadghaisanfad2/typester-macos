import XCTest
@testable import TypesterCore

final class PrimarySpeakerFilterTests: XCTestCase {
    func testUnlabeledTokensAlwaysIncluded() {
        let filter = PrimarySpeakerFilter()
        XCTAssertTrue(filter.shouldInclude(speaker: nil))
        XCTAssertTrue(filter.shouldInclude(speaker: ""))
        XCTAssertNil(filter.lockedSpeaker)
    }

    func testFirstSpeakerLocksPrimary() {
        let filter = PrimarySpeakerFilter()
        XCTAssertTrue(filter.shouldInclude(speaker: "1"))
        XCTAssertEqual(filter.lockedSpeaker, "1")
        XCTAssertTrue(filter.shouldInclude(speaker: "1"))
        XCTAssertFalse(filter.shouldInclude(speaker: "2"))
        XCTAssertFalse(filter.shouldInclude(speaker: "0"))
    }

    func testResetAllowsNewPrimary() {
        let filter = PrimarySpeakerFilter()
        XCTAssertTrue(filter.shouldInclude(speaker: "1"))
        filter.reset()
        XCTAssertNil(filter.lockedSpeaker)
        XCTAssertTrue(filter.shouldInclude(speaker: "2"))
        XCTAssertEqual(filter.lockedSpeaker, "2")
        XCTAssertFalse(filter.shouldInclude(speaker: "1"))
    }

    func testDeepgramIntegerSpeakerLabels() {
        let filter = PrimarySpeakerFilter()
        XCTAssertTrue(filter.shouldInclude(speaker: "0"))
        XCTAssertFalse(filter.shouldInclude(speaker: "1"))
    }
}

final class VoiceFocusConfigTests: XCTestCase {
    override func tearDown() {
        SettingsStore.shared.focusOnMyVoice = false
        super.tearDown()
    }

    func testSonioxConfigEnablesDiarizationWhenFocusOn() {
        let config = SonioxRealtimeSessionConfig.build(
            apiKey: "k",
            model: "stt-rt-v5",
            pasteOnPause: false,
            languageHints: ["en"],
            context: nil,
            focusOnMyVoice: true
        )
        XCTAssertEqual(config["enable_speaker_diarization"] as? Bool, true)
    }

    func testSonioxConfigOmitsDiarizationWhenFocusOff() {
        let config = SonioxRealtimeSessionConfig.build(
            apiKey: "k",
            model: "stt-rt-v5",
            pasteOnPause: false,
            languageHints: [],
            context: nil,
            focusOnMyVoice: false
        )
        XCTAssertNil(config["enable_speaker_diarization"])
    }

    func testSonioxParseEmitsSpeaker() {
        let config = SonioxConnectionConfig()
        let json: [String: Any] = [
            "tokens": [
                ["text": "Hello", "is_final": true, "speaker": "1"],
                ["text": " there", "is_final": true, "speaker": "2"]
            ]
        ]
        let results = config.parseResponse(json)
        XCTAssertEqual(results.count, 2)
        if case .transcript(let text, let isFinal, let speaker) = results[0] {
            XCTAssertEqual(text, "Hello")
            XCTAssertTrue(isFinal)
            XCTAssertEqual(speaker, "1")
        } else {
            XCTFail("Expected labeled transcript")
        }
        if case .transcript(_, _, let speaker) = results[1] {
            XCTAssertEqual(speaker, "2")
        } else {
            XCTFail("Expected second labeled transcript")
        }
    }

    func testDeepgramQueryIncludesDiarizeWhenFocusOn() {
        let items = DeepgramConnectionConfig.makeQueryItems(
            modelID: "nova-3",
            pasteOnPause: false,
            focusOnMyVoice: true
        )
        XCTAssertTrue(items.contains { $0.name == "diarize_model" && $0.value == "latest" })
    }

    func testDeepgramQueryOmitsDiarizeWhenFocusOff() {
        let items = DeepgramConnectionConfig.makeQueryItems(
            modelID: "nova-3",
            pasteOnPause: false,
            focusOnMyVoice: false
        )
        XCTAssertFalse(items.contains { $0.name == "diarize_model" })
    }

    func testDeepgramParseEmitsSpeakerFromWords() {
        let config = DeepgramConnectionConfig()
        let json: [String: Any] = [
            "is_final": true,
            "channel": [
                "alternatives": [[
                    "transcript": "hello world other person",
                    "words": [
                        ["word": "hello", "speaker": 0],
                        ["word": "world", "speaker": 0],
                        ["word": "other", "speaker": 1],
                        ["word": "person", "speaker": 1]
                    ]
                ]]
            ]
        ]
        let results = config.parseResponse(json)
        let transcripts = results.compactMap { result -> (String, String?)? in
            if case .transcript(let text, _, let speaker) = result {
                return (text, speaker)
            }
            return nil
        }
        XCTAssertEqual(transcripts.count, 2)
        XCTAssertEqual(transcripts[0].0, "hello world")
        XCTAssertEqual(transcripts[0].1, "0")
        XCTAssertEqual(transcripts[1].0, "other person")
        XCTAssertEqual(transcripts[1].1, "1")
    }

    func testRouteParseResultsFiltersOtherSpeakers() {
        let previous = SettingsStore.shared.focusOnMyVoice
        SettingsStore.shared.focusOnMyVoice = true
        defer { SettingsStore.shared.focusOnMyVoice = previous }

        let client = SonioxClient()
        var finals: [String] = []
        client.onTranscript = { text, isFinal in
            if isFinal { finals.append(text) }
        }

        client.routeParseResults([
            .transcript(text: "mine ", isFinal: true, speaker: "1"),
            .transcript(text: "theirs ", isFinal: true, speaker: "2"),
            .transcript(text: "again", isFinal: true, speaker: "1")
        ])

        // Soniox concatenates; filter skip still inserts a boundary space.
        XCTAssertEqual(finals, ["mine again"])
    }

    func testRouteParseResultsKeepsAllWhenFocusOff() {
        let previous = SettingsStore.shared.focusOnMyVoice
        SettingsStore.shared.focusOnMyVoice = false
        defer { SettingsStore.shared.focusOnMyVoice = previous }

        let client = SonioxClient()
        var finals: [String] = []
        client.onTranscript = { text, isFinal in
            if isFinal { finals.append(text) }
        }

        client.routeParseResults([
            .transcript(text: "mine ", isFinal: true, speaker: "1"),
            .transcript(text: "theirs ", isFinal: true, speaker: "2")
        ])

        XCTAssertEqual(finals, ["mine theirs "])
    }

    /// Regression: Deepgram speaker-runs omit padding; router must insert spaces
    /// so kept primary-speaker spans do not glue after another speaker is dropped.
    func testRouteParseResultsJoinsUnpaddedSpansAfterFiltering() {
        let previous = SettingsStore.shared.focusOnMyVoice
        SettingsStore.shared.focusOnMyVoice = true
        defer { SettingsStore.shared.focusOnMyVoice = previous }

        // Deepgram-style client (spaceBetweenUnpadded) + filter skip.
        let client = DeepgramStyleRoutingTestClient()
        var finals: [String] = []
        client.onTranscript = { text, isFinal in
            if isFinal { finals.append(text) }
        }

        client.routeParseResults([
            .transcript(text: "hello world", isFinal: true, speaker: "0"),
            .transcript(text: "other person", isFinal: true, speaker: "1"),
            .transcript(text: "again mine", isFinal: true, speaker: "0")
        ])

        XCTAssertEqual(finals, ["hello world again mine"])
    }

    func testRouteParseResultsDoesNotDoubleSpaceWhenProviderPads() {
        let previous = SettingsStore.shared.focusOnMyVoice
        SettingsStore.shared.focusOnMyVoice = true
        defer { SettingsStore.shared.focusOnMyVoice = previous }

        let client = SonioxClient()
        var finals: [String] = []
        client.onTranscript = { text, isFinal in
            if isFinal { finals.append(text) }
        }

        client.routeParseResults([
            .transcript(text: "hello ", isFinal: true, speaker: "1"),
            .transcript(text: "world", isFinal: true, speaker: "1")
        ])

        XCTAssertEqual(finals, ["hello world"])
    }

    func testDeepgramUnlabeledWordsFallBackToChannelTranscript() {
        let config = DeepgramConnectionConfig()
        let json: [String: Any] = [
            "is_final": true,
            "channel": [
                "alternatives": [[
                    "transcript": "Hello, world.",
                    "words": [
                        ["word": "Hello"],
                        ["word": "world"]
                    ]
                ]]
            ]
        ]
        let results = config.parseResponse(json)
        guard case .transcript(let text, _, let speaker) = results[0] else {
            XCTFail("Expected channel transcript")
            return
        }
        XCTAssertEqual(text, "Hello, world.")
        XCTAssertNil(speaker)
    }
}

/// Minimal STT client for exercising routeParseResults without a network connection.
private final class VoiceFocusRoutingTestClient: STTClientBase {
    override func makeConnectionConfig() -> STTConnectionConfig {
        SonioxConnectionConfig()
    }
    override var transcriptJoinStyle: TranscriptTokenJoinStyle { .concatenate }
}

private final class DeepgramStyleRoutingTestClient: STTClientBase {
    override func makeConnectionConfig() -> STTConnectionConfig {
        DeepgramConnectionConfig()
    }
    override var transcriptJoinStyle: TranscriptTokenJoinStyle { .spaceBetweenUnpadded }
}
