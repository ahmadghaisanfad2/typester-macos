import XCTest
@testable import TypesterCore

final class SpectrumAnalyzerTests: XCTestCase {
    private func feed(
        _ analyzer: SpectrumAnalyzer,
        sineHz: Float,
        sampleRate: Float,
        amplitude: Float = 0.45,
        windows: Int = 4
    ) -> [[Float]] {
        let fftSize = 512
        analyzer.reset()
        var results: [[Float]] = []
        var phase: Float = 0
        let phaseStep = 2 * Float.pi * sineHz / sampleRate
        for _ in 0..<windows {
            var block = [Float](repeating: 0, count: fftSize)
            for i in 0..<fftSize {
                block[i] = amplitude * sinf(phase)
                phase += phaseStep
            }
            block.withUnsafeBufferPointer { buffer in
                analyzer.appendSamples(buffer.baseAddress!, count: fftSize)
            }
            results.append(analyzer.bandLevels(sampleRate: sampleRate))
        }
        return results
    }

    func testSilenceStaysQuiet() {
        let analyzer = SpectrumAnalyzer()
        analyzer.reset()
        let zeros = [Float](repeating: 0, count: 512)
        zeros.withUnsafeBufferPointer { buffer in
            analyzer.appendSamples(buffer.baseAddress!, count: 512)
        }
        let bands = analyzer.bandLevels(sampleRate: 48_000)
        XCTAssertEqual(bands.count, analyzer.bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 < 0.1 }, "silence should stay near zero, got \(bands)")
    }

    func testLowTonePeaksInLowBand() {
        let analyzer = SpectrumAnalyzer()
        let results = feed(analyzer, sineHz: 250, sampleRate: 48_000)
        let bands = results.last!
        let peak = bands.firstIndex(of: bands.max()!)!
        XCTAssertTrue(peak <= 2, "250 Hz should sit in a low band, peaked at \(peak): \(bands)")
        XCTAssertTrue(bands.max()! > 0.3, "a strong tone should register clearly: \(bands)")
    }

    func testHighTonePeaksInHighBand() {
        let analyzer = SpectrumAnalyzer()
        let results = feed(analyzer, sineHz: 4_000, sampleRate: 48_000)
        let bands = results.last!
        let peak = bands.firstIndex(of: bands.max()!)!
        XCTAssertTrue(peak >= 6, "4 kHz should sit in a high band, peaked at \(peak): \(bands)")
    }

    func testAttackRisesMonotonically() {
        let analyzer = SpectrumAnalyzer()
        let results = feed(analyzer, sineHz: 250, sampleRate: 48_000, windows: 6)
        let peaks = results.map { $0.max()! }
        XCTAssertTrue(peaks == peaks.sorted(), "attack smoothing should be monotonic: \(peaks)")
    }

    func testResetClearsHistory() {
        let analyzer = SpectrumAnalyzer()
        _ = feed(analyzer, sineHz: 250, sampleRate: 48_000)
        analyzer.reset()
        let bands = analyzer.bandLevels(sampleRate: 48_000)
        XCTAssertTrue(bands.allSatisfy { $0 < 0.1 }, "reset should drop back to silence, got \(bands)")
    }
}
