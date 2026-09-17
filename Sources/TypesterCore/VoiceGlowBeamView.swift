import SwiftUI
import TypesterCore

/// Libraries.dev Voice-style glow used as a **masked in-capsule background**.
///
/// Multi-lobe colorful bloom rises from the bottom edge inside the pill shape;
/// when `frame.beamPhase` is set, a concentrated core travels left → right.
/// Parent views clip this layer to the capsule — it must not draw outside.
struct VoiceGlowBeamView: View {
    var frame: VoiceGlowFrame
    var palette: VoiceGlowPalette = .colorful
    var config: VoiceGlowConfig = .default
    /// Relative reach into the capsule (0…1 of view height at full voice).
    var reachFraction: CGFloat = 0.72

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Canvas { context, size in
            guard frame.intensity > 0.01, size.width > 4, size.height > 4 else { return }

            let intensity = CGFloat(min(1, frame.intensity))
            let level = CGFloat(min(1, frame.level))
            let isBeam = frame.beamPhase != nil && !accessibilityReduceMotion
            let phase = CGFloat(frame.beamPhase ?? 0.5)

            // Glow is anchored to the true bottom of the clipped capsule.
            let edgeY = size.height
            let spread = CGFloat(max(0.25, config.spread))
            let maxReach = size.height * reachFraction * CGFloat(max(0.25, config.reach))
            let reach = maxReach * (0.28 + 0.72 * level)

            if isBeam {
                drawTravelingBeam(
                    context: context,
                    size: size,
                    phase: phase,
                    edgeY: edgeY,
                    intensity: intensity,
                    reach: max(maxReach * 0.55, reach)
                )
            } else {
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

        // Broad warm wash first so the bottom reads as lit from within.
        let washOpacity = intensity * (0.18 + 0.42 * level)
        let washHeight = max(8, reach * 1.15)
        context.fill(
            Path(CGRect(x: 0, y: edgeY - washHeight, width: size.width, height: washHeight)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: palette.below).opacity(0), location: 0),
                    .init(color: Color(hex: palette.mid).opacity(Double(washOpacity * 0.55)), location: 0.45),
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

            // Ellipse centered on the bottom edge so the upper half blooms inward.
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

        // Bright core arc hugging the bottom edge inside the mask.
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

    private func drawTravelingBeam(
        context: GraphicsContext,
        size: CGSize,
        phase: CGFloat,
        edgeY: CGFloat,
        intensity: CGFloat,
        reach: CGFloat
    ) {
        // Keep the traveling core inside the rounded ends.
        let x = size.width * (0.18 + 0.64 * phase)
        let bandColors = [palette.above, palette.mid, palette.below, palette.core]

        // Soft floor so the beam still sits on a lit bottom, not a void.
        let floorOpacity = intensity * 0.35
        let floorHeight = max(6, reach * 0.55)
        context.fill(
            Path(CGRect(x: 0, y: edgeY - floorHeight, width: size.width, height: floorHeight)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: palette.mid).opacity(0), location: 0),
                    .init(color: Color(hex: palette.below).opacity(Double(floorOpacity)), location: 1)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: edgeY - floorHeight),
                endPoint: CGPoint(x: size.width / 2, y: edgeY)
            )
        )

        for (offset, hex) in bandColors.enumerated() {
            let scale = 1 - CGFloat(offset) * 0.16
            let radius = max(8, reach * 0.95 * scale)
            let opacity = intensity * (0.5 - CGFloat(offset) * 0.07)
            let color = Color(hex: hex).opacity(Double(max(0, opacity)))
            let rect = CGRect(
                x: x - radius,
                y: edgeY - radius * 0.85,
                width: radius * 2,
                height: radius * 1.2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    center: CGPoint(x: x, y: edgeY - radius * 0.1),
                    startRadius: 0,
                    endRadius: max(1, radius)
                )
            )
        }

        let coreOpacity = min(1, intensity * 0.95)
        let coreRect = CGRect(
            x: x - size.width * 0.07,
            y: edgeY - 3,
            width: size.width * 0.14,
            height: 6
        )
        context.fill(
            Path(ellipseIn: coreRect),
            with: .color(Color(hex: palette.core).opacity(Double(coreOpacity)))
        )
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
