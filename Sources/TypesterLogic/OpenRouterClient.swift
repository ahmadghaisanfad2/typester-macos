import Foundation

/// OpenRouter batch speech-to-text: buffer PCM, upload WAV, return final transcript.
public final class OpenRouterClient: STTProvider {
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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect() {
        guard SettingsStore.shared.openrouterApiKey != nil else {
            onError?(OpenRouterError.missingAPIKey.localizedDescription)
            return
        }
        stateLock.withLock {
            isCancelled = false
            isFinalizing = false
            connectedState = true
            sessionGeneration &+= 1
            sampleRate = Int(STTProviderType.openrouter.audioSampleRate)
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
            finishWithError(OpenRouterError.emptyAudio, generation: finalizeState.generation)
            return
        }

        guard let apiKey = SettingsStore.shared.openrouterApiKey, !apiKey.isEmpty else {
            finishWithError(OpenRouterError.missingAPIKey, generation: finalizeState.generation)
            return
        }

        let wav = PCMWavEncoder.wavData(pcm: pcm, sampleRate: finalizeState.sampleRate)
        let model = SettingsStore.shared.openrouterModelID
        let language = SettingsStore.shared.languageHints.first
        Debug.log("OpenRouter: uploading \(wav.count) byte WAV as \(model)")

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcribeWithRetry(
                    wav: wav,
                    apiKey: apiKey,
                    model: model,
                    language: language,
                    generation: finalizeState.generation
                )
                self.finishWithTranscript(text, generation: finalizeState.generation)
            } catch let error as OpenRouterError {
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

    private func transcribeWithRetry(
        wav: Data,
        apiKey: String,
        model: String,
        language: String?,
        generation: UInt
    ) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await transcribeOnce(
                    wav: wav,
                    apiKey: apiKey,
                    model: model,
                    language: language,
                    generation: generation
                )
            } catch {
                try throwIfCancelled(for: generation)
                guard attempt == 0, isTransient(error) else { throw error }
                attempt += 1
                Debug.log("OpenRouter transient failure; retrying once")
                try await sleep(0.35, generation: generation)
            }
        }
    }

    private func transcribeOnce(
        wav: Data,
        apiKey: String,
        model: String,
        language: String?,
        generation: UInt
    ) async throws -> String {
        try throwIfCancelled(for: generation)

        var request = URLRequest(url: OpenRouterAPI.transcriptionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        OpenRouterAPI.applyAttributionHeaders(to: &request)
        let body = OpenRouterAPI.makeTranscriptionBody(model: model, wav: wav, language: language)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        try throwIfCancelled(for: generation)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw makeHTTPError(data: data, statusCode: code)
        }
        return try OpenRouterAPI.parseTranscriptText(from: data)
    }

    private func makeHTTPError(data: Data, statusCode: Int) -> OpenRouterError {
        let message = OpenRouterAPI.apiErrorMessage(from: data, statusCode: statusCode)
        if statusCode == 429 || (500...599).contains(statusCode) {
            return .transient(message)
        }
        return .invalidResponse(message)
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
        if shouldCancel { throw OpenRouterError.cancelled }
    }

    private func isTransient(_ error: Error) -> Bool {
        if let openRouterError = error as? OpenRouterError {
            switch openRouterError {
            case .transient:
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

    private func finishWithError(_ error: OpenRouterError, generation: UInt) {
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
