import Foundation

/// Detects sustained digital silence on the converted mic path.
///
/// Voice-processing DSP on some Macs delivers all-zero Int16 PCM to the STT
/// tap even though the session “starts successfully.” That surfaces as empty
/// history entries (`Failed · App`) with zero-filled `.pcm` files. Callers
/// observe converted buffers and surface an error once silence is sustained.
public struct CaptureSilenceDetector: Equatable, Sendable {
    /// ~0.5s when the tap emits ~60 Hz chunks.
    public var silentBufferThreshold: Int
    public private(set) var consecutiveSilentBuffers = 0
    public private(set) var didFire = false

    public init(silentBufferThreshold: Int = 30) {
        self.silentBufferThreshold = max(1, silentBufferThreshold)
    }

    public mutating func reset() {
        consecutiveSilentBuffers = 0
        didFire = false
    }

    /// Returns true exactly once when silence has been sustained past the threshold.
    public mutating func observe(pcm16 data: Data) -> Bool {
        if Self.isSilent(pcm16: data) {
            consecutiveSilentBuffers += 1
        } else {
            consecutiveSilentBuffers = 0
            return false
        }
        guard !didFire, consecutiveSilentBuffers >= silentBufferThreshold else { return false }
        didFire = true
        return true
    }

    /// True when every Int16 sample in `data` is zero (or the buffer is empty).
    public static func isSilent(pcm16 data: Data) -> Bool {
        guard data.count >= 2 else { return true }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples where sample != 0 {
                return false
            }
            return true
        }
    }
}
