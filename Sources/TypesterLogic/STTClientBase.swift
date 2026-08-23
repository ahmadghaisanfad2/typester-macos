import Foundation

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Result of parsing an STT response message.
public enum STTParseResult {
    case transcript(text: String, isFinal: Bool)
    case endpoint
    /// A provider acknowledged that a finalize request flushed pending audio.
    /// The provider may still need to close its stream after this event.
    case finalizeAcknowledged
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

    private let stateLock = NSLock()
    /// Serializes admission of audio and control operations before they enter
    /// the wire FIFO. This closes the race where finalize could be queued just
    /// before an audio callback that arrived a moment earlier.
    private let admissionQueue = DispatchQueue(label: "com.typester.stt.admission")
    private let sendQueue = DispatchQueue(label: "com.typester.stt.send")
    private var outgoingMessages: [OutgoingMessage] = []
    private var isSendingMessage = false
    private var inFlightMessageID: UUID?
    private var socketGeneration: UInt = 0
    private var admissionGeneration: UInt = 0
    private var isIntentionalDisconnect = false
    private var didNotifyDisconnect = false
    private var connectionReady = false

    private struct OutgoingMessage {
        let id: UUID
        let task: URLSessionWebSocketTask
        let generation: UInt
        let message: URLSessionWebSocketTask.Message
        let completion: ((Error?) -> Void)?
    }

    public var isConnected: Bool {
        stateLock.withLock { connectionReady }
    }

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

    /// Called when a provider confirms that a finalize request flushed pending audio.
    /// Providers such as Deepgram can close the stream here.
    func onFinalizeAcknowledged() {}

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

        let task = Self.session.webSocketTask(with: request)
        let generation = stateLock.withLock { () -> UInt in
            isIntentionalDisconnect = false
            didNotifyDisconnect = false
            isConnecting = true
            connectionReady = false
            pendingFinalize = false
            socketGeneration &+= 1
            webSocketTask = task
            return socketGeneration
        }

        Debug.log("Opening WebSocket connection...")
        connectStartTime = Date()
        task.resume()

