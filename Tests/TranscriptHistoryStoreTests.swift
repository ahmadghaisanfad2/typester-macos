import XCTest
@testable import TypesterCore

final class TranscriptHistoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: TranscriptHistoryStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typester-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = TranscriptHistoryStore(rootDirectory: tempDir, maxEntries: 10)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        tempDir = nil
    }

    func testAddPersistsEntryAndAudio() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let entry = try store.add(
            text: "hello world",
            status: .succeeded,
            appName: "Notes",
            sampleRate: 16_000,
            audioPCM: pcm
        )

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, entry.id)
        XCTAssertEqual(store.entries[0].text, "hello world")
        XCTAssertEqual(store.entries[0].status, .succeeded)
        XCTAssertEqual(store.entries[0].appName, "Notes")
        XCTAssertEqual(store.entries[0].sampleRate, 16_000)

        let audioURL = try XCTUnwrap(store.audioURL(for: entry))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(try Data(contentsOf: audioURL), pcm)
    }

    func testCapEvictsOldestAndDeletesAudio() throws {
        var ids: [UUID] = []
        for i in 0..<11 {
            let entry = try store.add(
                text: "item \(i)",
                status: .succeeded,
                appName: "App",
                sampleRate: 16_000,
                audioPCM: Data([UInt8(i)])
            )
            ids.append(entry.id)
        }

        XCTAssertEqual(store.entries.count, 10)
        XCTAssertFalse(store.entries.contains { $0.id == ids[0] })
        XCTAssertEqual(store.entries.first?.text, "item 10")
        XCTAssertEqual(store.entries.last?.text, "item 1")

        let evictedPath = tempDir
            .appendingPathComponent("\(ids[0].uuidString).pcm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: evictedPath.path))
    }

    func testUpdateChangesTextAndStatus() throws {
        let entry = try store.add(
            text: "",
            status: .failed,
            appName: "Safari",
            sampleRate: 24_000,
            audioPCM: Data([0xAA])
        )

        var updated = entry
        updated.text = "recovered"
        updated.status = .succeeded
        try store.update(updated)

        XCTAssertEqual(store.entries.first?.text, "recovered")
        XCTAssertEqual(store.entries.first?.status, .succeeded)
    }

    func testClearAllRemovesIndexAndAudio() throws {
        _ = try store.add(
            text: "one",
            status: .succeeded,
            appName: "X",
            sampleRate: 16_000,
            audioPCM: Data([1])
        )
        _ = try store.add(
            text: "",
            status: .failed,
            appName: "Y",
            sampleRate: 16_000,
            audioPCM: Data([2])
        )

        try store.clearAll()

        XCTAssertTrue(store.entries.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(remaining.contains { $0.hasSuffix(".pcm") })
    }

    func testReloadFromDisk() throws {
        _ = try store.add(
            text: "persisted",
            status: .succeeded,
            appName: "Mail",
            sampleRate: 16_000,
            audioPCM: Data([9, 9])
        )

        let reloaded = TranscriptHistoryStore(rootDirectory: tempDir, maxEntries: 10)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].text, "persisted")
        XCTAssertEqual(reloaded.entries[0].appName, "Mail")
    }

    func testHasAudioFalseWhenFileMissing() throws {
        var entry = try store.add(
            text: "gone",
            status: .succeeded,
            appName: "Notes",
            sampleRate: 16_000,
            audioPCM: Data([1])
        )
        let url = try XCTUnwrap(store.audioURL(for: entry))
        try FileManager.default.removeItem(at: url)

        XCTAssertFalse(store.hasAudio(for: entry))
        entry.audioRelativePath = ""
        XCTAssertFalse(store.hasAudio(for: entry))
    }
}

final class TranscriptPastePayloadTests: XCTestCase {
    func testInterimFallbackWhenFinalsEmpty() {
        let accumulated = ""
        let lastInterim = "hello there"
        let payload = TranscriptPastePayload.resolve(
            accumulatedText: accumulated,
            lastInterimText: lastInterim
        )
        XCTAssertEqual(payload, "hello there")
    }

    func testFinalsPreferredOverInterim() {
        let payload = TranscriptPastePayload.resolve(
            accumulatedText: "final words",
            lastInterimText: "partial"
        )
        XCTAssertEqual(payload, "final words")
    }

    func testEmptyWhenBothBlank() {
        let payload = TranscriptPastePayload.resolve(
            accumulatedText: "   ",
            lastInterimText: ""
        )
        XCTAssertNil(payload)
    }
}
