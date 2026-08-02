import Foundation

/// Deepgram STT connection configuration.
public struct DeepgramConnectionConfig: STTConnectionConfig {
    public init() {}
    public var apiKey: String? { SettingsStore.shared.deepgramApiKey }

    public func makeWebSocketRequest() -> URLRequest? {
        guard let apiKey = apiKey else { return nil }

        var urlComponents = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        // Disable silence endpointing unless paste-on-pause is enabled (was 100ms — very choppy).
        let endpointing = SettingsStore.shared.pasteOnPause ? "500" : "false"
        urlComponents.queryItems = [
            URLQueryItem(name: "model", value: STTProviderType.deepgram.modelID),
            URLQueryItem(name: "language", value: "multi"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: endpointing)
        ]

        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func parseResponse(_ json: [String: Any]) -> [STTParseResult] {
        // Check for error response
        if let error = json["error"] as? String {
            return [.error(error)]
        }

        // Check for error in err_code/err_msg format
        if let errCode = json["err_code"] as? String {
            let errMsg = json["err_msg"] as? String ?? errCode
            return [.error(errMsg)]
        }

        // Parse transcript
        if let channel = json["channel"] as? [String: Any],
           let alternatives = channel["alternatives"] as? [[String: Any]],
           let firstAlt = alternatives.first,
           let transcript = firstAlt["transcript"] as? String,
           !transcript.isEmpty {

            var results: [STTParseResult] = []

            let isFinal = json["is_final"] as? Bool ?? false
            let speechFinal = json["speech_final"] as? Bool ?? false
            let fromFinalize = json["from_finalize"] as? Bool ?? false

            Debug.log("Transcript: '\(transcript)' isFinal=\(isFinal) speechFinal=\(speechFinal)")

            results.append(.transcript(text: transcript, isFinal: isFinal))

            if speechFinal {
                results.append(.endpoint)
            }

            if fromFinalize {
                results.append(.finalizeAcknowledged)
            }

            return results
        }

        // Deepgram may acknowledge Finalize in a result without a transcript.
        if json["from_finalize"] as? Bool == true {
            return [.finalizeAcknowledged]
        }

        return []
    }
}

/// Deepgram speech-to-text client.
public class DeepgramClient: STTClientBase {
    private var finalizeWatchdog: DispatchWorkItem?
    private var awaitingFinalizeAcknowledgement = false
    private var receivedFinalizeAcknowledgement = false
    private var didCompleteFinalize = false

    public override init() { super.init() }
    override func makeConnectionConfig() -> STTConnectionConfig {
        DeepgramConnectionConfig()
    }

    override func onWebSocketOpened() {
        // Deepgram is ready after brief WebSocket handshake delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isConnecting else { return }
            self.markConnectionReady()
        }
    }

    public override func connect() {
        finalizeWatchdog?.cancel()
        finalizeWatchdog = nil
        awaitingFinalizeAcknowledgement = false
        receivedFinalizeAcknowledgement = false
        didCompleteFinalize = false
        super.connect()
    }

    public override func disconnect() {
        finalizeWatchdog?.cancel()
        finalizeWatchdog = nil
        awaitingFinalizeAcknowledgement = false
        receivedFinalizeAcknowledgement = false
        didCompleteFinalize = false
        super.disconnect()
    }

    override func finalizeMessage() -> String {
        return "{\"type\":\"Finalize\"}"
    }

    override func onFinalizeMessageSent() {
        // Finalize flushes audio that is still being processed. Wait for the
        // provider's from_finalize result before closing the stream.
        awaitingFinalizeAcknowledgement = true
        if receivedFinalizeAcknowledgement {
            receivedFinalizeAcknowledgement = false
            closeStreamAndFinish()
            return
        }
        finalizeWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingFinalizeAcknowledgement else { return }
            Debug.log("Deepgram Finalize acknowledgement timed out; closing stream")
            self.closeStreamAndFinish()
        }
        finalizeWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    override func onFinalizeAcknowledged() {
        receivedFinalizeAcknowledgement = true
        guard awaitingFinalizeAcknowledgement else { return }
        receivedFinalizeAcknowledgement = false
        finalizeWatchdog?.cancel()
        finalizeWatchdog = nil
        awaitingFinalizeAcknowledgement = false
        closeStreamAndFinish()
    }

    private func closeStreamAndFinish() {
        guard !didCompleteFinalize else { return }
        sendMessage("{\"type\":\"CloseStream\"}") { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.didCompleteFinalize else { return }
                if let error {
                    self.didCompleteFinalize = true
                    self.onError?("Deepgram stream close failed: \(error.localizedDescription)")
                    return
                }
                self.didCompleteFinalize = true
                self.onFinalized?()
            }
        }
    }
}
