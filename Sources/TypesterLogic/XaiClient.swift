import Foundation

/// Shared xAI (Grok) speech-to-text constants and pure request/response helpers.
public enum XaiAPI {
    public static let baseURL = URL(string: "https://api.x.ai")!
    public static let webSocketURL = "wss://api.x.ai/v1/stt"
    /// Server default model. The WebSocket route takes no model parameter.
    public static let modelID = "grok-voice-transcribe-2"
    public static let sampleRate = 16_000
    public static let keytermLimit = 100
    public static let keytermMaxLength = 50

    public static var transcriptionsURL: URL {
        baseURL.appendingPathComponent("v1/stt")
    }

    /// Query items for the streaming endpoint (configuration is URL-only for xAI).
    public static func makeQueryItems(
        language: String?,
        focusOnMyVoice: Bool,
        keyterms: [String]
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true")
        ]
        if let language, !language.isEmpty {
            items.append(URLQueryItem(name: "language", value: language))
        }
        if focusOnMyVoice {
            items.append(URLQueryItem(name: "diarize", value: "true"))
        }
        for term in sanitizedKeyterms(keyterms) {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        return items
    }

    /// Trims, de-duplicates, and caps key terms to what the API accepts.
    public static func sanitizedKeyterms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= keytermMaxLength else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == keytermLimit { break }
        }
        return result
    }

    /// Multipart body for the batch endpoint. The `file` field must be last.
    public static func makeMultipartBody(
        boundary: String,
        model: String,
        language: String?,
        keyterms: [String],
        wav: Data
    ) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("model", model)
        if let language, !language.isEmpty {
            appendField("language", language)
            // Inverse text normalization needs a language to format against.
            appendField("format", "true")
        }
        for term in sanitizedKeyterms(keyterms) {
            appendField("keyterm", term)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"typester.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    public static func parseRestText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw XaiAsyncError.invalidResponse("Missing transcript text")
        }
        return text
    }

    public static func apiErrorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
        }
        return "xAI request failed (\(statusCode))"
    }
}

/// xAI streaming connection configuration.
public struct XaiConnectionConfig: STTConnectionConfig {
    public init() {}
    public var apiKey: String? { SettingsStore.shared.xaiApiKey }

    public func makeWebSocketRequest() -> URLRequest? {
        guard let apiKey, !apiKey.isEmpty else { return nil }

        var components = URLComponents(string: XaiAPI.webSocketURL)!
        components.queryItems = XaiAPI.makeQueryItems(
            language: SettingsStore.shared.languageHints.first,
            focusOnMyVoice: SettingsStore.shared.focusOnMyVoice,
            keyterms: SettingsStore.shared.providerKeyterms
        )
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func parseResponse(_ json: [String: Any]) -> [STTParseResult] {
        switch json["type"] as? String {
        case "transcript.partial":
            let isFinal = json["is_final"] as? Bool ?? false
            let speechFinal = json["speech_final"] as? Bool ?? false
            var results = transcripts(from: json, isFinal: isFinal)
            if speechFinal {
                results.append(.endpoint)
            }
            return results
        case "transcript.done":
            var results = transcripts(from: json, isFinal: true)
            results.append(.finalized)
            return results
        case "error":
            let message = json["message"] as? String ?? "xAI transcription error"
            return [.error(message)]
        default:
            return []
        }
    }

    /// Turns a transcript event into results, splitting per-speaker runs when
    /// diarization supplies word labels so the speaker filter can drop them.
    private func transcripts(from json: [String: Any], isFinal: Bool) -> [STTParseResult] {
        if let words = json["words"] as? [[String: Any]], !words.isEmpty,
           words.contains(where: { $0["speaker"] != nil }) {
            var results: [STTParseResult] = []
            var pendingText = ""
            var pendingSpeaker: String?

            func flush() {
                guard !pendingText.isEmpty else { return }
                results.append(.transcript(text: pendingText, isFinal: isFinal, speaker: pendingSpeaker))
                pendingText = ""
            }

            for word in words {
                guard let wordText = word["text"] as? String, !wordText.isEmpty else { continue }
                let speaker: String?
                if let value = word["speaker"] as? Int {
                    speaker = String(value)
                } else if let value = word["speaker"] as? String {
                    speaker = value
                } else {
                    speaker = nil
                }
                if !pendingText.isEmpty, speaker != pendingSpeaker {
                    flush()
                }
                pendingText = pendingText.isEmpty ? wordText : pendingText + " " + wordText
                pendingSpeaker = speaker
            }
            flush()

            if !results.isEmpty { return results }
        }

        if let text = json["text"] as? String, !text.isEmpty {
            return [.transcript(text: text, isFinal: isFinal)]
        }
        return []
    }
}

/// xAI streaming speech-to-text client (raw PCM over WebSocket).
public class XaiClient: STTClientBase {
    private var createdFallbackWorkItem: DispatchWorkItem?
    private var finalizeWatchdog: DispatchWorkItem?
    private var didEmitFinalText = false

    public override init() { super.init() }

    override func makeConnectionConfig() -> STTConnectionConfig {
        XaiConnectionConfig()
    }

    public override func connect() {
        didEmitFinalText = false
        cancelTimers()
        super.connect()
    }

    public override func disconnect() {
        cancelTimers()
        super.disconnect()
    }

    override func onWebSocketOpened() {
        // xAI wants `transcript.created` before audio; fall back if it never comes.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isConnecting else { return }
            Debug.log("xAI transcript.created not received; marking connection ready")
            self.markConnectionReady()
        }
        createdFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    override func finalizeMessage() -> String {
        return "{\"type\":\"audio.done\"}"
    }

    override func onFinalizeMessageSent() {
        // The server flushes on `audio.done` and closes after `transcript.done`.
        // Guard against a silent stream so stopping always resolves.
        finalizeWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Debug.log("xAI transcript.done timed out; finalizing")
            self.onFinalized?()
            self.disconnect()
        }
        finalizeWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    override func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        guard let json = Self.decodeJSON(message), json["type"] as? String == "transcript.created" else {
            super.handleWebSocketMessage(message)
            return
        }
        createdFallbackWorkItem?.cancel()
        createdFallbackWorkItem = nil
        markConnectionReady()
    }

    override func routeParseResults(_ results: [STTParseResult]) {
        var containsFinalized = false
        for result in results {
            if case .finalized = result { containsFinalized = true; break }
        }

        guard containsFinalized else {
            for result in results {
                if case .transcript(let text, true, _) = result, !text.isEmpty {
                    didEmitFinalText = true
                }
            }
            super.routeParseResults(results)
            return
        }

        // `transcript.done` repeats the utterance. Drop its text when final chunk
        // text was already streamed so the transcript is not doubled.
        finalizeWatchdog?.cancel()
        finalizeWatchdog = nil
        let routed = results.filter { result in
            if case .transcript(_, true, _) = result, didEmitFinalText { return false }
            return true
        }
        super.routeParseResults(routed)
    }

    private func cancelTimers() {
        createdFallbackWorkItem?.cancel()
        createdFallbackWorkItem = nil
        finalizeWatchdog?.cancel()
        finalizeWatchdog = nil
    }

    private static func decodeJSON(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            data = nil
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