        onWebSocketOpened()
        receiveMessage(for: task, generation: generation)
    }

    public func disconnect() {
        let task = stateLock.withLock { () -> URLSessionWebSocketTask? in
            Debug.log("disconnect() called, buffered chunks: \(audioBuffer.count)")
            isIntentionalDisconnect = true
            didNotifyDisconnect = true
            isConnecting = false
            pendingFinalize = false
            connectionReady = false
            audioBuffer.removeAll()
            socketGeneration &+= 1
            admissionGeneration &+= 1
            let oldTask = webSocketTask
            webSocketTask = nil
            return oldTask
        }

        sendQueue.async { [weak self] in
            self?.outgoingMessages.removeAll()
            self?.isSendingMessage = false
            self?.inFlightMessageID = nil
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Audio streaming (STTProvider protocol)

    public func sendAudio(_ data: Data) {
        let generation = stateLock.withLock { admissionGeneration }
        enqueueOrdered { [weak self] in
            guard let self,
                  self.stateLock.withLock({ self.admissionGeneration == generation }) else { return }
            self.sendAudioInOrder(data)
        }
    }

    private func sendAudioInOrder(_ data: Data) {
        let shouldTransmit = stateLock.withLock { () -> Bool in
            guard connectionReady, webSocketTask != nil else {
                audioBuffer.append(data)
                return false
            }
            return true
        }

        if shouldTransmit {
            transmitAudio(data)
        }
    }

    /// Sends one audio chunk on the wire. Default: raw binary data frame.
    /// OpenAI overrides this to wrap PCM in base64 JSON events.
    func transmitAudio(_ data: Data) {
        enqueueMessage(.data(data))
    }

    public func sendFinalize() {
        let generation = stateLock.withLock { admissionGeneration }
        enqueueOrdered { [weak self] in
            guard let self,
                  self.stateLock.withLock({ self.admissionGeneration == generation }) else { return }
            self.sendFinalizeInOrder()
        }
    }

    /// Subclasses with provider-specific finalize handshakes can enqueue their
    /// own operation while preserving the same audio-before-control ordering.
    func enqueueOrdered(_ operation: @escaping () -> Void) {
        admissionQueue.async(execute: operation)
    }

    func sendFinalizeInOrder() {
        let connected = isConnected
        let bufferedCount = stateLock.withLock { audioBuffer.count }
        let hasTask = stateLock.withLock { webSocketTask != nil }
        Debug.log("sendFinalize() called, isConnected=\(connected), buffered=\(bufferedCount)")
        if connected {
            sendFinalizeMessage()
        } else if !hasTask && bufferedCount == 0 {
            Debug.log("No audio buffered, disconnecting")
            disconnect()
            DispatchQueue.main.async { [weak self] in
                self?.onFinalized?()
            }
        } else {
            // Keep finalize behind any buffered audio. This also covers the
            // short handshake window during an automatic reconnect.
            Debug.log("Deferring finalize until connection is ready; buffered=\(bufferedCount)")
            stateLock.withLock { pendingFinalize = true }
        }
    }

    // MARK: - Internal helpers

    /// Marks the connection as ready and flushes buffered audio.
    func markConnectionReady() {
        let buffered: [Data] = stateLock.withLock {
            isConnecting = false
            connectionReady = true
            let chunks = audioBuffer
            audioBuffer.removeAll()
            return chunks
        }

        let elapsed = connectStartTime.map { Date().timeIntervalSince($0) } ?? 0
        Debug.log("Connected in \(String(format: "%.2f", elapsed))s, flushing \(buffered.count) buffered chunks")

        for chunk in buffered {
            transmitAudio(chunk)
        }
        onConnected?()

        let shouldFinalize = stateLock.withLock { () -> Bool in
            guard pendingFinalize else { return false }
            pendingFinalize = false
            return true
        }
        if shouldFinalize {
            Debug.log("Sending pending finalize")
            sendFinalizeMessage()
        }
    }

    /// Sends a message on the WebSocket.
    func sendMessage(_ text: String, completion: ((Error?) -> Void)? = nil) {
        enqueueMessage(.string(text), completion: completion)
    }

    func sendFinalizeMessage() {
        let message = finalizeMessage()
        enqueueMessage(.string(message)) { [weak self] error in
            guard let self = self, error == nil else { return }
            DispatchQueue.main.async {
                self.onFinalizeMessageSent()
            }
        }
    }

    private func enqueueMessage(
        _ message: URLSessionWebSocketTask.Message,
        completion: ((Error?) -> Void)? = nil
    ) {
        let target = stateLock.withLock { (webSocketTask, socketGeneration) }
        guard let task = target.0 else {
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            if let completion {
                DispatchQueue.main.async { completion(error) }
            }
            return
        }

        sendQueue.async { [weak self] in
            guard let self = self else { return }
            self.outgoingMessages.append(
                OutgoingMessage(
                    id: UUID(),
                    task: task,
                    generation: target.1,
                    message: message,
                    completion: completion
                )
            )
            self.drainOutgoingMessages()
        }
    }

    /// All WebSocket writes pass through this serial queue so audio frames and
    /// control messages preserve their order and the finalize barrier is real.
    private func drainOutgoingMessages() {
        dispatchPrecondition(condition: .onQueue(sendQueue))
        guard !isSendingMessage, let next = outgoingMessages.first else { return }

        let currentGeneration = stateLock.withLock { socketGeneration }
        guard next.generation == currentGeneration else {
            outgoingMessages.removeFirst()
            next.completion?(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            drainOutgoingMessages()
            return
        }

        isSendingMessage = true
        inFlightMessageID = next.id
        next.task.send(next.message) { [weak self] error in
            guard let self = self else { return }
            self.sendQueue.async {
                // A disconnect can clear the old queue while its send
                // callback is still in flight. Never let that stale callback
                // consume the first message of a replacement socket.
                guard self.inFlightMessageID == next.id,
                      !self.outgoingMessages.isEmpty,
                      self.outgoingMessages[0].id == next.id else {
                    return
                }

                let sent = self.outgoingMessages.removeFirst()
                self.isSendingMessage = false
                self.inFlightMessageID = nil
                sent.completion?(error)

                let isCurrent = self.stateLock.withLock {
                    sent.generation == self.socketGeneration && !self.isIntentionalDisconnect
                }
                if let error = error, isCurrent {
                    self.handleSendFailure(error)
                }
                self.drainOutgoingMessages()
            }
        }
    }

    private func handleSendFailure(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(sendQueue))
        Debug.log("WebSocket send FAILED: \(error.localizedDescription)")
        let shouldNotify = stateLock.withLock { () -> Bool in
            guard !isIntentionalDisconnect, !didNotifyDisconnect else { return false }
            didNotifyDisconnect = true
            connectionReady = false
            isConnecting = false
            return true
        }
        if shouldNotify {
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnected?()
            }
        }
    }

    private func receiveMessage(
        for currentTask: URLSessionWebSocketTask,
        generation: UInt
    ) {
        currentTask.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                guard self.isCurrentSocket(currentTask, generation: generation) else { return }
                self.receiveMessage(for: currentTask, generation: generation)
                DispatchQueue.main.async {
                    // Ignore messages from a stale socket.
                    guard self.isCurrentSocket(currentTask, generation: generation) else { return }
                    self.handleWebSocketMessage(message)
                }

            case .failure(let error):
                let shouldNotify = self.stateLock.withLock { () -> Bool in
                    guard self.webSocketTask === currentTask,
                          self.socketGeneration == generation,
                          !self.isIntentionalDisconnect,
                          !self.didNotifyDisconnect else { return false }
                    self.connectionReady = false
                    self.isConnecting = false
                    self.didNotifyDisconnect = true
                    return true
                }

                guard shouldNotify else { return }
                DispatchQueue.main.async {
                    Debug.log("WebSocket receive FAILED: \(error.localizedDescription)")
                    self.onDisconnected?()
                }
            }
        }
    }

    private func isCurrentSocket(_ task: URLSessionWebSocketTask, generation: UInt) -> Bool {
        stateLock.withLock {
            webSocketTask === task && socketGeneration == generation
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
        // Batch tokens from one response. Provider final tokens are already
        // deltas; do not apply a global prefix heuristic across messages.
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

        // Emit batched transcripts before other events (endpoint, finalized, etc.).
        if !finalBatch.isEmpty {
            onTranscript?(finalBatch, true)
        }
        if !interimBatch.isEmpty {
            onTranscript?(interimBatch, false)
        }

        for result in otherResults {
            switch result {
            case .endpoint:
                onEndpoint?()
            case .finalizeAcknowledged:
                onFinalizeAcknowledged()
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
