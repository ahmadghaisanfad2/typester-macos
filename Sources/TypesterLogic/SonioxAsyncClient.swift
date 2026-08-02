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
    case transient(String)
    case transcriptionFailed(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not configured"
        case .emptyAudio: return "No audio to transcribe"
        case .invalidResponse(let detail): return detail
        case .transient(let detail): return detail
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

    private let stateLock = NSLock()
    private var connectedState = false
    private var sessionGeneration: UInt = 0
    public var isConnected: Bool {
        stateLock.withLock { connectedState }
    }

    private let pcmBuffer = AudioSessionBuffer()
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
        stateLock.withLock {
            isCancelled = false
            isFinalizing = false
            connectedState = true
            sessionGeneration &+= 1
            sampleRate = Int(STTProviderType.soniox.audioSampleRate)
        }
        pcmBuffer.clear()
        onConnected?()
    }

    public func disconnect() {
        let wasConnected = stateLock.withLock { () -> Bool in
            let wasConnected = connectedState
            isCancelled = true
            isFinalizing = false
            connectedState = false
            sessionGeneration &+= 1
            return wasConnected
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pcmBuffer.clear()
        if wasConnected {
            onDisconnected?()
        }
    }

    public func sendAudio(_ data: Data) {
        let canBuffer = stateLock.withLock { connectedState && !isFinalizing }
        guard canBuffer else { return }
        pcmBuffer.append(data)
    }

    public func sendFinalize() {
        let finalizeState = stateLock.withLock { () -> (isConnected: Bool, shouldFinalize: Bool, sampleRate: Int, generation: UInt) in
            guard connectedState else { return (false, false, sampleRate, sessionGeneration) }
            guard !isFinalizing else { return (true, false, sampleRate, sessionGeneration) }
            isFinalizing = true
            return (true, true, sampleRate, sessionGeneration)
        }
        guard finalizeState.isConnected, finalizeState.shouldFinalize else { return }

        let pcm = pcmBuffer.take()
        guard !pcm.isEmpty else {
            finishWithError(SonioxAsyncError.emptyAudio, generation: finalizeState.generation)
            return
        }

        guard let apiKey = SettingsStore.shared.apiKey, !apiKey.isEmpty else {
            finishWithError(SonioxAsyncError.missingAPIKey, generation: finalizeState.generation)
            return
        }

        let wav = PCMWavEncoder.wavData(pcm: pcm, sampleRate: finalizeState.sampleRate)
        Debug.log("Soniox async: uploading \(wav.count) byte WAV")

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcribeWithRetry(
                    wav: wav,
                    apiKey: apiKey,
                    generation: finalizeState.generation
                )
                self.finishWithTranscript(text, generation: finalizeState.generation)
            } catch let error as SonioxAsyncError {
                if case .cancelled = error { return }
                self.finishWithError(error, generation: finalizeState.generation)
            } catch is CancellationError {
                return
            } catch {
                if (error as NSError).code == NSURLErrorCancelled { return }
                self.finishWithError(.invalidResponse(error.localizedDescription), generation: finalizeState.generation)
            }
        }
    }

    private func transcribeWithRetry(wav: Data, apiKey: String, generation: UInt) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await transcribeOnce(wav: wav, apiKey: apiKey, generation: generation)
            } catch {
                try throwIfCancelled(for: generation)
                guard attempt == 0, isTransient(error) else { throw error }
                attempt += 1
                Debug.log("Soniox async transient failure; retrying once")
                try await sleep(0.35, generation: generation)
            }
        }
    }

    private func transcribeOnce(wav: Data, apiKey: String, generation: UInt) async throws -> String {
        let fileID = try await uploadFile(wav: wav, apiKey: apiKey)
        do {
            try throwIfCancelled(for: generation)
            let transcriptionID = try await createTranscription(fileID: fileID, apiKey: apiKey)
            try throwIfCancelled(for: generation)
            try await pollUntilComplete(
                transcriptionID: transcriptionID,
                apiKey: apiKey,
                generation: generation
            )
            try throwIfCancelled(for: generation)
            let text = try await fetchTranscript(transcriptionID: transcriptionID, apiKey: apiKey)
            try throwIfCancelled(for: generation)
            bestEffortCleanup(transcriptionID: transcriptionID, fileID: fileID, apiKey: apiKey)
            return text
        } catch {
            bestEffortDeleteFile(fileID: fileID, apiKey: apiKey)
            throw error
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
            throw makeHTTPError(data: data, statusCode: code)
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
            throw makeHTTPError(data: data, statusCode: code)
        }
        return try SonioxAsyncAPI.parseTranscriptionID(from: data)
    }

    private func pollUntilComplete(transcriptionID: String, apiKey: String, generation: UInt) async throws {
        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            try throwIfCancelled(for: generation)
            let status = try await fetchStatus(transcriptionID: transcriptionID, apiKey: apiKey)
            try throwIfCancelled(for: generation)
            switch status.status {
            case "completed":
                return
            case "error":
                throw SonioxAsyncError.transcriptionFailed(status.errorMessage ?? "Transcription failed")
            default:
                try await sleep(pollInterval, generation: generation)
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
            throw makeHTTPError(data: data, statusCode: code)
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
            throw makeHTTPError(data: data, statusCode: code)
        }
        return try SonioxAsyncAPI.parseTranscriptText(from: data)
    }

    private func makeHTTPError(data: Data, statusCode: Int) -> SonioxAsyncError {
        let message = SonioxAsyncAPI.apiErrorMessage(from: data, statusCode: statusCode)
        if statusCode == 429 || (500...599).contains(statusCode) {
            return .transient(message)
        }
        return .invalidResponse(message)
    }

    private func bestEffortCleanup(transcriptionID: String, fileID: String, apiKey: String) {
        Task {
            await deleteResource(pathComponents: ["v1", "transcriptions", transcriptionID], apiKey: apiKey)
            await deleteResource(pathComponents: ["v1", "files", fileID], apiKey: apiKey)
        }
    }

    private func bestEffortDeleteFile(fileID: String, apiKey: String) {
        Task {
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

    private func sleep(_ seconds: TimeInterval, generation: UInt? = nil) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try throwIfCancelled(for: generation)
    }

    private func throwIfCancelled(for generation: UInt? = nil) throws {
        let shouldCancel = stateLock.withLock {
            isCancelled || (generation.map { $0 != sessionGeneration } ?? false)
        }
        if shouldCancel { throw SonioxAsyncError.cancelled }
    }

    private func isTransient(_ error: Error) -> Bool {
        if let asyncError = error as? SonioxAsyncError {
            switch asyncError {
            case .transient, .timeout:
                return true
            default:
                return false
            }
        }

        let code = (error as NSError).code
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable
        ].contains(code)
    }

    private func finishWithTranscript(_ text: String, generation: UInt) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSession(generation) else { return }
            self.stateLock.withLock { self.isFinalizing = false }
            if !text.isEmpty {
                self.onTranscript?(text, true)
            }
            self.onFinalized?()
        }
    }

    private func finishWithError(_ error: SonioxAsyncError, generation: UInt) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSession(generation) else { return }
            self.stateLock.withLock { self.isFinalizing = false }
            self.onError?(error.localizedDescription)
        }
    }

    private func isCurrentSession(_ generation: UInt) -> Bool {
        stateLock.withLock {
            sessionGeneration == generation && !isCancelled
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
