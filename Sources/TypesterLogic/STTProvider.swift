import Foundation

public enum STTProviderType: String, Codable, CaseIterable {
    case soniox = "soniox"
    case deepgram = "deepgram"

    public var displayName: String {
        switch self {
        case .soniox: return "Soniox"
        case .deepgram: return "Deepgram"
        }
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
