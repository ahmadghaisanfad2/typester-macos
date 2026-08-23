import Foundation

/// A small thread-safe PCM buffer shared by the audio callback and the main
/// thread. Audio capture can continue while a provider reconnects or while a
/// finalized transcript is being written to history.
public final class AudioSessionBuffer {
    private let lock = NSLock()
    private var storage = Data()

    public init() {}

    public var isEmpty: Bool {
        lock.withLock { storage.isEmpty }
    }

    public var count: Int {
        lock.withLock { storage.count }
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            storage.append(data)
        }
    }

    public func snapshot() -> Data {
        lock.withLock { storage }
    }

    public func take() -> Data {
        lock.withLock {
            let value = storage
            storage.removeAll(keepingCapacity: false)
            return value
        }
    }

    public func clear() {
        lock.withLock {
            storage.removeAll(keepingCapacity: false)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
