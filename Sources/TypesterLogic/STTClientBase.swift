import Foundation

/// Result of parsing an STT response message.
public enum STTParseResult {
    case transcript(text: String, isFinal: Bool)
    case endpoint
    case finalized
    case error(String)
    case finished
    case none
}

/// Protocol for STT client configuration - each provider implements this.
public protocol STTConnectionConfig {
    var apiKey: String? { get }
    func makeWebSocketRequest() -> URLRequest?
    func parseResponse(_ json: [String: Any]) -> [STTParseResult]
}

/// Base class for speech-to-text WebSocket clients.
/// Handles connection lifecycle, audio buffering, and message routing.
public class STTClientBase: NSObject, STTProvider {
    public override init() { super.init() }
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Keep request handshake snappy, but do not bound the lifetime of a
        // long-lived streaming WebSocket (0 = no resource timeout).
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0
        return URLSession(configuration: config)
    }()

    var webSocketTask: URLSessionWebSocketTask?
    var isConnecting = false
    var audioBuffer: [Data] = []
    var pendingFinalize = false
    var connectStartTime: Date?

    private var isIntentionalDisconnect = false
    private var connectionReady = false
    /// Providers like Soniox re-send all final tokens each message; track what we already emitted.
    private var lastEmittedFinalText = ""

    public var isConnected: Bool { connectionReady }

    // MARK: - Callbacks (STTProvider protocol)

    public var onTranscript: ((String, Bool) -> Void)?
    public var onEndpoint: (() -> Void)?
    public var onFinalized: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: (() -> Void)?

    // MARK: - Abstract hooks (subclasses override)

    /// Returns the connection config for this client.
    func makeConnectionConfig() -> STTConnectionConfig {
        fatalError("Subclass must override makeConnectionConfig()")
    }

    /// Called when WebSocket connection opens. Subclass can send config messages here.
    func onWebSocketOpened() {
        // Default: mark as ready immediately
        markConnectionReady()
    }

    /// Called after sending finalize message. Subclass can delay finalized callback.
    func onFinalizeMessageSent() {
        // Default: no special handling
    }

    /// Returns the finalize message to send (JSON string).
    func finalizeMessage() -> String {
        return "{\"type\":\"finalize\"}"
    }

    // MARK: - Connection (STTProvider protocol)

    public func connect() {
        Debug.log("connect() called, isConnecting=\(isConnecting)")
        guard !isConnecting else {
            Debug.log("connect() SKIPPED - already connecting")
            return
        }

        let config = makeConnectionConfig()
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            Debug.log("connect() FAILED - no API key")
            onError?("API key not configured")
            return
        }

        guard let request = config.makeWebSocketRequest() else {
            Debug.log("connect() FAILED - could not create request")
            onError?("Failed to create connection request")
            return
        }

        disconnect()
        isConnecting = true
        connectionReady = false
        isIntentionalDisconnect = false
        pendingFinalize = false
        lastEmittedFinalText = ""

        Debug.log("Opening WebSocket connection...")
        connectStartTime = Date()
        webSocketTask = Self.session.webSocketTask(with: request)
        webSocketTask?.resume()

        onWebSocketOpened()
        receiveMessage()
    }

    public func disconnect() {
        Debug.log("disconnect() called, buffered chunks: \(audioBuffer.count)")
        isIntentionalDisconnect = true
        isConnecting = false
        pendingFinalize = false
        lastEmittedFinalText = ""
        audioBuffer.removeAll()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionReady = false
    }

    // MARK: - Audio streaming (STTProvider protocol)

    public func sendAudio(_ data: Data) {
        if connectionReady {
            transmitAudio(data)
        } else {
            audioBuffer.append(data)
        }
    }

    /// Sends one audio chunk on the wire. Default: raw binary data frame.
    /// OpenAI overrides this to wrap PCM in base64 JSON events.
    func transmitAudio(_ data: Data) {
        webSocketTask?.send(.data(data)) { _ in }
    }

    public func sendFinalize() {
        Debug.log("sendFinalize() called, isConnected=\(isConnected), buffered=\(audioBuffer.count)")
        if connectionReady {
            sendFinalizeMessage()
        } else if audioBuffer.isEmpty {
            Debug.log("No audio buffered, disconnecting")
            disconnect()
            onFinalized?()
        } else {
            // Connection dropped mid-stream with leftover buffer — don't wait forever.
            Debug.log("Not connected with \(audioBuffer.count) buffered chunks; finalizing locally")
            audioBuffer.removeAll()
            pendingFinalize = false
            onFinalized?()
            disconnect()
        }
    }

    // MARK: - Internal helpers

    /// Marks the connection as ready and flushes buffered audio.
    func markConnectionReady() {
        isConnecting = false
        connectionReady = true

        let elapsed = connectStartTime.map { Date().timeIntervalSince($0) } ?? 0
        Debug.log("Connected in \(String(format: "%.2f", elapsed))s, flushing \(audioBuffer.count) buffered chunks")

        for chunk in audioBuffer {
            transmitAudio(chunk)
        }
        audioBuffer.removeAll()
        onConnected?()

        if pendingFinalize {
            Debug.log("Sending pending finalize")
            pendingFinalize = false
            sendFinalizeMessage()
        }
    }

    /// Sends a message on the WebSocket.
    func sendMessage(_ text: String, completion: ((Error?) -> Void)? = nil) {
        webSocketTask?.send(.string(text)) { error in
            completion?(error)
        }
    }

    private func sendFinalizeMessage() {
        let message = finalizeMessage()
        webSocketTask?.send(.string(message)) { [weak self] _ in
            self?.onFinalizeMessageSent()
        }
    }

    private func receiveMessage() {
        let currentTask = webSocketTask
        currentTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                DispatchQueue.main.async {
                    // Ignore messages from a stale socket
                    guard self.webSocketTask === currentTask else { return }
                    self.handleWebSocketMessage(message)
                }
                self.receiveMessage()

            case .failure(let error):
                DispatchQueue.main.async {
                    // Ignore disconnects from a stale socket that was replaced
                    guard self.webSocketTask === currentTask || self.webSocketTask == nil else { return }
                    if !self.isIntentionalDisconnect {
                        Debug.log("WebSocket receive FAILED: \(error.localizedDescription)")
                    }
                    self.connectionReady = false
                    self.isConnecting = false
                    self.onDisconnected?()
                }
            }
        }
    }

    /// Parses a WebSocket message into JSON and routes STT results.
    func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let str):
            text = str
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }

        guard let text = text,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let config = makeConnectionConfig()
        let results = config.parseResponse(json)
        routeParseResults(results)
    }

    /// Routes parsed STT results to provider callbacks. Subclasses may override.
    func routeParseResults(_ results: [STTParseResult]) {
        // Batch tokens from this response: Soniox re-sends all tokens each
        // response, so we concatenate them into single final/interim callbacks.
        var finalBatch = ""
        var interimBatch = ""
        var otherResults: [STTParseResult] = []

        for result in results {
            switch result {
            case .transcript(let text, let isFinal):
                if isFinal {
                    finalBatch += text
                } else {
                    interimBatch += text
                }
            default:
                otherResults.append(result)
            }
        }

        // Emit batched transcripts before other events (endpoint, finalized, etc.)
        // Soniox re-sends all final tokens each message — only forward the delta.
        if !finalBatch.isEmpty {
            let delta: String
            if finalBatch.hasPrefix(lastEmittedFinalText) {
                delta = String(finalBatch.dropFirst(lastEmittedFinalText.count))
            } else {
                delta = finalBatch
            }
            lastEmittedFinalText = finalBatch
            if !delta.isEmpty {
                onTranscript?(delta, true)
            }
        }
        if !interimBatch.isEmpty {
            onTranscript?(interimBatch, false)
        }

        for result in otherResults {
            switch result {
            case .endpoint:
                onEndpoint?()
            case .finalized:
                onFinalized?()
            case .error(let message):
                onError?(message)
                onDisconnected?()
            case .finished:
                onDisconnected?()
            case .transcript, .none:
                break
            }
        }
    }
}
