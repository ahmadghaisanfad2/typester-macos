import XCTest
@testable import TypesterCore

final class DictionaryHelpersTests: XCTestCase {

    func testApplyReplacementsLongestFirst() {
        let pairs = [
            CorrectionPair(wrong: "type", right: "TYPE"),
            CorrectionPair(wrong: "typester", right: "Typester")
        ]

        let result = DictionaryHelpers.applyReplacements("hello typester type", pairs: pairs)
        XCTAssertEqual(result, "hello Typester TYPE")
    }

    func testApplyReplacementsCaseSensitive() {
        let pairs = [CorrectionPair(wrong: "Typester", right: "TypesterApp")]
        XCTAssertEqual(
            DictionaryHelpers.applyReplacements("typester Typester", pairs: pairs),
            "typester TypesterApp"
        )
    }

    func testMergeTermsUniquePreservesOrder() {
        let pairs = [
            CorrectionPair(wrong: "a", right: "Alpha"),
            CorrectionPair(wrong: "b", right: "Beta"),
            CorrectionPair(wrong: "c", right: "Alpha")
        ]
        let merged = DictionaryHelpers.mergeTerms(manual: ["Beta", "Gamma"], pairs: pairs)
        XCTAssertEqual(merged, ["Beta", "Gamma", "Alpha"])
    }

    func testUpsertCorrectionRejectsIdentical() {
        XCTAssertNil(
            DictionaryHelpers.upsertCorrection(wrong: "same", right: "same", into: [])
        )
        XCTAssertNil(
            DictionaryHelpers.upsertCorrection(wrong: "  ", right: "ok", into: [])
        )
    }

    func testUpsertCorrectionUpdatesExistingAndCaps() {
        var pairs: [CorrectionPair] = []
        for i in 0..<DictionaryHelpers.maxCorrectionPairs {
            guard let updated = DictionaryHelpers.upsertCorrection(
                wrong: "w\(i)",
                right: "r\(i)",
                into: pairs
            ) else {
                XCTFail("Expected upsert success")
                return
            }
            pairs = updated
        }
        XCTAssertEqual(pairs.count, DictionaryHelpers.maxCorrectionPairs)

        guard let updated = DictionaryHelpers.upsertCorrection(
            wrong: "newest",
            right: "Newest",
            into: pairs
        ) else {
            XCTFail("Expected upsert success")
            return
        }
        XCTAssertEqual(updated.count, DictionaryHelpers.maxCorrectionPairs)
        XCTAssertTrue(updated.contains { $0.wrong == "newest" && $0.right == "Newest" })
        XCTAssertFalse(updated.contains { $0.wrong == "w0" })
    }

    func testUpsertCorrectionUpdatesSameWrong() {
        let first = DictionaryHelpers.upsertCorrection(wrong: "teh", right: "the", into: [])!
        let second = DictionaryHelpers.upsertCorrection(wrong: "teh", right: "The", into: first)!
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].right, "The")
    }

    func testBuildSonioxContextIncludesGeneralAndTerms() {
        let context = DictionaryHelpers.buildSonioxContext(
            domain: "Software",
            topic: "Standup",
            terms: ["Typester", "Soniox"]
        )

        XCTAssertNotNil(context)
        let general = context?["general"] as? [[String: String]]
        XCTAssertEqual(general?.count, 2)
        let terms = context?["terms"] as? [String]
        XCTAssertEqual(terms, ["Typester", "Soniox"])
    }

    func testBuildSonioxContextNilWhenEmpty() {
        XCTAssertNil(DictionaryHelpers.buildSonioxContext(domain: "  ", topic: "", terms: []))
    }

    func testBuildSonioxContextTrimsOversizedTerms() {
        let hugeTerms = (0..<500).map { String(repeating: "t\($0)", count: 40) }
        let context = DictionaryHelpers.buildSonioxContext(
            domain: "Domain",
            topic: "Topic",
            terms: hugeTerms
        )
        XCTAssertNotNil(context)
        guard let data = try? JSONSerialization.data(withJSONObject: context!),
              let string = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to serialize context")
            return
        }
        XCTAssertLessThanOrEqual(string.count, DictionaryHelpers.maxContextCharacters)
        XCTAssertNotNil(context?["general"])
    }
}
