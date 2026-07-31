import Foundation

/// Helpers for Soniox async HTTP transcription responses.
public enum SonioxAsyncAPI {
    public static let baseURL = URL(string: "https://api.soniox.com")!

    public static func parseFileID(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw SonioxAsyncError.invalidResponse("Missing file id")
        }
        return id
    }

    public static func parseTranscriptionID(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw SonioxAsyncError.invalidResponse("Missing transcription id")
        }
        return id
    }

    public static func parseTranscriptionStatus(from data: Data) throws -> (status: String, errorMessage: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            throw SonioxAsyncError.invalidResponse("Missing transcription status")
        }
        let message = json["error_message"] as? String
        return (status, message)
    }

    public static func parseTranscriptText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw SonioxAsyncError.invalidResponse("Missing transcript text")
        }
        return text
    }

    public static func apiErrorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["error_message"] as? String, !message.isEmpty {
            return message
        }
        return "Soniox async request failed (\(statusCode))"
    }
}

public enum SonioxAsyncError: LocalizedError {
    case missingAPIKey
    case emptyAudio
    case invalidResponse(String)
    case transcriptionFailed(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not configured"
        case .emptyAudio: return "No audio to transcribe"
        case .invalidResponse(let detail): return detail
        case .transcriptionFailed(let detail): return detail
        case .timeout: return "Soniox async transcription timed out"
        case .cancelled: return "Transcription cancelled"
        }
    }
}

/// Soniox async (batch) speech-to-text client: buffer PCM, upload WAV, poll job.
public final class SonioxAsyncClient: STTProvider {
    public var onTranscript: ((String, Bool) -> Void)?
    public var onEndpoint: (() -> Void)?
    public var onFinalized: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: (() -> Void)?

    public private(set) var isConnected = false

    private var pcmBuffer = Data()
    private var sampleRate: Int = 16_000
    private var session: URLSession
    private var isFinalizing = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    private let pollInterval: TimeInterval = 1.0
    private let pollTimeout: TimeInterval = 180

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect() {
        guard SettingsStore.shared.apiKey != nil else {
            onError?(SonioxAsyncError.missingAPIKey.localizedDescription)
            return
        }
        isCancelled = false
        isFinalizing = false
        pcmBuffer = Data()
        sampleRate = Int(STTProviderType.soniox.audioSampleRate)
        isConnected = true
        onConnected?()
    }

    public func disconnect() {
        isCancelled = true
        isFinalizing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pcmBuffer = Data()
        let wasConnected = isConnected
        isConnected = false
        if wasConnected {
            onDisconnected?()
        }
    }

    public func sendAudio(_ data: Data) {
        guard isConnected, !isFinalizing else { return }
        pcmBuffer.append(data)
    }

