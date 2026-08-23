import Accelerate
import Foundation

/// Real-FFT speech-band analyzer behind the HUD waveform.
///
/// Samples arrive on the audio tap thread via `appendSamples`; `bandLevels`
/// turns the newest window into log-spaced 0...1 magnitudes with per-band
/// attack/release smoothing. Both calls must run on one thread (the tap).
public final class SpectrumAnalyzer {
    /// Number of waveform bands exposed to the HUD.
    public let bandCount: Int

    private let fftSize: Int
    private let window: [Float]
    private var history: [Float]
    private var historyLength = 0
    private var historyHead = 0

    private let dft: vDSP.DiscreteFourierTransform<Float>?
    private var scratchIn: [Float]
    private var scratchImaginary: [Float]
    private var magnitudes: [Float]
    private var binRanges: [Range<Int>] = []
    private var smoothed: [Float]
    private var cachedSampleRate: Float = 0

    /// Log-spaced speech band edges; bass bars track vowels, top bars sibilance.
    private static let lowestHz: Float = 140
    private static let highestHz: Float = 7_600
    private static let noiseFloorDB: Float = -66
    private static let ceilingDB: Float = -14
    private static let attack: Float = 0.65
    private static let release: Float = 0.4

    public init(bandCount: Int = 9, fftSize: Int = 512) {
        self.bandCount = bandCount
        self.fftSize = fftSize
        self.window = (0..<fftSize).map { 0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(fftSize)) }
        self.history = [Float](repeating: 0, count: fftSize)
        self.scratchIn = [Float](repeating: 0, count: fftSize)
        self.scratchImaginary = [Float](repeating: 0, count: fftSize)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        self.smoothed = [Float](repeating: 0, count: bandCount)
        // macOS 26 SDK dropped the real-complex DFT wrapper; a complex-complex
        // transform over zero-imaginary input gives the identical spectrum.
        self.dft = try? vDSP.DiscreteFourierTransform(
            count: fftSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
    }

    /// Drop history and smoothing so a new session does not inherit stale motion.
    public func reset() {
        historyLength = 0
        historyHead = 0
        for i in 0..<bandCount { smoothed[i] = 0 }
    }

    /// Copy the newest tap samples into the ring buffer.
    public func appendSamples(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var remaining = count
        var src = 0
        // Keep only the last fftSize samples when the tap delivers more.
        if count >= fftSize {
            src = count - fftSize
            remaining = fftSize
        }
        for _ in 0..<remaining {
            history[historyHead] = samples[src]
            historyHead = (historyHead + 1) % fftSize
            if historyLength < fftSize { historyLength += 1 }
            src += 1
        }
    }

    /// Smoothed per-band levels in 0...1, oldest-to-newest window, `bandCount` values.
    public func bandLevels(sampleRate: Float) -> [Float] {
        rebuildBinRangesIfNeeded(sampleRate: sampleRate)

        if let dft {
            // Unwind the ring buffer in time order, apply the Hann window.
            let oldest = (historyHead - historyLength + fftSize) % fftSize
            for i in 0..<fftSize {
                let ringIndex = (oldest + i) % fftSize
                let raw = i < historyLength ? history[ringIndex] : 0
                scratchIn[i] = raw * window[i]
            }
            let spectrum = dft.transform(real: scratchIn, imaginary: scratchImaginary)
            for bin in 0..<magnitudes.count {
                let re = spectrum.real[bin]
                let im = spectrum.imaginary[bin]
                magnitudes[bin] = (re * re + im * im).squareRoot()
            }
        }

        let binWidth = sampleRate / Float(fftSize)
        for band in 0..<bandCount {
            let range = binRanges[band]
            var peak: Float = 0
            for bin in range where bin < magnitudes.count {
                let mag = magnitudes[bin]
                if mag > peak { peak = mag }
            }
            // Reference so amplitude maps to a stable dB range regardless of FFT size.
            let db = 20 * log10(peak / Float(fftSize / 4) + 1e-7)
            var normalized = (db - Self.noiseFloorDB) / (Self.ceilingDB - Self.noiseFloorDB)
            normalized = min(1, max(0, normalized))
            // Gentle expansion keeps quiet speech visible and silence calm.
            normalized = powf(normalized, 1.35)

            let alpha = normalized > smoothed[band] ? Self.attack : Self.release
            smoothed[band] += (normalized - smoothed[band]) * alpha
        }
        return smoothed
    }

    private func rebuildBinRangesIfNeeded(sampleRate: Float) {
        guard abs(sampleRate - cachedSampleRate) > 1, sampleRate > 0 else { return }
        cachedSampleRate = sampleRate

        let binWidth = sampleRate / Float(fftSize)
        let nyquistBin = fftSize / 2
        var edges = [Int]()
        edges.reserveCapacity(bandCount + 1)
        for i in 0...bandCount {
            let hz = Self.lowestHz * powf(Self.highestHz / Self.lowestHz, Float(i) / Float(bandCount))
            let bin = max(1, min(nyquistBin - 1, Int((hz / binWidth).rounded())))
            if let last = edges.last, bin <= last {
                edges.append(last + 1 <= nyquistBin - 1 ? last + 1 : last)
            } else {
                edges.append(bin)
            }
        }
        binRanges = (0..<bandCount).map { edges[$0]..<max(edges[$0] + 1, edges[$0 + 1]) }
    }
}
