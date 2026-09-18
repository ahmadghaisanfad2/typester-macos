import XCTest
@testable import TypesterCore

final class TranscriptAssemblyTests: XCTestCase {
    func testBaseRouterForwardsFinalBatchesAsDeltas() {
        let client = STTClientBase()
        var finals: [String] = []
        client.onTranscript = { text, isFinal in
            if isFinal { finals.append(text) }
        }

        client.routeParseResults([.transcript(text: "first ", isFinal: true, speaker: nil)])
        client.routeParseResults([.transcript(text: "second", isFinal: true, speaker: nil)])

        XCTAssertEqual(finals, ["first ", "second"])
    }

    func testBaseRouterSurfacesFinalizeAcknowledgement() {
        let client = FinalizeProbeClient()

        client.routeParseResults([.finalizeAcknowledged])

        XCTAssertEqual(client.acknowledgementCount, 1)
    }

    func testFinalTokensAppendAcrossBatchesWithoutPrefixDeduplication() {
        let assembler = TranscriptSessionAssembler(joinStyle: .spaceBetweenUnpadded)

        assembler.appendFinal("The first few words ")
        assembler.appendFinal("continue after the pause")

        XCTAssertEqual(assembler.finalText, "The first few words continue after the pause")
        XCTAssertEqual(assembler.resolvedText, "The first few words continue after the pause")
    }

    func testAppendFinalInsertsSpaceBetweenUnpaddedDeltas() {
        let assembler = TranscriptSessionAssembler(joinStyle: .spaceBetweenUnpadded)

        assembler.appendFinal("hello world")
        assembler.appendFinal("again mine")

        XCTAssertEqual(assembler.finalText, "hello world again mine")
    }

    func testAppendFinalDoesNotDoubleSpaceWhenProviderPads() {
        let assembler = TranscriptSessionAssembler(joinStyle: .spaceBetweenUnpadded)

        assembler.appendFinal("hello ")
        assembler.appendFinal("world")

        XCTAssertEqual(assembler.finalText, "hello world")
    }

    func testInterimIsReplacedAndFinalClearsInterim() {
        let assembler = TranscriptSessionAssembler(joinStyle: .concatenate)

        assembler.replaceInterim("The first wor")
        assembler.replaceInterim("The first words")
        XCTAssertEqual(assembler.resolvedText, "The first words")

        assembler.appendFinal("The first words")
        XCTAssertEqual(assembler.interimText, "")
        XCTAssertEqual(assembler.resolvedText, "The first words")
    }

    func testResetStartsAIndependentSession() {
        let assembler = TranscriptSessionAssembler(joinStyle: .concatenate)
        assembler.appendFinal("old session")

        assembler.reset()
        assembler.appendFinal("new session")

        XCTAssertEqual(assembler.resolvedText, "new session")
    }
}

private final class FinalizeProbeClient: STTClientBase {
    var acknowledgementCount = 0

    override func onFinalizeAcknowledged() {
        acknowledgementCount += 1
    }
}

final class AudioSessionBufferTests: XCTestCase {
    func testTakeReturnsAllAudioAndEmptiesBuffer() {
        let buffer = AudioSessionBuffer()
        buffer.append(Data([0, 1]))
        buffer.append(Data([2, 3]))

        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.take(), Data([0, 1, 2, 3]))
        XCTAssertTrue(buffer.isEmpty)
    }
}
