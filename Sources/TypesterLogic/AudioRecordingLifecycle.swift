public struct AudioRecordingLifecycle: Equatable {
    public enum State: Equatable { case idle, awaitingPermission, starting, recording }

    public private(set) var state: State = .idle
    public init() {}

    public mutating func begin() -> Bool {
        guard state == .idle else { return false }
        state = .awaitingPermission
        return true
    }

    public mutating func resolvePermission(granted: Bool) -> Bool {
        guard state == .awaitingPermission else { return false }
        state = granted ? .starting : .idle
        return true
    }

    public mutating func finishStarting() {
        guard state == .starting else { return }
        state = .recording
    }

    public mutating func failStarting() {
        guard state == .starting else { return }
        state = .idle
    }

    @discardableResult
    public mutating func stop() -> Bool {
        guard state != .idle else { return false }
        state = .idle
        return true
    }

    public var isStarting: Bool { state == .starting }
    public var isRecording: Bool { state == .recording }
}