    public func sendFinalize() {
        guard isConnected else { return }
        guard !isFinalizing else { return }
        isFinalizing = true

        let pcm = pcmBuffer
        pcmBuffer = Data()
        guard !pcm.isEmpty else {
            finishWithError(SonioxAsyncError.emptyAudio)
            return
        }

        guard let apiKey = SettingsStore.shared.apiKey, !apiKey.isEmpty else {
            finishWithError(SonioxAsyncError.missingAPIKey)
            return
        }

        let wav = PCMWavEncoder.wavData(pcm: pcm, sampleRate: sampleRate)
        Debug.log("Soniox async: uploading \(wav.count) byte WAV")

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fileID = try await self.uploadFile(wav: wav, apiKey: apiKey)
                try self.throwIfCancelled()
                let transcriptionID = try await self.createTranscription(fileID: fileID, apiKey: apiKey)
                try self.throwIfCancelled()
                try await self.pollUntilComplete(transcriptionID: transcriptionID, apiKey: apiKey)
                try self.throwIfCancelled()
                let text = try await self.fetchTranscript(transcriptionID: transcriptionID, apiKey: apiKey)
                self.bestEffortCleanup(transcriptionID: transcriptionID, fileID: fileID, apiKey: apiKey)
                self.finishWithTranscript(text)
            } catch let error as SonioxAsyncError {
                if case .cancelled = error { return }
                self.finishWithError(error)
            } catch is CancellationError {
                return
            } catch {
                if (error as NSError).code == NSURLErrorCancelled { return }
                self.finishWithError(.invalidResponse(error.localizedDescription))
            }
        }
    }

    // MARK: - HTTP

    private func uploadFile(wav: Data, apiKey: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: SonioxAsyncAPI.baseURL.appendingPathComponent("v1/files"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"typester.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await perform(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw SonioxAsyncError.invalidResponse(SonioxAsyncAPI.apiErrorMessage(from: data, statusCode: code))
        }
        return try SonioxAsyncAPI.parseFileID(from: data)
    }

    private func createTranscription(fileID: String, apiKey: String) async throws -> String {
        var body: [String: Any] = [
            "model": SonioxTranscribeMode.async.modelID,
            "file_id": fileID
        ]
        let languageHints = SettingsStore.shared.languageHints
        if !languageHints.isEmpty {
            body["language_hints"] = languageHints
        }
        if let context = SettingsStore.shared.sonioxContext() {
            body["context"] = context
        }

        var request = URLRequest(url: SonioxAsyncAPI.baseURL.appendingPathComponent("v1/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw SonioxAsyncError.invalidResponse(SonioxAsyncAPI.apiErrorMessage(from: data, statusCode: code))
        }
        return try SonioxAsyncAPI.parseTranscriptionID(from: data)
    }

    private func pollUntilComplete(transcriptionID: String, apiKey: String) async throws {
        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            try throwIfCancelled()
            let status = try await fetchStatus(transcriptionID: transcriptionID, apiKey: apiKey)
            switch status.status {
            case "completed":
                return
            case "error":
                throw SonioxAsyncError.transcriptionFailed(status.errorMessage ?? "Transcription failed")
            default:
                try await sleep(pollInterval)
            }
        }
        throw SonioxAsyncError.timeout
    }

    private func fetchStatus(transcriptionID: String, apiKey: String) async throws -> (status: String, errorMessage: String?) {
        var request = URLRequest(
            url: SonioxAsyncAPI.baseURL
                .appendingPathComponent("v1/transcriptions")
                .appendingPathComponent(transcriptionID)
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw SonioxAsyncError.invalidResponse(SonioxAsyncAPI.apiErrorMessage(from: data, statusCode: code))
        }
        return try SonioxAsyncAPI.parseTranscriptionStatus(from: data)
    }

    private func fetchTranscript(transcriptionID: String, apiKey: String) async throws -> String {
        var request = URLRequest(
            url: SonioxAsyncAPI.baseURL
                .appendingPathComponent("v1/transcriptions")
                .appendingPathComponent(transcriptionID)
                .appendingPathComponent("transcript")
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw SonioxAsyncError.invalidResponse(SonioxAsyncAPI.apiErrorMessage(from: data, statusCode: code))
        }
        return try SonioxAsyncAPI.parseTranscriptText(from: data)
    }

    private func bestEffortCleanup(transcriptionID: String, fileID: String, apiKey: String) {
        Task {
            await deleteResource(pathComponents: ["v1", "transcriptions", transcriptionID], apiKey: apiKey)
            await deleteResource(pathComponents: ["v1", "files", fileID], apiKey: apiKey)
        }
    }

    private func deleteResource(pathComponents: [String], apiKey: String) async {
        var url = SonioxAsyncAPI.baseURL
        for component in pathComponents {
            url = url.appendingPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try? await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try throwIfCancelled()
        let (data, response) = try await session.data(for: request)
        try throwIfCancelled()
        return (data, response)
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try throwIfCancelled()
    }

    private func throwIfCancelled() throws {
        if isCancelled { throw SonioxAsyncError.cancelled }
    }

    private func finishWithTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.isFinalizing = false
            if !text.isEmpty {
                self.onTranscript?(text, true)
            }
            self.onFinalized?()
        }
    }

    private func finishWithError(_ error: SonioxAsyncError) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.isFinalizing = false
            self.onError?(error.localizedDescription)
        }
    }
}
