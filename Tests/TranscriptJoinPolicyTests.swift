import XCTest
@testable import TypesterCore

final class TranscriptJoinPolicyTests: XCTestCase {
    func testConcatenateDoesNotForceSpaces() {
        let joined = [
            "He", "y,", " go", "od", " mor", "ning."
        ].reduce("") { TranscriptJoinPolicy.join(left: $0, right: $1, style: .concatenate) }
        XCTAssertEqual(joined, "Hey, good morning.")
    }

    func testSpaceBetweenUnpaddedInsertsSingleBoundary() {
        XCTAssertEqual(
            TranscriptJoinPolicy.join(left: "hello world", right: "again mine", style: .spaceBetweenUnpadded),
            "hello world again mine"
        )
        XCTAssertEqual(
            TranscriptJoinPolicy.join(left: "hello ", right: "world", style: .spaceBetweenUnpadded),
            "hello world"
        )
    }

    func testFilterSkipEnsuresBoundarySpaceForUnpaddedStyles() {
        XCTAssertEqual(
            TranscriptJoinPolicy.joinAcrossFilterSkip(
                left: "hello world", right: "again mine", style: .spaceBetweenUnpadded
            ),
            "hello world again mine"
        )
        XCTAssertEqual(
            TranscriptJoinPolicy.joinAcrossFilterSkip(
                left: "mine ", right: "again", style: .spaceBetweenUnpadded
            ),
            "mine again"
        )
    }

    func testFilterSkipDoesNotSplitConcatenateTokens() {
        // Soniox sub-word tokens interruptible by a dropped (background) token
        // must never gain a forced space mid-word.
        XCTAssertEqual(
            TranscriptJoinPolicy.joinAcrossFilterSkip(left: "He", right: "y,", style: .concatenate),
            "Hey,"
        )
        XCTAssertEqual(
            TranscriptJoinPolicy.joinAcrossFilterSkip(left: "wel", right: "come", style: .concatenate),
            "welcome"
        )
    }

    func testSonioxProviderUsesConcatenate() {
        XCTAssertEqual(STTProviderType.soniox.transcriptJoinStyle, .concatenate)
        XCTAssertEqual(SonioxConnectionConfig().transcriptJoinStyle, .concatenate)
        XCTAssertEqual(SonioxClient().transcriptJoinStyle, .concatenate)
        XCTAssertEqual(STTProviderType.deepgram.transcriptJoinStyle, .spaceBetweenUnpadded)
    }
}

final class SonioxTokenAssemblyTests: XCTestCase {
    override func tearDown() {
        SettingsStore.shared.focusOnMyVoice = false
        super.tearDown()
    }

    func testSubwordTokensAreNotSpaceSplit() {
        let client = SonioxClient()
        var finals: [String] = []
        client.onTranscript = { text, isFinal in
            if isFinal { finals.append(text) }
        }

        // Soniox-style subtokens without padding — must concatenate, not space-split.
        client.routeParseResults([
            .transcript(text: "He", isFinal: true, speaker: nil),
            .transcript(text: "y,", isFinal: true, speaker: nil),
            .transcript(text: " go", isFinal: true, speaker: nil),
            .transcript(text: "od", isFinal: true, speaker: nil),
        ])

        XCTAssertEqual(finals, ["Hey, good"])
    }

    func testAssemblerConcatenateForSonioxStyle() {
        let assembler = TranscriptSessionAssembler(joinStyle: .concatenate)
        assembler.appendFinal("He")
        assembler.appendFinal("y,")
        assembler.appendFinal(" go")
        assembler.appendFinal("od")
        XCTAssertEqual(assembler.finalText, "Hey, good")
    }

    func testAssemblerSpaceJoinForDeepgramStyle() {
        let assembler = TranscriptSessionAssembler(joinStyle: .spaceBetweenUnpadded)
        assembler.appendFinal("hello world")
        assembler.appendFinal("again mine")
        XCTAssertEqual(assembler.finalText, "hello world again mine")
    }
}
