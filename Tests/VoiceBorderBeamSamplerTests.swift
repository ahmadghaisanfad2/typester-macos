import XCTest
@testable import TypesterCore

final class VoiceBorderBeamSamplerTests: XCTestCase {
    func testPathLengthMatchesCapsuleFormula() {
        // Width 200, height 40, inset 0 → r=20, straight=160
        // length = 2*160 + 2*π*20
        let sampler = VoiceBorderBeamSampler(width: 200, height: 40, inset: 0)
        let expected = 2 * 160 + 2 * Float.pi * 20
        XCTAssertEqual(sampler.pathLength, expected, accuracy: 0.01)
    }

    func testPhaseZeroIsTopLeftOfStraightEdge() {
        let sampler = VoiceBorderBeamSampler(width: 200, height: 40, inset: 0)
        let p = sampler.point(at: 0)
        XCTAssertEqual(p.x, 20, accuracy: 0.05) // r
        XCTAssertEqual(p.y, 0, accuracy: 0.05)
    }

    func testQuarterPathIsMidTopEdge() {
        let sampler = VoiceBorderBeamSampler(width: 200, height: 40, inset: 0)
        // Top straight is 160 of total ~405.66; mid-top ≈ 80/total
        let midTop = 80 / sampler.pathLength
        let p = sampler.point(at: midTop)
        XCTAssertEqual(p.x, 100, accuracy: 0.5)
        XCTAssertEqual(p.y, 0, accuracy: 0.5)
    }

    func testTrailProgressesAlongPath() {
        let sampler = VoiceBorderBeamSampler(width: 180, height: 44, inset: 2)
        let trail = sampler.trail(phase: 0.3, count: 8, span: 0.1)
        XCTAssertEqual(trail.count, 8)
        XCTAssertEqual(trail.last!.u, 1, accuracy: 0.001)
        XCTAssertEqual(trail.first!.u, 0, accuracy: 0.001)
        // Head (phase 0.3) should not equal tail (phase 0.2)
        let head = trail.last!
        let tail = trail.first!
        let dx = abs(head.x - tail.x) + abs(head.y - tail.y)
        XCTAssertGreaterThan(dx, 1)
    }

    func testInsetKeepsPointsInsideOuterBounds() {
        let sampler = VoiceBorderBeamSampler(width: 200, height: 48, inset: 6)
        for i in 0..<36 {
            let p = sampler.point(at: Float(i) / 36)
            XCTAssertGreaterThanOrEqual(p.x, 6 - 0.1)
            XCTAssertLessThanOrEqual(p.x, 200 - 6 + 0.1)
            XCTAssertGreaterThanOrEqual(p.y, 6 - 0.1)
            XCTAssertLessThanOrEqual(p.y, 48 - 6 + 0.1)
        }
    }
}
