import Foundation

/// Multi-lobe colors for the Libraries.dev–style Voice glow, as raw sRGB hex.
public struct VoiceGlowPalette: Equatable, Sendable {
    /// Soft lobe colors spread along the bottom edge (up to 7).
    public let lobes: [UInt32]
    /// Bright core / highlight color.
    public let core: UInt32
    /// Band colors for the glow stack (above → mid → below the edge).
    public let above: UInt32
    public let mid: UInt32
    public let below: UInt32

    public init(
        lobes: [UInt32],
        core: UInt32 = 0xF5F7FA,
        above: UInt32 = 0x9B7CFF,
        mid: UInt32 = 0x5B8CFF,
        below: UInt32 = 0xFF7AB8
    ) {
        self.lobes = Array(lobes.prefix(7))
        self.core = core
        self.above = above
        self.mid = mid
        self.below = below
    }

    /// Libraries.dev Voice `colorful` — vibrant multi-lobe bloom.
    public static let colorful = VoiceGlowPalette(
        lobes: [
            0x5B8CFF,
            0x7C5CFF,
            0xC45CFF,
            0xFF6B9D,
            0xFFB86B,
            0x6BFFE0,
            0xA8FF6B
        ],
        core: 0xF5F7FA,
        above: 0x9B7CFF,
        mid: 0x5B8CFF,
        below: 0xFF7AB8
    )
}

/// Input chain + shape knobs for the native Voice glow.
public struct VoiceGlowConfig: Equatable, Sendable {
    /// Levels below this gate toward the idle floor.
    public var threshold: Float
    /// Envelope rise factor (0…1 per step).
    public var attack: Float
    /// Envelope fall factor (0…1 per step).
    public var release: Float
    /// Quiet floor while active so silence still breathes a little.
    public var idle: Float
    /// Relative bloom height.
    public var reach: Float
    /// Horizontal lobe spread (0…1).
    public var spread: Float
    /// Overall effect opacity multiplier.
    public var strength: Float
    /// Seconds for one left→right processing beam cycle.
    public var beamPeriod: TimeInterval
    /// Steady glow level used while processing (beam mode).
    public var processingLevel: Float

    public init(
        threshold: Float = 0.04,
        attack: Float = 0.42,
        release: Float = 0.16,
        idle: Float = 0.05,
        reach: Float = 1.0,
        spread: Float = 0.55,
        strength: Float = 0.9,
        beamPeriod: TimeInterval = 1.6,
        processingLevel: Float = 0.32
    ) {
        self.threshold = threshold
        self.attack = attack
        self.release = release
        self.idle = idle
        self.reach = reach
        self.spread = spread
        self.strength = strength
        self.beamPeriod = beamPeriod
        self.processingLevel = processingLevel
    }

    public static let `default` = VoiceGlowConfig()
}

/// One display frame of the Voice glow after envelope + beam evaluation.
public struct VoiceGlowFrame: Equatable, Sendable {
    /// Smoothed 0…1 bloom energy.
    public var level: Float
    /// Overall opacity factor for the glow.
    public var intensity: Float
    /// Non-nil only while processing; 0…1 travel position along the edge.
    public var beamPhase: Float?

    public init(level: Float, intensity: Float, beamPhase: Float? = nil) {
        self.level = level
        self.intensity = intensity
        self.beamPhase = beamPhase
    }

    public static let inactive = VoiceGlowFrame(level: 0, intensity: 0, beamPhase: nil)
}

/// Turns raw mic level + processing state into a smooth Voice-glow frame.
///
/// Pure logic — no UI, no audio hardware. Drive it from `AudioRecorder.onAudioLevel`
/// at display rate via `VoiceGlowTargetBox` or a TimelineView.
public final class VoiceGlowDriver {
    public private(set) var smoothed: Float = 0
    public var config: VoiceGlowConfig

    public init(config: VoiceGlowConfig = .default) {
        self.config = config
    }

    /// Drop envelope state so a new dictation session does not inherit bloom.
    public func reset() {
        smoothed = 0
    }

    /// Advance one frame. `time` is any monotonic seconds clock (used for beam travel).
    public func step(
        level rawLevel: Float,
        processing: Bool,
        time: TimeInterval,
        active: Bool = true
    ) -> VoiceGlowFrame {
        guard active else {
            smoothed = 0
            return .inactive
        }

        if processing {
            let target = config.processingLevel
            let alpha = target > smoothed ? config.attack : config.release
            smoothed += (target - smoothed) * alpha
            smoothed = min(1, max(0, smoothed))
            let period = max(0.2, config.beamPeriod)
            let phase = Float((time / period).truncatingRemainder(dividingBy: 1.0))
            let intensity = min(1, max(config.idle, smoothed) * config.strength)
            return VoiceGlowFrame(level: smoothed, intensity: intensity, beamPhase: phase)
        }

        let gated = rawLevel < config.threshold ? 0 : min(1, max(0, rawLevel))
        let target = max(config.idle, gated)
        let alpha = target > smoothed ? config.attack : config.release
        smoothed += (target - smoothed) * alpha
        smoothed = min(1, max(0, smoothed))

        // Map envelope → opacity: silence stays near idle, speech blooms.
        let normalized = (smoothed - config.idle * 0.5) / max(0.001, 1 - config.idle * 0.5)
        let intensity = min(1, max(0, normalized) * config.strength + config.idle * 0.4 * config.strength)
        return VoiceGlowFrame(level: smoothed, intensity: intensity, beamPhase: nil)
    }
}

