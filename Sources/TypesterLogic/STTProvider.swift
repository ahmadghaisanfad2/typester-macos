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

/// Selectable transcript punctuation styles.
///
/// Soniox exposes no punctuation parameter, so a style steers the model with a
/// `context.general` instruction (see `sonioxInstructions`) and is also applied
/// deterministically to the finalized text locally (see `TranscriptFormatter`).
public enum TranscriptStyle: String, Codable, CaseIterable, Identifiable {
    case minimal = "minimal"
    case casual = "casual"
    case neutral = "neutral"
    case formal = "formal"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .casual: return "Casual"
        case .neutral: return "Neutral"
        case .formal: return "Formal"
        }
    }

    public var helpText: String {
        switch self {
        case .minimal: return "No punctuation or capitalization."
        case .casual: return "Sentence periods dropped; question and exclamation marks kept."
        case .neutral: return "Keep the provider's punctuation as-is."
        case .formal: return "Full punctuation, with a sentence-ending period."
        }
    }

    /// Instruction injected into the Soniox `context.general` array. `nil` sends
    /// nothing, leaving the model's default behavior untouched.
    public var sonioxInstructions: String? {
        switch self {
        case .minimal:
            return "Output plain unpunctuated text. Do not add periods, commas, or other punctuation, and do not capitalize words."
        case .casual:
            return "Use minimal punctuation. Avoid periods and commas; only add question marks or exclamation points when clearly needed."
        case .neutral:
            return nil
        case .formal:
            return "Use full, proper punctuation and capitalization, including commas and sentence-ending periods."
        }
    }

    /// Prompt clause for providers that accept a free-form style hint (OpenAI
    /// transcription `prompt`). Neutral keeps the long-standing default wording.
    public var transcriptionPrompt: String {
        switch self {
        case .minimal:
            return "Output plain unpunctuated text. Do not add periods, commas, or other punctuation, and do not capitalize words."
        case .casual:
            return "Use minimal punctuation: avoid periods and commas; only add question marks or exclamation points when clearly needed."
        case .neutral:
            return "Transcribe clearly with proper punctuation, commas, periods, and sentence capitalization."
        case .formal:
            return "Transcribe with full, proper punctuation and capitalization, including commas and sentence-ending periods."
        }
    }

    /// Deepgram streaming punctuation flags. Minimal turns both off so the model
    /// does not add the punctuation this style strips.
    public var deepgramPunctuation: (punctuate: Bool, smartFormat: Bool) {
        self == .minimal ? (false, false) : (true, true)
    }

    /// Whether a provider's inverse text normalization (punctuation, casing,
    /// numbers) should run. Minimal keeps the raw unformatted output.
    public var usesInverseTextNormalization: Bool {
        self != .minimal
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
