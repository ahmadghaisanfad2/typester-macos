import Foundation

/// Soniox STT connection configuration.
public struct SonioxConnectionConfig: STTConnectionConfig {
    public init() {}
    public var apiKey: String? { SettingsStore.shared.apiKey }

    public func makeWebSocketRequest() -> URLRequest? {
        let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
        return URLRequest(url: url)
    }

    public func parseResponse(_ json: [String: Any]) -> [STTParseResult] {
        var results: [STTParseResult] = []

        // Legacy error shape
        if let error = json["error"] as? String {
            return [.error(error)]
        }

        // Current Soniox API error shape
        if let errorMessage = json["error_message"] as? String {
            return [.error(errorMessage)]
        }

        if let tokens = json["tokens"] as? [[String: Any]] {
            for token in tokens {
                guard let tokenText = token["text"] as? String else { continue }

                if tokenText == "<end>" {
                    results.append(.endpoint)
                    continue
                }

                if tokenText == "<fin>" {
                    results.append(.finalized)
                    continue
                }

                let isFinal = token["is_final"] as? Bool ?? false
                results.append(.transcript(text: tokenText, isFinal: isFinal))
            }
        }

        if let finished = json["finished"] as? Bool, finished {
            results.append(.finished)
        }

        return results
    }
}

/// Soniox speech-to-text client.
public class SonioxClient: STTClientBase {
    public override init() { super.init() }
    override func makeConnectionConfig() -> STTConnectionConfig {
        SonioxConnectionConfig()
    }

    override func onWebSocketOpened() {
        sendConfiguration()
    }

    override func finalizeMessage() -> String {
        return "{\"type\":\"finalize\"}"
    }

    private func sendConfiguration() {
        guard let apiKey = SettingsStore.shared.apiKey else { return }

        // Always enable endpoint detection so Soniox punctuates on pauses.
        // Paste-on-pause is handled in AppDelegate's onEndpoint — enabling detection
        // here does not paste by itself.
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": STTProviderType.soniox.modelID,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
            // Prefer fewer false endpoints so brief breaths don't split sentences.
            "endpoint_sensitivity": -0.3,
            "max_endpoint_delay_ms": 2500
        ]

        let languageHints = SettingsStore.shared.languageHints
        if !languageHints.isEmpty {
            config["language_hints"] = languageHints
        }

        if let context = SettingsStore.shared.sonioxContext() {
            config["context"] = context
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            onError?("Failed to create config")
            return
        }

        Debug.log("Sending config to Soniox...")
        sendMessage(jsonString) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    Debug.log("Config send FAILED: \(error.localizedDescription)")
                    // Suppress timeout/cancellation errors - just disconnect silently
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain &&
                       (nsError.code == NSURLErrorTimedOut ||
                        nsError.code == NSURLErrorCancelled ||
                        nsError.code == NSURLErrorNetworkConnectionLost) {
                        self.onDisconnected?()
                    } else {
                        self.onError?("Failed to send config: \(error.localizedDescription)")
                    }
                } else {
                    self.markConnectionReady()
                }
            }
        }
    }
}
