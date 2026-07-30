import Foundation
import TypesterCore

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("OK: \(message)")
}

// Replacements longest-first
do {
    let pairs = [
        CorrectionPair(wrong: "type", right: "TYPE"),
        CorrectionPair(wrong: "typester", right: "Typester")
    ]
    let result = DictionaryHelpers.applyReplacements("hello typester type", pairs: pairs)
    expect(result == "hello Typester TYPE", "longest-first replacements")
}

// Case-sensitive
do {
    let pairs = [CorrectionPair(wrong: "Typester", right: "TypesterApp")]
    let result = DictionaryHelpers.applyReplacements("typester Typester", pairs: pairs)
    expect(result == "typester TypesterApp", "case-sensitive replacements")
}

// Merge terms
do {
    let pairs = [
        CorrectionPair(wrong: "a", right: "Alpha"),
        CorrectionPair(wrong: "b", right: "Beta"),
        CorrectionPair(wrong: "c", right: "Alpha")
    ]
    let merged = DictionaryHelpers.mergeTerms(manual: ["Beta", "Gamma"], pairs: pairs)
    expect(merged == ["Beta", "Gamma", "Alpha"], "merge terms unique order")
}

// Upsert rejects
expect(DictionaryHelpers.upsertCorrection(wrong: "same", right: "same", into: []) == nil, "reject identical")
expect(DictionaryHelpers.upsertCorrection(wrong: "  ", right: "ok", into: []) == nil, "reject empty")

// Upsert update
do {
    let first = DictionaryHelpers.upsertCorrection(wrong: "teh", right: "the", into: [])!
    let second = DictionaryHelpers.upsertCorrection(wrong: "teh", right: "The", into: first)!
    expect(second.count == 1 && second[0].right == "The", "upsert updates same wrong")
}

// Cap
do {
    var pairs: [CorrectionPair] = []
    for i in 0..<DictionaryHelpers.maxCorrectionPairs {
        pairs = DictionaryHelpers.upsertCorrection(wrong: "w\(i)", right: "r\(i)", into: pairs)!
    }
    pairs = DictionaryHelpers.upsertCorrection(wrong: "newest", right: "Newest", into: pairs)!
    expect(pairs.count == DictionaryHelpers.maxCorrectionPairs, "cap size")
    expect(pairs.contains { $0.wrong == "newest" }, "cap keeps newest")
    expect(!pairs.contains { $0.wrong == "w0" }, "cap drops oldest")
}

// Context
do {
    let context = DictionaryHelpers.buildSonioxContext(
        domain: "Software",
        topic: "Standup",
        terms: ["Typester", "Soniox"]
    )
    expect(context != nil, "context non-nil")
    let general = context?["general"] as? [[String: String]]
    expect(general?.count == 2, "context general count")
    let terms = context?["terms"] as? [String]
    expect(terms == ["Typester", "Soniox"], "context terms")
}

expect(DictionaryHelpers.buildSonioxContext(domain: "  ", topic: "", terms: []) == nil, "empty context nil")

// Soniox error_message parsing
do {
    let config = SonioxConnectionConfig()
    let legacy = config.parseResponse(["error": "Invalid API key"])
    expect(legacy.count == 1, "legacy error count")
    if case .error(let message) = legacy[0] {
        expect(message == "Invalid API key", "legacy error message")
    } else {
        expect(false, "legacy error case")
    }

    let modern = config.parseResponse([
        "tokens": [],
        "error_code": 401,
        "error_type": "unauthenticated",
        "error_message": "Incorrect API key provided."
    ])
    expect(modern.count == 1, "modern error count")
    if case .error(let message) = modern[0] {
        expect(message == "Incorrect API key provided.", "modern error message")
    } else {
        expect(false, "modern error case")
    }
}

print("All smoke checks passed.")
