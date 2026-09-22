import Foundation

public enum STTProviderType: String, Codable, CaseIterable {
    case soniox = "soniox"
    case deepgram = "deepgram"
    case openai = "openai"
    case openrouter = "openrouter"
    case xai = "xai"

    public var displayName: String {
        switch self {
        case .soniox: return "Soniox"
        case .deepgram: return "Deepgram"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .xai: return "xAI"
        }
    }

    /// Model ID sent to the provider API (or selected OpenAI / Soniox / OpenRouter model).
    public var modelID: String {
        switch self {
        case .soniox: return SettingsStore.shared.sonioxMode.modelID
        case .deepgram: return "nova-3"
        case .openai: return SettingsStore.shared.openaiModel.rawValue
        case .openrouter: return SettingsStore.shared.openrouterModelID
        case .xai: return SettingsStore.shared.xaiMode.modelID
        }
    }

    /// PCM sample rate expected by the provider.
    public var audioSampleRate: Double {
        switch self {
        case .soniox, .deepgram, .openrouter, .xai: return 16_000
        case .openai: return 24_000
        }
    }

    /// How unpadded transcript deltas from this provider should be joined.
    /// Soniox realtime tokens carry their own spaces — forcing a space between
    /// every token splits words (“Wel com e”). Deepgram diarized runs are
    /// unpadded spans and need a boundary space.
    public var transcriptJoinStyle: TranscriptTokenJoinStyle {
        switch self {
        case .soniox: return .concatenate
        case .deepgram, .openai, .openrouter, .xai: return .spaceBetweenUnpadded
        }
    }

    /// True when the provider buffers audio and returns text only after stop (no live interim).
    public var isBatchTranscription: Bool {
        switch self {
        case .openrouter:
            return true
        case .soniox:
            return SettingsStore.shared.sonioxMode == .async
        case .xai:
            return SettingsStore.shared.xaiMode == .async
        case .deepgram, .openai:
            return false
        }
    }
}

/// Selectable Soniox transcription modes (real-time WebSocket vs async HTTP).
public enum SonioxTranscribeMode: String, Codable, CaseIterable, Identifiable {
    case realtime = "realtime"
    case async = "async"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realtime: return "Real-time"
        case .async: return "Async"
        }
    }

    public var modelID: String {
        switch self {
        case .realtime: return "stt-rt-v5"
        case .async: return "stt-async-v5"
        }
    }
}

/// Selectable xAI transcription modes (real-time WebSocket vs async HTTP).
public enum XaiTranscribeMode: String, Codable, CaseIterable, Identifiable {
    case realtime = "realtime"
    case async = "async"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realtime: return "Real-time"
        case .async: return "Async"
        }
    }

    public var modelID: String { XaiAPI.modelID }
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
