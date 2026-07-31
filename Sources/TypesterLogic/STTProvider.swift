import Foundation

public enum STTProviderType: String, Codable, CaseIterable {
    case soniox = "soniox"
    case deepgram = "deepgram"
    case openai = "openai"

    public var displayName: String {
        switch self {
        case .soniox: return "Soniox"
        case .deepgram: return "Deepgram"
        case .openai: return "OpenAI"
        }
    }

    /// Model ID sent to the provider API (or selected OpenAI model).
    public var modelID: String {
        switch self {
        case .soniox: return "stt-rt-v5"
        case .deepgram: return "nova-3"
        case .openai: return SettingsStore.shared.openaiModel.rawValue
        }
    }

    /// PCM sample rate expected by the provider.
    public var audioSampleRate: Double {
        switch self {
        case .soniox, .deepgram: return 16_000
        case .openai: return 24_000
        }
    }
}

/// Selectable OpenAI Realtime transcription models.
public enum OpenAITranscribeModel: String, Codable, CaseIterable, Identifiable {
    case gptLiveTranscribe = "gpt-live-transcribe"
    case gptTranscribe = "gpt-transcribe"
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gptLiveTranscribe: return "GPT Live Transcribe"
        case .gptTranscribe: return "GPT Transcribe"
        case .gpt4oTranscribe: return "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe: return "GPT-4o Mini Transcribe"
        }
    }

    /// Whether this model supports the live `delay` latency knob.
    public var supportsDelay: Bool {
        self == .gptLiveTranscribe
    }
}

public protocol STTProvider: AnyObject {
    var onTranscript: ((String, Bool) -> Void)? { get set }
    var onEndpoint: (() -> Void)? { get set }
    var onFinalized: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onConnected: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }

    var isConnected: Bool { get }

    func connect()
    func disconnect()
    func sendAudio(_ data: Data)
    func sendFinalize()
}