/// Samples a Libraries.dev–style border beam along a capsule/stadium path.
///
/// Path runs clockwise from the top-left of the straight top edge:
/// top → right cap → bottom (right-to-left) → left cap.
public struct VoiceBorderBeamSampler: Equatable, Sendable {
    public var width: Float
    public var height: Float
    /// Inset from the outer bounds so the beam rides *inside* the capsule.
    public var inset: Float

    public init(width: Float, height: Float, inset: Float = 2.5) {
        self.width = width
        self.height = height
        self.inset = inset
    }

    public var innerWidth: Float { max(0, width - 2 * inset) }
    public var innerHeight: Float { max(0, height - 2 * inset) }
    public var radius: Float { min(innerWidth, innerHeight) / 2 }

    public var pathLength: Float {
        let straight = max(0, innerWidth - 2 * radius)
        return 2 * straight + 2 * .pi * radius
    }

    /// Point on the inner stadium path for `phase` in 0…1 (wraps).
    public func point(at phase: Float) -> (x: Float, y: Float) {
        let w = innerWidth
        let h = innerHeight
        let r = max(0.5, radius)
        let straight = max(0, w - 2 * r)
        let arc = Float.pi * r
        let total = max(0.001, 2 * straight + 2 * arc)
        var s = (phase - floor(phase)) * total

        // Origin of the inner rect in parent coordinates.
        let ox = inset
        let oy = inset

        // Top edge, left → right.
        if s <= straight {
            return (ox + r + s, oy)
        }
        s -= straight

        // Right cap: top-right → bottom-right.
        if s <= arc {
            let angle = s / r
            return (ox + r + straight + r * sin(angle), oy + r - r * cos(angle))
        }
        s -= arc

        // Bottom edge, right → left.
        if s <= straight {
            return (ox + r + straight - s, oy + h)
        }
        s -= straight

        // Left cap: bottom-left → top-left.
        let angle = s / r
        return (ox + r - r * sin(angle), oy + r + r * cos(angle))
    }

    /// A short trail of samples for `phase`, newest last. `span` is path-normalized.
    public func trail(phase: Float, count: Int, span: Float) -> [(x: Float, y: Float, u: Float)] {
        let n = max(1, count)
        return (0..<n).map { i in
            let u = Float(i) / Float(n - 1 == 0 ? 1 : n - 1)
            let t = phase - span * (1 - u)
            let p = point(at: t)
            return (p.x, p.y, u)
        }
    }
}

/// Main-thread holder for the newest mic level + overlay activity flags.
///
/// Mirrors `SpectrumTargetBox`: writes are cheap; UI samples on TimelineView
/// without `@Published` 60 Hz storms.
public final class VoiceGlowTargetBox {
    private let lock = NSLock()
    private var _rawLevel: Float = 0
    private var _active = false
    private var _processing = false
    private var _driver = VoiceGlowDriver()

    public init(config: VoiceGlowConfig = .default) {
        _driver = VoiceGlowDriver(config: config)
    }

    public var rawLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _rawLevel
    }

    public var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return _active
    }

    public var processing: Bool {
        lock.lock(); defer { lock.unlock() }
        return _processing
    }

    public func update(level: Float) {
        lock.lock()
        _rawLevel = min(1, max(0, level))
        lock.unlock()
    }

    public func setActive(_ active: Bool) {
        lock.lock()
        _active = active
        if !active {
            _rawLevel = 0
            _processing = false
            _driver.reset()
        }
        lock.unlock()
    }

    public func setProcessing(_ processing: Bool) {
        lock.lock()
        _processing = processing
        if !processing {
            // Keep last raw level; envelope will release naturally.
        }
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        _rawLevel = 0
        _active = false
        _processing = false
        _driver.reset()
        lock.unlock()
    }

    /// Sample a display frame for `time` (seconds). Call from TimelineView.
    public func frame(at time: TimeInterval) -> VoiceGlowFrame {
        lock.lock()
        let frame = _driver.step(
            level: _rawLevel,
            processing: _processing,
            time: time,
            active: _active
        )
        lock.unlock()
        return frame
    }
}
