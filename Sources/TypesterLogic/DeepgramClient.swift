import Foundation

/// Deepgram STT connection configuration.
public struct DeepgramConnectionConfig: STTConnectionConfig {
    public init() {}
    public var apiKey: String? { SettingsStore.shared.deepgramApiKey }

    /// Query items for the streaming listen endpoint.
    public static func makeQueryItems(
        modelID: String,
        pasteOnPause: Bool,
        focusOnMyVoice: Bool
    ) -> [URLQueryItem] {
        let endpointing = pasteOnPause ? "500" : "false"
        var queryItems = [
            URLQueryItem(name: "model", value: modelID),
            URLQueryItem(name: "language", value: "multi"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: endpointing)
        ]
        if focusOnMyVoice {
            queryItems.append(URLQueryItem(name: "diarize_model", value: "latest"))
        }
        return queryItems
    }

    public func makeWebSocketRequest() -> URLRequest? {
        guard let apiKey = apiKey else { return nil }

        var urlComponents = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        urlComponents.queryItems = Self.makeQueryItems(
            modelID: STTProviderType.deepgram.modelID,
            pasteOnPause: SettingsStore.shared.pasteOnPause,
            focusOnMyVoice: SettingsStore.shared.focusOnMyVoice
        )

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
           let firstAlt = alternatives.first {

            let isFinal = json["is_final"] as? Bool ?? false
            let speechFinal = json["speech_final"] as? Bool ?? false
            let fromFinalize = json["from_finalize"] as? Bool ?? false
            var results: [STTParseResult] = []

            // Prefer word-level speaker labels when diarization is enabled.
            // Without any speaker field, fall back to the channel transcript
            // so smart_format punctuation is preserved.
            if let words = firstAlt["words"] as? [[String: Any]], !words.isEmpty,
               words.contains(where: { $0["speaker"] != nil }) {
                var pendingText = ""
                var pendingSpeaker: String?
                var hasPending = false

                func flushPending() {
                    guard hasPending, !pendingText.isEmpty else { return }
                    results.append(.transcript(text: pendingText, isFinal: isFinal, speaker: pendingSpeaker))
                    pendingText = ""
                    hasPending = false
                }

                for word in words {
                    guard let wordText = word["word"] as? String, !wordText.isEmpty else { continue }
                    let speaker: String?
                    if let speakerInt = word["speaker"] as? Int {
                        speaker = String(speakerInt)
                    } else if let speakerString = word["speaker"] as? String {
                        speaker = speakerString
                    } else {
                        speaker = nil
                    }

                    if hasPending && speaker != pendingSpeaker {
                        flushPending()
                    }
                    if pendingText.isEmpty {
                        pendingText = wordText
                    } else {
                        pendingText += " " + wordText
                    }
                    pendingSpeaker = speaker
                    hasPending = true
                }
                flushPending()

                if !results.isEmpty {
                    Debug.log("Transcript (diarized) isFinal=\(isFinal) speechFinal=\(speechFinal)")
                    if speechFinal {
                        results.append(.endpoint)
                    }
                    if fromFinalize {
                        results.append(.finalizeAcknowledged)
                    }
                    return results
                }
            }

            if let transcript = firstAlt["transcript"] as? String,
               !transcript.isEmpty {
                Debug.log("Transcript: '\(transcript)' isFinal=\(isFinal) speechFinal=\(speechFinal)")
                results.append(.transcript(text: transcript, isFinal: isFinal, speaker: nil))

                if speechFinal {
                    results.append(.endpoint)
                }

                if fromFinalize {
                    results.append(.finalizeAcknowledged)
                }

                return results
            }

            if speechFinal {
                results.append(.endpoint)
            }
            if fromFinalize {
                results.append(.finalizeAcknowledged)
            }
            if !results.isEmpty {
                return results
            }
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
