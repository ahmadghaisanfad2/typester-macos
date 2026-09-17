import XCTest
@testable import TypesterCore

final class VoiceGlowModelTests: XCTestCase {
    func testColorfulPaletteHasMultipleLobes() {
        let palette = VoiceGlowPalette.colorful
        XCTAssertGreaterThanOrEqual(palette.lobes.count, 5)
        XCTAssertLessThanOrEqual(palette.lobes.count, 7)
    }

    func testInactiveActiveReturnsZeroIntensity() {
        let driver = VoiceGlowDriver()
        let frame = driver.step(level: 0.8, processing: false, time: 0, active: false)
        XCTAssertEqual(frame, .inactive)
        XCTAssertEqual(driver.smoothed, 0)
    }

    func testSilenceStaysNearIdleWhenActive() {
        let driver = VoiceGlowDriver()
        var frame = VoiceGlowFrame.inactive
        for i in 0..<30 {
            frame = driver.step(level: 0, processing: false, time: Double(i) / 60, active: true)
        }
        XCTAssertLessThan(frame.level, 0.15)
        XCTAssertGreaterThan(frame.intensity, 0)
        XCTAssertNil(frame.beamPhase)
    }

    func testAttackRisesWithLoudInput() {
        let driver = VoiceGlowDriver()
        var frames: [Float] = []
        for i in 0..<20 {
            let frame = driver.step(level: 0.9, processing: false, time: Double(i) / 60, active: true)
            frames.append(frame.level)
        }
        XCTAssertEqual(frames, frames.sorted(), "attack envelope should rise monotonically")
        XCTAssertGreaterThan(frames.last ?? 0, 0.5)
    }

    func testReleaseFallsAfterVoiceStops() {
        let driver = VoiceGlowDriver()
        for i in 0..<25 {
            _ = driver.step(level: 0.95, processing: false, time: Double(i) / 60, active: true)
        }
        let peak = driver.smoothed
        XCTAssertGreaterThan(peak, 0.5)

        var later: [Float] = []
        for i in 0..<40 {
            let frame = driver.step(level: 0, processing: false, time: 1 + Double(i) / 60, active: true)
            later.append(frame.level)
        }
        XCTAssertEqual(later, later.sorted(by: >), "release should fall after speech ends")
        XCTAssertLessThan(later.last ?? 1, peak)
    }

    func testThresholdGatesQuietNoise() {
        let config = VoiceGlowConfig(threshold: 0.2, idle: 0.05)
        let driver = VoiceGlowDriver(config: config)
        var frame = VoiceGlowFrame.inactive
        for i in 0..<20 {
            frame = driver.step(level: 0.1, processing: false, time: Double(i) / 60, active: true)
        }
        XCTAssertLessThanOrEqual(frame.level, config.idle + 0.02)
    }

    func testProcessingProducesAdvancingBeamPhase() {
        let config = VoiceGlowConfig(beamPeriod: 1.0, processingLevel: 0.3)
        let driver = VoiceGlowDriver(config: config)
        var phases: [Float] = []
        for i in 0..<10 {
            let frame = driver.step(level: 0, processing: true, time: Double(i) * 0.1, active: true)
            XCTAssertNotNil(frame.beamPhase)
            phases.append(frame.beamPhase!)
        }
        // 0.0, 0.1, … 0.9 with period 1.0
        for (index, phase) in phases.enumerated() {
            XCTAssertEqual(phase, Float(index) * 0.1, accuracy: 0.02)
        }
        XCTAssertGreaterThan(driver.smoothed, 0.1)
    }

    func testProcessingFrameHasNoBeamWhenNotProcessing() {
        let driver = VoiceGlowDriver()
        let frame = driver.step(level: 0.7, processing: false, time: 0.5, active: true)
        XCTAssertNil(frame.beamPhase)
    }

    func testTargetBoxResetClearsState() {
        let box = VoiceGlowTargetBox()
        box.setActive(true)
        box.setProcessing(true)
        box.update(level: 0.9)
        _ = box.frame(at: 0.2)
        box.reset()
        XCTAssertEqual(box.rawLevel, 0)
        XCTAssertFalse(box.active)
        XCTAssertFalse(box.processing)
        let frame = box.frame(at: 0.3)
        XCTAssertEqual(frame, .inactive)
    }

    func testTargetBoxInactiveClearsLevel() {
        let box = VoiceGlowTargetBox()
        box.setActive(true)
        box.update(level: 0.8)
        box.setActive(false)
        XCTAssertEqual(box.rawLevel, 0)
        XCTAssertEqual(box.frame(at: 0), .inactive)
    }
}
