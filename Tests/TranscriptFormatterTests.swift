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
}
