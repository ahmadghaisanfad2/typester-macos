import XCTest
@testable import TypesterCore

final class TranscriptFormatterTests: XCTestCase {

    func testCollapseWhitespace() {
        XCTAssertEqual(TranscriptFormatter.format("hello   world"), "Hello world")
    }

    func testSpaceAfterComma() {
        XCTAssertEqual(TranscriptFormatter.format("hello,world"), "Hello, world")
    }

    func testSpaceAfterPeriod() {
        XCTAssertEqual(TranscriptFormatter.format("hi.there"), "Hi. There")
    }

    func testCapitalizeStart() {
        XCTAssertEqual(TranscriptFormatter.format("hello world"), "Hello world")
    }

    func testCapitalizeAfterSentence() {
        XCTAssertEqual(
            TranscriptFormatter.format("hello. world? yes! maybe"),
            "Hello. World? Yes! Maybe"
        )
    }

    func testAlreadyFormattedUnchanged() {
        XCTAssertEqual(
            TranscriptFormatter.format("Hello, world. How are you?"),
            "Hello, world. How are you?"
        )
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(TranscriptFormatter.format(""), "")
        XCTAssertEqual(TranscriptFormatter.format("   "), "")
    }

    func testTrimsEdges() {
        XCTAssertEqual(TranscriptFormatter.format("  hello.  "), "Hello.")
    }

    // MARK: - Styles

    func testNeutralStylePreservesPunctuation() {
        XCTAssertEqual(
            TranscriptFormatter.format("hello. world? yes", style: .neutral),
            "Hello. World? Yes"
        )
    }

    func testCasualStyleDropsSentencePeriods() {
        XCTAssertEqual(
            TranscriptFormatter.format("hello. world? yes!", style: .casual),
            "Hello world? Yes!"
        )
    }

    func testCasualStyleKeepsAbbreviations() {
        XCTAssertEqual(
            TranscriptFormatter.format("dr. smith is here.", style: .casual),
            "Dr. Smith is here"
        )
    }

    func testMinimalStyleStripsPunctuationAndCasing() {
        XCTAssertEqual(
            TranscriptFormatter.format("hello, world. how are you?", style: .minimal),
            "hello world how are you?"
        )
    }

    func testFormalStyleAddsTerminalPeriod() {
        XCTAssertEqual(
            TranscriptFormatter.format("hello world", style: .formal),
            "Hello world."
        )
    }

    func testFormalStyleKeepsExistingTerminalPunctuation() {
        XCTAssertEqual(
            TranscriptFormatter.format("hello world?", style: .formal),
            "Hello world?"
        )
    }

    // MARK: - Capitalization follows punctuation

    func testCasualLowercasesWordAfterDroppedPeriod() {
        XCTAssertEqual(
            TranscriptFormatter.format("Aku pergi ke pasar. Terus aku makan.", style: .casual),
            "Aku pergi ke pasar terus aku makan"
        )
    }

    func testCasualKeepsCapitalAfterQuestionAndExclamation() {
        XCTAssertEqual(
            TranscriptFormatter.format("Kamu di mana? Aku sudah sampai! Ayo makan.", style: .casual),
            "Kamu di mana? Aku sudah sampai! Ayo makan"
        )
    }

    func testCasualKeepsPronounIAcronymsAndMixedCase() {
        XCTAssertEqual(
            TranscriptFormatter.format("It works. I think so. NASA agrees. iPhone too.", style: .casual),
            "It works I think so NASA agrees iPhone too"
        )
    }

    func testCasualKeepsDictionaryTermsCapitalized() {
        XCTAssertEqual(
            TranscriptFormatter.format(
                "Aku tinggal di sini. Bandung itu sejuk.",
                style: .casual,
                preservedTerms: ["Bandung"]
            ),
            "Aku tinggal di sini Bandung itu sejuk"
        )
    }

    func testCasualKeepsNameSeenMidSentenceElsewhere() {
        XCTAssertEqual(
            TranscriptFormatter.format("Aku ketemu Budi tadi. Budi lagi makan.", style: .casual),
            "Aku ketemu Budi tadi Budi lagi makan"
        )
    }

    func testCasualContinuationStartsLowercase() {
        XCTAssertEqual(
            TranscriptFormatter.format("Terus aku pulang.", style: .casual, continuesSentence: true),
            "terus aku pulang"
        )
    }

    func testNeutralContinuationIsNotForceCapitalized() {
        XCTAssertEqual(
            TranscriptFormatter.format("lalu aku pulang.", style: .neutral, continuesSentence: true),
            "lalu aku pulang."
        )
    }

    func testDecimalDoesNotCapitalizeNextWord() {
        XCTAssertEqual(
            TranscriptFormatter.format("harganya 3.5 dollar saja", style: .neutral),
            "Harganya 3.5 dollar saja"
        )
    }

    func testNumbersKeepTheirSeparators() {
        XCTAssertEqual(
            TranscriptFormatter.format("jam 10:30 bayar 1,000 atau 2.5 juta", style: .neutral),
            "Jam 10:30 bayar 1,000 atau 2.5 juta"
        )
    }

    func testLatinAbbreviationDoesNotStartSentence() {
        XCTAssertEqual(
            TranscriptFormatter.format("buah, e.g. apel dan jeruk", style: .neutral),
            "Buah, e.g. apel dan jeruk"
        )
    }

    func testContinuationDetection() {
        XCTAssertFalse(TranscriptFormatter.continuesSentence(after: ""))
        XCTAssertFalse(TranscriptFormatter.continuesSentence(after: "Selesai."))
        XCTAssertFalse(TranscriptFormatter.continuesSentence(after: "Benarkah?\""))
        XCTAssertTrue(TranscriptFormatter.continuesSentence(after: "aku pergi ke pasar"))
        XCTAssertTrue(TranscriptFormatter.continuesSentence(after: "aku pergi, "))
    }
}
