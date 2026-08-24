import XCTest
import ApplicationServices
@testable import TypesterCore

final class AutomaticDictionaryLearningTests: XCTestCase {
    func testDetectsSingleWordCorrection() {
        XCTAssertEqual(
            AutomaticCorrectionDetector.detect(
                original: "Please contact Fad fat tomorrow.",
                corrected: "Please contact Fadfad tomorrow."
            ),
            [DetectedCorrection(wrong: "Fad fat", right: "Fadfad")]
        )
    }

    func testDetectsIndependentCorrections() {
        XCTAssertEqual(
            AutomaticCorrectionDetector.detect(
                original: "Nuha eduk uses super base today",
                corrected: "Nuha Edu uses Supabase today"
            ),
            [
                DetectedCorrection(wrong: "eduk", right: "Edu"),
                DetectedCorrection(wrong: "super base", right: "Supabase")
            ]
        )
    }

    func testRejectsContinuedTypingAndPunctuationOnlyChanges() {
        XCTAssertTrue(
            AutomaticCorrectionDetector.detect(
                original: "Existing transcript",
                corrected: "Existing transcript plus ordinary typing"
            ).isEmpty
        )
        XCTAssertTrue(
            AutomaticCorrectionDetector.detect(
                original: "Hello world",
                corrected: "Hello, world!"
            ).isEmpty
        )
    }

    func testRejectsLargeRewrite() {
        XCTAssertTrue(
            AutomaticCorrectionDetector.detect(
                original: "one two three four five six seven eight nine",
                corrected: "alpha beta gamma delta epsilon zeta eta theta iota"
            ).isEmpty
        )
    }

    func testTrackerKeepsOrdinaryTypingOutsidePastedRangeOutOfCorrection() {
        var tracker = PastedTextTracker(
            originalText: "hello ",
            currentValue: "prefix hello suffix",
            range: NSRange(location: 7, length: 6)
        )

        XCTAssertEqual(tracker.update(to: "prefix hello new suffix"), .irrelevant)
        XCTAssertEqual(tracker.correctedText, "hello ")
    }

    func testTrackerFollowsCorrectionInsidePastedRange() {
        var tracker = PastedTextTracker(
            originalText: "Fad fat ",
            currentValue: "Say Fad fat now",
            range: NSRange(location: 4, length: 8)
        )

        XCTAssertEqual(tracker.update(to: "Say Fadfad now"), .relevant)
        XCTAssertEqual(tracker.correctedText, "Fadfad ")
    }

    func testTrackerShiftsWhenTextBeforePasteChanges() {
        var tracker = PastedTextTracker(
            originalText: "hello ",
            currentValue: "A hello end",
            range: NSRange(location: 2, length: 6)
        )

        XCTAssertEqual(tracker.update(to: "Before A hello end"), .irrelevant)
        XCTAssertEqual(tracker.range.location, 9)
        XCTAssertEqual(tracker.correctedText, "hello ")
    }

    func testTrackerRejectsEditThatCrossesObservedBoundary() {
        var tracker = PastedTextTracker(
            originalText: "hello ",
            currentValue: "prefix hello suffix",
            range: NSRange(location: 7, length: 6)
        )

        XCTAssertEqual(tracker.update(to: "prefix replacement"), .invalid)
    }

    func testSecureFieldsAreExcluded() {
        XCTAssertTrue(
            AccessibilityPasteTarget.isSecureField(
                role: kAXTextFieldRole as String,
                subrole: kAXSecureTextFieldSubrole as String
            )
        )
        XCTAssertFalse(
            AccessibilityPasteTarget.isSecureField(
                role: kAXTextAreaRole as String,
                subrole: nil
            )
        )
    }

    func testAutomaticReplacementUsesWordBoundaries() {
        let pair = CorrectionPair(
            wrong: "he",
            right: "she",
            source: .automatic,
            matchMode: .wordOrPhrase
        )
        XCTAssertEqual(
            DictionaryHelpers.applyReplacements("he said the theme", pairs: [pair]),
            "she said the theme"
        )
    }

    func testLegacyCorrectionDecodesAsTaughtLiteralEntry() throws {
        struct LegacyCorrection: Encodable {
            let id: UUID
            let wrong: String
            let right: String
            let createdAt: Date
        }

        let createdAt = Date(timeIntervalSinceReferenceDate: 123)
        let data = try JSONEncoder().encode(LegacyCorrection(
            id: UUID(),
            wrong: "teh",
            right: "the",
            createdAt: createdAt
        ))
        let decoded = try JSONDecoder().decode(CorrectionPair.self, from: data)

        XCTAssertEqual(decoded.source, .taught)
        XCTAssertEqual(decoded.matchMode, .literal)
        XCTAssertEqual(decoded.observationCount, 1)
        XCTAssertEqual(decoded.lastObservedAt, createdAt)
    }

    func testAutomaticCorrectionCannotOverwriteTaughtCorrection() {
        let taught = CorrectionPair(wrong: "nuha", right: "Nuha Edu")
        XCTAssertNil(DictionaryHelpers.upsertCorrection(
            wrong: "nuha",
            right: "Noha",
            into: [taught],
            source: .automatic,
            matchMode: .wordOrPhrase
        ))
    }
}
