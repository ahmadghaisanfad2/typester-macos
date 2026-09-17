import SwiftUI
import TypesterCore

/// Libraries.dev Voice + Border beam, drawn as a **masked in-capsule background**.
///
/// Recording: multi-lobe colorful bloom from the bottom edge (Voice).
/// Transcribing: a colorful beam rides the **inner perimeter** of the capsule
/// (Border beam). No outer bleed — parent clips to the capsule shape.
struct VoiceGlowBeamView: View {
    var frame: VoiceGlowFrame
    var palette: VoiceGlowPalette = .colorful
    var config: VoiceGlowConfig = .default
    /// Relative reach into the capsule (0…1 of view height at full voice).
    var reachFraction: CGFloat = 0.72
    /// Border-beam thickness scale when processing.
    var beamStrength: CGFloat = 0.85

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Canvas { context, size in
            guard frame.intensity > 0.01, size.width > 4, size.height > 4 else { return }

            let intensity = CGFloat(min(1, frame.intensity))
            let level = CGFloat(min(1, frame.level))
            let isBeam = frame.beamPhase != nil && !accessibilityReduceMotion
            let phase = CGFloat(frame.beamPhase ?? 0.5)

            let edgeY = size.height
            let spread = CGFloat(max(0.25, config.spread))
            let maxReach = size.height * reachFraction * CGFloat(max(0.25, config.reach))

            if isBeam {
                // Soft interior wash so the capsule still feels alive…
                drawInteriorWash(
                    context: context,
                    size: size,
                    intensity: intensity * 0.55,
                    level: max(level, 0.35)
                )
                // …plus the Border beam riding the inner edge.
                drawBorderBeam(
                    context: context,
                    size: size,
                    phase: Float(phase),
                    intensity: intensity,
                    maxReach: maxReach
                )
            } else {
                let reach = maxReach * (0.28 + 0.72 * level)
                drawVoiceBloom(
                    context: context,
                    size: size,
                    edgeY: edgeY,
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

    // MARK: - Voice bloom (recording)

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

        // Broad continuous wash — no hard plateau under the lobes.
        let washOpacity = intensity * (0.2 + 0.45 * level)
        let washHeight = max(10, reach * 1.25)
        context.fill(
            Path(CGRect(x: 0, y: edgeY - washHeight, width: size.width, height: washHeight)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: palette.below).opacity(0), location: 0),
                    .init(color: Color(hex: palette.mid).opacity(Double(washOpacity * 0.5)), location: 0.4),
                    .init(color: Color(hex: palette.below).opacity(Double(washOpacity)), location: 1)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: edgeY - washHeight),
                endPoint: CGPoint(x: size.width / 2, y: edgeY)
            )
        )

        for (index, hex) in lobes.enumerated() {
            let t = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let centerWeight = 1 - abs(t - 0.5) * 2
            let x = size.width * (0.5 + (t - 0.5) * spread)
            let lobeRadius = reach * (0.55 + 0.55 * centerWeight) * (0.45 + 0.55 * level)
            let opacity = intensity * (0.32 + 0.55 * centerWeight) * (0.4 + 0.6 * level)
            let color = Color(hex: hex).opacity(Double(min(0.95, opacity)))

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

        let coreOpacity = intensity * (0.25 + 0.55 * level)
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
                    Color(hex: palette.core).opacity(Double(min(0.9, coreOpacity))),
                    Color(hex: palette.above).opacity(Double(coreOpacity * 0.45)),
                    Color(hex: palette.core).opacity(0)
                ]),
                center: CGPoint(x: coreRect.midX, y: edgeY - 2),
                startRadius: 0,
                endRadius: max(1, coreRect.width * 0.5)
            )
        )
    }

    // MARK: - Border beam (transcribing)

    private func drawInteriorWash(
        context: GraphicsContext,
        size: CGSize,
        intensity: CGFloat,
        level: CGFloat
    ) {
        let colors = [
            Color(hex: palette.mid).opacity(Double(intensity * 0.22 * level)),
            Color(hex: palette.below).opacity(Double(intensity * 0.16 * level)),
            Color(hex: palette.above).opacity(Double(intensity * 0.10 * level)),
            .clear
        ]
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: colors),
                center: CGPoint(x: size.width * 0.5, y: size.height),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.85
            )
        )
    }

    private func drawBorderBeam(
        context: GraphicsContext,
        size: CGSize,
        phase: Float,
        intensity: CGFloat,
        maxReach: CGFloat
    ) {
        let width = Float(size.width)
        let height = Float(size.height)
        // Stay clearly inside the rounded ends so the beam is not clipped away.
        let inset = Float(min(size.height, size.width) * 0.12 + 2)
        let sampler = VoiceBorderBeamSampler(width: width, height: height, inset: inset)

        let trailCount = 16
        let span: Float = 0.14
        let samples = sampler.trail(phase: phase, count: trailCount, span: span)
        let lobes = palette.lobes.isEmpty ? [palette.mid, palette.above, palette.below] : palette.lobes
        let bloom = CGFloat(max(4, min(size.height * 0.22, maxReach * 0.35))) * CGFloat(max(0.4, beamStrength))

        // Faint full-perimeter rail so the path reads even between pulses.
        let railOpacity = intensity * 0.18
        let rail = capsulePath(
            in: CGRect(x: CGFloat(inset), y: CGFloat(inset),
                       width: CGFloat(sampler.innerWidth), height: CGFloat(sampler.innerHeight))
        )
        context.stroke(
            rail,
            with: .color(Color(hex: palette.mid).opacity(Double(railOpacity))),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )

        for sample in samples {
            let u = CGFloat(sample.u)
            let colorHex = lobes[min(lobes.count - 1, Int(u * CGFloat(lobes.count - 1) + 0.5))]
            // Head is brighter; trail fades.
            let opacity = intensity * Double(0.25 + 0.7 * pow(Double(u), 1.2)) * Double(beamStrength)
            let radius = bloom * (0.45 + 0.55 * u)
            let color = Color(hex: colorHex).opacity(min(0.95, opacity))
            let center = CGPoint(x: CGFloat(sample.x), y: CGFloat(sample.y))
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: max(1, radius)
                )
            )
        }

        // Bright head core.
        if let head = samples.last {
            let headColor = Color(hex: palette.core).opacity(Double(min(1, intensity * beamStrength)))
            let r = bloom * 0.35
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

    private func capsulePath(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
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
            // No travel — steady in-capsule energy only.
            adjusted.beamPhase = nil
            adjusted.level = max(adjusted.level, VoiceGlowConfig.default.processingLevel)
            adjusted.intensity = max(adjusted.intensity, 0.4)
        }
        return VoiceGlowBeamView(
            frame: adjusted,
            palette: palette,
            reachFraction: reachFraction
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
