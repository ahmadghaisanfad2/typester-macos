import XCTest
@testable import TypesterCore

final class FillerWordRemoverTests: XCTestCase {

    func testRemovesCommonSoundFillers() {
        let input = "I was uh thinking um we should go"
        XCTAssertEqual(FillerWordRemover.removeFillers(from: input), "I was thinking we should go")
    }

    func testRemovesFillerWithTrailingComma() {
        let input = "Well, um, I am not sure"
        XCTAssertEqual(FillerWordRemover.removeFillers(from: input), "Well, I am not sure")
    }

    func testRemovesYouKnowPhrase() {
        let input = "It is you know pretty good"
        XCTAssertEqual(FillerWordRemover.removeFillers(from: input), "It is pretty good")
    }

    func testRemovesIMeanPhrase() {
        let input = "I mean that is what I meant"
        XCTAssertEqual(FillerWordRemover.removeFillers(from: input), "that is what I meant")
    }

    func testFormatterCapitalizesAfterRemovingIMean() {
        let input = "I mean that is what I meant"
        XCTAssertEqual(
            TranscriptFormatter.format(input, removeFillers: true),
            "That is what I meant"
        )
    }

    func testKeepsContentWords() {
        // "like" as a verb must stay; only pure hesitation sounds are removed.
        let input = "I like pizza and uh love pasta"
        XCTAssertEqual(FillerWordRemover.removeFillers(from: input), "I like pizza and love pasta")
    }

    func testKeepsWordsContainingFillerSubstrings() {
        // "humble" contains "um" but is not a filler token.
        let input = "A humble beginning"
        XCTAssertEqual(FillerWordRemover.removeFillers(from: input), "A humble beginning")
    }

    func testCollapsesWhitespaceAfterRemoval() {
        let input = "Hello   um   world"
        XCTAssertEqual(FillerWordRemover.removeFillers(from: input), "Hello world")
    }

    func testOnlyFillersReturnsEmpty() {
        XCTAssertEqual(FillerWordRemover.removeFillers(from: "um uh umm"), "")
    }

    func testFormatterIntegratesFillerRemoval() {
        let input = "hello um world"
        XCTAssertEqual(
            TranscriptFormatter.format(input, removeFillers: true),
            "Hello world"
        )
    }

    func testFormatterLeavesFillersWhenDisabled() {
        let input = "hello um world"
        XCTAssertEqual(
            TranscriptFormatter.format(input, removeFillers: false),
            "Hello um world"
        )
    }
}
