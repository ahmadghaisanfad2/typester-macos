import Foundation

/// OpenAI Realtime transcription connection configuration.
public struct OpenAIConnectionConfig: STTConnectionConfig {
    public init() {}

    public var apiKey: String? { SettingsStore.shared.openaiApiKey }

    public func makeWebSocketRequest() -> URLRequest? {
        guard let apiKey = apiKey else { return nil }

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        // Open a transcription session (not a voice-agent realtime session).
        // Transcription model is set in session.update → audio.input.transcription.model.
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        // GA Realtime WebSocket: Authorization only (no OpenAI-Beta; that selects the retired beta API).
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func parseResponse(_ json: [String: Any]) -> [STTParseResult] {
        guard let type = json["type"] as? String else { return [] }

        switch type {
        case "error":
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String
                    ?? error["code"] as? String
                    ?? "OpenAI error"
                return [.error(message)]
            }
            return [.error("OpenAI error")]

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                return [.transcript(text: delta, isFinal: false)]
            }
            return []

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                return [.transcript(text: transcript, isFinal: true)]
            }
            return []

        default:
            return []
        }
    }

    /// Builds the `session.update` payload for a transcription session.
    public static func makeSessionUpdatePayload(
        model: OpenAITranscribeModel,
        pasteOnPause: Bool,
        languageHints: [String],
        domain: String,
        topic: String,
        keywords: [String]
    ) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": model.rawValue
        ]

        var promptParts = [
            "Transcribe clearly with proper punctuation, commas, periods, and sentence capitalization."
        ]
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDomain.isEmpty {
            promptParts.append("Domain: \(trimmedDomain).")
        }
        if !trimmedTopic.isEmpty {
            promptParts.append("Topic: \(trimmedTopic).")
        }
        transcription["prompt"] = promptParts.joined(separator: " ")

        let cleanKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") }
            .prefix(100)
        if !cleanKeywords.isEmpty {
            transcription["keywords"] = Array(cleanKeywords)
        }

        let languages = languageHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !languages.isEmpty {
            switch model {
            case .gptLiveTranscribe, .gptTranscribe:
                transcription["languages"] = languages
            case .gpt4oTranscribe, .gpt4oMiniTranscribe:
                transcription["language"] = languages[0]
            }
        }

        if model.supportsDelay {
            transcription["delay"] = "medium"
        }

        var input: [String: Any] = [
            "format": [
                "type": "audio/pcm",
                "rate": 24_000
            ],
            "transcription": transcription
        ]

        if pasteOnPause {
            input["turn_detection"] = [
                "type": "server_vad",
                "silence_duration_ms": 500,
                "prefix_padding_ms": 300,
                "threshold": 0.5
            ]
        } else {
            input["turn_detection"] = NSNull()
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": input
                ]
            ]
        ]
    }
}

/// OpenAI Realtime transcription client.
public class OpenAIClient: STTClientBase {
    /// Accumulated interim deltas for the current turn (overlay replaces interim wholesale).
    private var interimAccumulator = ""
    /// True after the user stops; next completed transcript triggers finalize.
    private var awaitingUserFinalize = false
    /// Fallback timer if completed never arrives after commit.
    private var finalizeFallbackWorkItem: DispatchWorkItem?

    public override init() { super.init() }

    override func makeConnectionConfig() -> STTConnectionConfig {
        OpenAIConnectionConfig()
    }

    override func onWebSocketOpened() {
        sendSessionUpdate()
    }

    override func finalizeMessage() -> String {
        "{\"type\":\"input_audio_buffer.commit\"}"
    }

    override func onFinalizeMessageSent() {
        awaitingUserFinalize = true
        finalizeFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.awaitingUserFinalize else { return }
            Debug.log("OpenAI finalize fallback — no completed event")
            self.awaitingUserFinalize = false
            self.onFinalized?()
        }
        finalizeFallbackWorkItem = workItem
        // The normal completion event arrives after the commit has been
        // processed. Keep a generous safety net for a stalled provider, but
        // do not close the session before the transcription event has had a
        // chance to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    override func transmitAudio(_ data: Data) {
        let base64 = data.base64EncodedString()
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        sendMessage(jsonString)
    }

    public override func connect() {
        awaitingUserFinalize = false
        interimAccumulator = ""
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        super.connect()
    }

    public override func disconnect() {
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        awaitingUserFinalize = false
        interimAccumulator = ""
        super.disconnect()
    }

    public override func sendFinalize() {
        enqueueOrdered { [weak self] in
            guard let self else { return }
            Debug.log("OpenAI sendFinalize(), isConnected=\(self.isConnected)")
            if self.isConnected {
                self.sendFinalizeMessage()
            } else {
                self.sendFinalizeInOrder()
            }
        }
    }

    override func routeParseResults(_ results: [STTParseResult]) {
        let pasteOnPause = SettingsStore.shared.pasteOnPause

        for result in results {
            switch result {
            case .transcript(let text, let isFinal):
                if isFinal {
                    interimAccumulator = ""
                    // Ensure space between turns when pasting on pause.
                    var finalText = text
                    if !finalText.hasSuffix(" ") {
                        finalText += " "
                    }
                    onTranscript?(finalText, true)

                    if awaitingUserFinalize {
                        finalizeFallbackWorkItem?.cancel()
                        finalizeFallbackWorkItem = nil
                        awaitingUserFinalize = false
                        onFinalized?()
                    } else if pasteOnPause {
                        onEndpoint?()
                    }
                } else {
                    interimAccumulator += text
                    onTranscript?(interimAccumulator, false)
                }

            case .endpoint:
                onEndpoint?()

            case .finalizeAcknowledged:
                // OpenAI signals completion with the transcription.completed
                // event rather than a separate finalize acknowledgement.
                break

            case .finalized:
                onFinalized?()

            case .error(let message):
                onError?(message)
                onDisconnected?()

            case .finished:
                onDisconnected?()

            case .none:
                break
            }
        }
    }

    private func sendSessionUpdate() {
        let store = SettingsStore.shared
        let payload = OpenAIConnectionConfig.makeSessionUpdatePayload(
            model: store.openaiModel,
            pasteOnPause: store.pasteOnPause,
            languageHints: store.languageHints,
            domain: store.contextDomain,
            topic: store.contextTopic,
            keywords: store.sonioxTerms
        )

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            onError?("Failed to create OpenAI session config")
            return
        }

        Debug.log("Sending OpenAI session.update...")
        sendMessage(jsonString) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    Debug.log("OpenAI session.update FAILED: \(error.localizedDescription)")
                    self.onError?("Failed to configure OpenAI session: \(error.localizedDescription)")
                } else {
                    self.markConnectionReady()
                }
            }
        }
    }
}
