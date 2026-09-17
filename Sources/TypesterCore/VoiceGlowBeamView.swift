import SwiftUI
import TypesterCore

/// Libraries.dev Voice + Border beam, drawn as a **masked in-capsule background**.
///
/// Recording: full-interior colorful ambient + bottom Voice bloom — no dark
/// plate left behind labels or the waveform.
/// Transcribing: colorful Border beam rides the **capsule edges**; interior
/// stays a soft wash so content is not sitting on black.
struct VoiceGlowBeamView: View {
    var frame: VoiceGlowFrame
    var palette: VoiceGlowPalette = .colorful
    var config: VoiceGlowConfig = .default
    /// Relative reach into the capsule (0…1 of view height at full voice).
    var reachFraction: CGFloat = 0.72
    /// Border-beam thickness scale when processing.
    var beamStrength: CGFloat = 1.0

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Canvas { context, size in
            guard frame.intensity > 0.01, size.width > 4, size.height > 4 else { return }

            let intensity = CGFloat(min(1, frame.intensity))
            let level = CGFloat(min(1, frame.level))
            let isBeam = frame.beamPhase != nil && !accessibilityReduceMotion
            let phase = CGFloat(frame.beamPhase ?? 0.5)

            // Always paint the interior first so labels/waveform never sit on black.
            drawFullInteriorAmbient(
                context: context,
                size: size,
                intensity: intensity,
                level: level,
                emphasizeBottom: !isBeam
            )

            if isBeam {
                drawEdgeBeam(
                    context: context,
                    size: size,
                    phase: Float(phase),
                    intensity: intensity
                )
            } else {
                let maxReach = size.height * reachFraction * CGFloat(max(0.25, config.reach))
                let spread = CGFloat(max(0.25, config.spread))
                let reach = maxReach * (0.28 + 0.72 * level)
                drawVoiceBloom(
                    context: context,
                    size: size,
                    edgeY: size.height,
                    level: level,
                    intensity: intensity,
                    spread: spread,
                    reach: reach
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Full interior ambient (kills the black plate look)

    private func drawFullInteriorAmbient(
        context: GraphicsContext,
        size: CGSize,
        intensity: CGFloat,
        level: CGFloat,
        emphasizeBottom: Bool
    ) {
        let lobes = palette.lobes.isEmpty ? [palette.mid, palette.below, palette.above] : palette.lobes
        // Strong enough that the content row is on color, not on the dark base.
        let base = intensity * (0.34 + 0.22 * level)

        // Horizontal multi-lobe wash across the entire capsule.
        let horizontal = lobes.enumerated().map { index, hex -> Color in
            let t = lobes.count <= 1 ? 0.5 : CGFloat(index) / CGFloat(lobes.count - 1)
            let center = 1 - abs(t - 0.5) * 2
            return Color(hex: hex).opacity(Double(base * (0.55 + 0.45 * center)))
        }
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: horizontal),
                startPoint: CGPoint(x: 0, y: size.height * 0.55),
                endPoint: CGPoint(x: size.width, y: size.height * 0.55)
            )
        )

        // Vertical lift — stronger at the bottom when recording (Voice).
        let liftOpacity = intensity * (emphasizeBottom ? (0.22 + 0.28 * level) : 0.14)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: palette.above).opacity(Double(liftOpacity * 0.35)), location: 0),
                    .init(color: Color(hex: palette.mid).opacity(Double(liftOpacity * 0.7)), location: 0.45),
                    .init(color: Color(hex: palette.below).opacity(Double(liftOpacity)), location: 1)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )
    }

    // MARK: - Voice bloom (recording, bottom emphasis)

    private func drawVoiceBloom(
        context: GraphicsContext,
        size: CGSize,
        edgeY: CGFloat,
        level: CGFloat,
        intensity: CGFloat,
        spread: CGFloat,
        reach: CGFloat
    ) {
        let lobes = palette.lobes.isEmpty ? [palette.mid] : palette.lobes
        let count = lobes.count

        for (index, hex) in lobes.enumerated() {
            let t = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let centerWeight = 1 - abs(t - 0.5) * 2
            let x = size.width * (0.5 + (t - 0.5) * spread)
            let lobeRadius = reach * (0.55 + 0.55 * centerWeight) * (0.45 + 0.55 * level)
            let opacity = intensity * (0.28 + 0.45 * centerWeight) * (0.4 + 0.6 * level)
            let color = Color(hex: hex).opacity(Double(min(0.9, opacity)))

            let rect = CGRect(
                x: x - lobeRadius * 1.25,
                y: edgeY - lobeRadius * 1.1,
                width: lobeRadius * 2.5,
                height: lobeRadius * 1.6
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    center: CGPoint(x: x, y: edgeY - lobeRadius * 0.15),
                    startRadius: 0,
                    endRadius: max(1, lobeRadius * 1.15)
                )
            )
        }

        let coreOpacity = intensity * (0.22 + 0.45 * level)
        let coreWidth = size.width * min(0.92, spread + 0.2)
        let coreRect = CGRect(
            x: (size.width - coreWidth) / 2,
            y: edgeY - reach * 0.42,
            width: coreWidth,
            height: reach * 0.55
        )
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [
                    Color(hex: palette.core).opacity(Double(min(0.85, coreOpacity))),
                    Color(hex: palette.above).opacity(Double(coreOpacity * 0.4)),
                    Color(hex: palette.core).opacity(0)
                ]),
                center: CGPoint(x: coreRect.midX, y: edgeY - 2),
                startRadius: 0,
                endRadius: max(1, coreRect.width * 0.5)
            )
        )
    }

    // MARK: - Border beam on capsule edges (transcribing)

    private func drawEdgeBeam(
        context: GraphicsContext,
        size: CGSize,
        phase: Float,
        intensity: CGFloat
    ) {
        let width = Float(size.width)
        let height = Float(size.height)
        // Ride the true capsule edge (tiny inset so clip does not eat the glow).
        let inset = Float(1.5)
        let sampler = VoiceBorderBeamSampler(width: width, height: height, inset: inset)
        let edgeRect = CGRect(
            x: CGFloat(inset),
            y: CGFloat(inset),
            width: CGFloat(max(1, sampler.innerWidth)),
            height: CGFloat(max(1, sampler.innerHeight))
        )
        let path = Path(roundedRect: edgeRect, cornerRadius: CGFloat(sampler.radius), style: .continuous)

        let lobes = palette.lobes.isEmpty ? [palette.mid, palette.above, palette.below, palette.core] : palette.lobes
        let railAlpha = intensity * 0.55 * CGFloat(max(0.5, beamStrength))

        // Continuous colorful rail along the entire edge.
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: lobes.map {
                    Color(hex: $0).opacity(Double(railAlpha))
                }),
                startPoint: CGPoint(x: edgeRect.minX, y: edgeRect.midY),
                endPoint: CGPoint(x: edgeRect.maxX, y: edgeRect.midY)
            ),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
        )

        // Soft outer bloom hugging the edge (reads as glow on the rim, not inside).
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: lobes.map {
                    Color(hex: $0).opacity(Double(intensity * 0.22))
                }),
                startPoint: CGPoint(x: edgeRect.minX, y: edgeRect.midY),
                endPoint: CGPoint(x: edgeRect.maxX, y: edgeRect.midY)
            ),
            style: StrokeStyle(lineWidth: 8, lineCap: .round)
        )

        // Traveling head + trail along the edge path.
        let trailCount = 18
        let span: Float = 0.16
        let samples = sampler.trail(phase: phase, count: trailCount, span: span)
        let bloom = max(5, size.height * 0.2) * CGFloat(max(0.5, beamStrength))

        for sample in samples {
            let u = CGFloat(sample.u)
            let colorHex = lobes[min(lobes.count - 1, Int(u * CGFloat(lobes.count - 1) + 0.5))]
            let opacity = intensity * Double(0.3 + 0.65 * pow(Double(u), 1.15)) * Double(beamStrength)
            let radius = bloom * (0.4 + 0.6 * u)
            let color = Color(hex: colorHex).opacity(min(0.95, opacity))
            let center = CGPoint(x: CGFloat(sample.x), y: CGFloat(sample.y))
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: max(1, radius)
                )
            )
        }

        if let head = samples.last {
            let headColor = Color(hex: palette.core).opacity(Double(min(1, intensity * beamStrength)))
            let r = bloom * 0.4
            let center = CGPoint(x: CGFloat(head.x), y: CGFloat(head.y))
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(colors: [headColor, headColor.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: max(1, r)
                )
            )
        }
    }
}

// MARK: - In-capsule background helper

extension VoiceGlowBeamView {
    /// Glow that fills the parent capsule and is clipped by it (no outer bleed).
    static func capsuleBackground(
        frame: VoiceGlowFrame,
        palette: VoiceGlowPalette = .colorful,
        reachFraction: CGFloat = 0.72,
        reduceMotion: Bool
    ) -> some View {
        var adjusted = frame
        if reduceMotion, frame.beamPhase != nil {
            // Steady edge energy, no travel.
            adjusted.beamPhase = nil
            adjusted.level = max(adjusted.level, VoiceGlowConfig.default.processingLevel)
            adjusted.intensity = max(adjusted.intensity, 0.45)
        }
        return VoiceGlowBeamView(
            frame: adjusted,
            palette: palette,
            reachFraction: reachFraction
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
