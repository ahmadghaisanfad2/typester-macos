import Foundation

/// Detects sustained digital silence on the converted mic path.
///
/// Voice-processing DSP on some Macs delivers all-zero Int16 PCM to the STT
/// tap even though the session “starts successfully.” That surfaces as empty
/// history entries (`Failed · App`) with zero-filled `.pcm` files. Callers
/// observe converted buffers and surface an error once silence is sustained.
///
/// The threshold is measured in seconds of captured audio, not buffers: voice
/// processing can deliver far larger (and far fewer) buffers than the ~60 Hz
/// tap hint, so a buffer-count threshold can never be reached on those Macs.
public struct CaptureSilenceDetector: Equatable, Sendable {
    /// Seconds of consecutive all-zero PCM before the detector fires.
    public var silentSecondsThreshold: Double
    public private(set) var consecutiveSilentSeconds: Double = 0
    public private(set) var didFire = false

    public init(silentSecondsThreshold: Double = 0.5) {
        self.silentSecondsThreshold = max(0.05, silentSecondsThreshold)
    }

    public mutating func reset() {
        consecutiveSilentSeconds = 0
        didFire = false
    }

    /// Returns true exactly once, when silence has been sustained past the
    /// threshold. `sampleRate` is the rate of `data`, used to turn frames into
    /// seconds so the threshold holds for any buffer size.
    public mutating func observe(pcm16 data: Data, sampleRate: Double) -> Bool {
        if Self.isSilent(pcm16: data) {
            consecutiveSilentSeconds += Double(data.count / 2) / max(sampleRate, 1)
        } else {
            consecutiveSilentSeconds = 0
            return false
        }
        guard !didFire, consecutiveSilentSeconds >= silentSecondsThreshold else { return false }
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
