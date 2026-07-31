import Foundation

public enum TranscriptEntryStatus: String, Codable, Equatable {
    case succeeded
    case failed
}

public struct TranscriptEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var status: TranscriptEntryStatus
    public var appName: String
    public var sampleRate: Double
    public var audioRelativePath: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        status: TranscriptEntryStatus,
        appName: String,
        sampleRate: Double,
        audioRelativePath: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.status = status
        self.appName = appName
        self.sampleRate = sampleRate
        self.audioRelativePath = audioRelativePath
    }

    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var menuTitle: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if trimmed.count <= 48 { return trimmed }
            return String(trimmed.prefix(45)) + "…"
        }
        let app = appName.isEmpty ? "Unknown app" : appName
        return "Failed · \(app)"
    }
}

/// Resolves the text that should be pasted after finalize.
public enum TranscriptPastePayload {
    public static func resolve(accumulatedText: String, lastInterimText: String) -> String? {
        let finals = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finals.isEmpty { return finals }
        let interim = lastInterimText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !interim.isEmpty { return interim }
        return nil
    }
}

public final class TranscriptHistoryStore {
    public static let shared = TranscriptHistoryStore()

    public static let defaultMaxEntries = 10

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let maxEntries: Int
    private let indexURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) public var entries: [TranscriptEntry] = []

    /// Directory containing `index.json` and `.pcm` recordings.
    public var directoryURL: URL { rootDirectory }

    public init(
        rootDirectory: URL? = nil,
        maxEntries: Int = TranscriptHistoryStore.defaultMaxEntries,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.maxEntries = max(1, maxEntries)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootDirectory = appSupport
                .appendingPathComponent("Typester", isDirectory: true)
                .appendingPathComponent("history", isDirectory: true)
        }
        self.indexURL = self.rootDirectory.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        load()
    }

    public func audioURL(for entry: TranscriptEntry) -> URL? {
        guard !entry.audioRelativePath.isEmpty else { return nil }
        return rootDirectory.appendingPathComponent(entry.audioRelativePath)
    }

    public func hasAudio(for entry: TranscriptEntry) -> Bool {
        guard let url = audioURL(for: entry) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    @discardableResult
    public func add(
        text: String,
        status: TranscriptEntryStatus,
        appName: String,
        sampleRate: Double,
        audioPCM: Data
    ) throws -> TranscriptEntry {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let id = UUID()
        let relativePath = "\(id.uuidString).pcm"
        let audioURL = rootDirectory.appendingPathComponent(relativePath)
        try audioPCM.write(to: audioURL, options: .atomic)

        let entry = TranscriptEntry(
            id: id,
            text: text,
            status: status,
            appName: appName,
            sampleRate: sampleRate,
            audioRelativePath: relativePath
        )

        entries.insert(entry, at: 0)
        try evictIfNeeded()
        try save()
        return entry
    }

    public func update(_ entry: TranscriptEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        try save()
    }

    public func clearAll() throws {
        for entry in entries {
            if let url = audioURL(for: entry) {
                try? fileManager.removeItem(at: url)
            }
        }
        entries = []
        if fileManager.fileExists(atPath: indexURL.path) {
            try fileManager.removeItem(at: indexURL)
        }
        // Remove any leftover PCM files.
        if let contents = try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "pcm" {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let decoded = try? decoder.decode([TranscriptEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: .atomic)
    }

    private func evictIfNeeded() throws {
        while entries.count > maxEntries {
            let removed = entries.removeLast()
            if let url = audioURL(for: removed) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
