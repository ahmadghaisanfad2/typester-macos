import Foundation

/// Shared OpenRouter API constants and pure JSON parsing helpers.
public enum OpenRouterAPI {
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    public static let defaultModelID = "openai/whisper-large-v3"
    public static let appReferer = "https://github.com/nickustinov/typester-macos"
    public static let appTitle = "Typester"
    public static let modelsCacheTTL: TimeInterval = 6 * 60 * 60

    public static var modelsURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_modalities", value: "transcription")]
        return components.url!
    }

    public static var transcriptionsURL: URL {
        baseURL.appendingPathComponent("audio/transcriptions")
    }

    public static func parseModels(from data: Data) throws -> [OpenRouterModel] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data
            .filter { !$0.id.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func parseTranscriptText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw OpenRouterError.invalidResponse("Missing transcript text")
        }
        return text
    }

    public static func makeTranscriptionBody(
        model: String,
        wav: Data,
        language: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "input_audio": [
                "data": wav.base64EncodedString(),
                "format": "wav"
            ]
        ]
        if let language, !language.isEmpty {
            body["language"] = language
        }
        return body
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
        }
        return "OpenRouter request failed (\(statusCode))"
    }

    public static func applyAttributionHeaders(to request: inout URLRequest) {
        request.setValue(appReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")
    }

    private struct ModelsResponse: Decodable {
        let data: [OpenRouterModel]
    }
}

public struct OpenRouterModel: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = (decodedName?.isEmpty == false) ? decodedName! : id
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
    }
}

public enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case emptyAudio
    case invalidResponse(String)
    case transient(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not configured"
        case .emptyAudio: return "No audio to transcribe"
        case .invalidResponse(let detail): return detail
        case .transient(let detail): return detail
        case .cancelled: return "Transcription cancelled"
        }
    }
}

/// Fetches and caches OpenRouter transcription models for the settings picker.
@MainActor
public final class OpenRouterModelsStore: ObservableObject {
    public static let shared = OpenRouterModelsStore()

    @Published public private(set) var models: [OpenRouterModel] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastFetchedAt: Date?

    private let modelsCacheKey = "openrouterModelsCache"
    private let modelsFetchedAtKey = "openrouterModelsFetchedAt"
    private let session: URLSession
    private var inFlightTask: Task<Void, Never>?

    public init(session: URLSession = .shared) {
        self.session = session
        loadCache()
    }

    public var isCacheFresh: Bool {
        guard let lastFetchedAt else { return false }
        return Date().timeIntervalSince(lastFetchedAt) < OpenRouterAPI.modelsCacheTTL
    }

    /// Selected model is still valid even if it dropped out of the live list.
    public var pickerModels: [OpenRouterModel] {
        let selectedID = SettingsStore.shared.openrouterModelID
        if models.contains(where: { $0.id == selectedID }) {
            return models
        }
        let stale = OpenRouterModel(id: selectedID, name: "\(selectedID) (unavailable)")
        return [stale] + models
    }

    public func ensureLoaded(force: Bool = false) {
        if !force, isCacheFresh, !models.isEmpty { return }
        if !force, isLoading { return }
        refresh(force: force)
    }

    public func refresh(force: Bool = true) {
        if !force, isCacheFresh, !models.isEmpty { return }
        inFlightTask?.cancel()
        isLoading = true
        lastError = nil
        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: OpenRouterAPI.modelsURL)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                OpenRouterAPI.applyAttributionHeaders(to: &request)

                let (data, response) = try await self.session.data(for: request)
                try Task.checkCancellation()
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code) else {
                    throw OpenRouterError.invalidResponse(
                        OpenRouterAPI.apiErrorMessage(from: data, statusCode: code)
                    )
                }
                let parsed = try OpenRouterAPI.parseModels(from: data)
                self.models = parsed
                self.lastFetchedAt = Date()
                self.lastError = nil
                self.persistCache(data: data, fetchedAt: self.lastFetchedAt!)
            } catch is CancellationError {
                // Ignore cancelled in-flight refresh.
            } catch {
                if self.models.isEmpty {
                    self.lastError = error.localizedDescription
                }
            }
            self.isLoading = false
            self.inFlightTask = nil
        }
    }

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: modelsCacheKey),
           let parsed = try? OpenRouterAPI.parseModels(from: data) {
            models = parsed
        }
        let timestamp = UserDefaults.standard.double(forKey: modelsFetchedAtKey)
        if timestamp > 0 {
            lastFetchedAt = Date(timeIntervalSince1970: timestamp)
        }
    }

    private func persistCache(data: Data, fetchedAt: Date) {
        UserDefaults.standard.set(data, forKey: modelsCacheKey)
        UserDefaults.standard.set(fetchedAt.timeIntervalSince1970, forKey: modelsFetchedAtKey)
    }
}
