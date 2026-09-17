import SwiftUI
import TypesterCore

/// Libraries.dev Voice-style bottom-edge glow for Typester overlays.
///
/// Drawn as a non-interactive Canvas above the capsule: multi-lobe colorful
/// bloom that rises with voice energy; when `frame.beamPhase` is set, a
/// concentrated core travels left → right along the bottom edge.
struct VoiceGlowBeamView: View {
    var frame: VoiceGlowFrame
    var palette: VoiceGlowPalette = .colorful
    var config: VoiceGlowConfig = .default
    /// Capsule corner radius used to tuck lobes under the bottom edge.
    var cornerRadius: CGFloat = 14
    /// Extra visual height above the bottom edge for bloom reach.
    var bloomHeight: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Canvas { context, size in
            guard frame.intensity > 0.01, size.width > 4, size.height > 4 else { return }

            let intensity = CGFloat(min(1, frame.intensity))
            let level = CGFloat(min(1, frame.level))
            let isBeam = frame.beamPhase != nil && !accessibilityReduceMotion
            let phase = CGFloat(frame.beamPhase ?? 0.5)

            // Bottom edge sits near the lower third so glow hugs the capsule.
            let edgeY = size.height * 0.72
            let spread = CGFloat(max(0.15, config.spread))
            let reach = CGFloat(max(0.2, config.reach)) * bloomHeight * (0.35 + 0.65 * level)

            if isBeam {
                drawTravelingBeam(
                    context: context,
                    size: size,
                    phase: phase,
                    edgeY: edgeY,
                    intensity: intensity,
                    reach: reach
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

        for (index, hex) in lobes.enumerated() {
            let t = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            // Center-weighted: middle lobes sit slightly higher / brighter.
            let centerWeight = 1 - abs(t - 0.5) * 2
            let x = size.width * (0.5 + (t - 0.5) * spread)
            let lobeRadius = reach * (0.55 + 0.45 * centerWeight) * (0.5 + 0.5 * level)
            let opacity = intensity * (0.28 + 0.55 * centerWeight) * (0.45 + 0.55 * level)
            let color = Color(hex: hex).opacity(Double(min(1, opacity)))

            let rect = CGRect(
                x: x - lobeRadius * 1.35,
                y: edgeY - lobeRadius,
                width: lobeRadius * 2.7,
                height: lobeRadius * 2.2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    center: CGPoint(x: x, y: edgeY),
                    startRadius: 0,
                    endRadius: max(1, lobeRadius * 1.2)
                )
            )
        }

        // Core highlight band along the bottom edge.
        let coreOpacity = intensity * (0.2 + 0.5 * level)
        let coreHeight = max(3, reach * 0.35)
        let coreRect = CGRect(
            x: size.width * 0.5 - size.width * spread * 0.45,
            y: edgeY - coreHeight * 0.3,
            width: size.width * spread * 0.9,
            height: coreHeight
        )
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [
                    Color(hex: palette.core).opacity(Double(min(1, coreOpacity))),
                    Color(hex: palette.mid).opacity(Double(coreOpacity * 0.35)),
                    Color(hex: palette.core).opacity(0)
                ]),
                center: CGPoint(x: coreRect.midX, y: coreRect.midY),
                startRadius: 0,
                endRadius: max(1, coreRect.width * 0.55)
            )
        )

        // Soft below-edge wash so the glow reads as attached, not floating.
        let wash = Color(hex: palette.below).opacity(Double(intensity * 0.22 * (0.4 + 0.6 * level)))
        let washRect = CGRect(
            x: size.width * (0.5 - spread * 0.55),
            y: edgeY - 2,
            width: size.width * spread * 1.1,
            height: max(6, bloomHeight * 0.45)
        )
        context.fill(
            Path(ellipseIn: washRect),
            with: .radialGradient(
                Gradient(colors: [wash, wash.opacity(0)]),
                center: CGPoint(x: washRect.midX, y: washRect.minY),
                startRadius: 0,
                endRadius: max(1, washRect.height)
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
        let x = size.width * (0.08 + 0.84 * phase)
        let bandColors = [palette.above, palette.mid, palette.below, palette.core]

        for (offset, hex) in bandColors.enumerated() {
            let scale = 1 - CGFloat(offset) * 0.18
            let radius = max(6, reach * 1.35 * scale)
            let opacity = intensity * (0.55 - CGFloat(offset) * 0.08)
            let color = Color(hex: hex).opacity(Double(max(0, opacity)))
            let rect = CGRect(
                x: x - radius,
                y: edgeY - radius * 0.55,
                width: radius * 2,
                height: radius * 1.3
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    center: CGPoint(x: x, y: edgeY),
                    startRadius: 0,
                    endRadius: max(1, radius)
                )
            )
        }

        // Thin bright core streak.
        let coreOpacity = min(1, intensity * 0.95)
        let coreRect = CGRect(
            x: x - size.width * 0.06,
            y: edgeY - 2,
            width: size.width * 0.12,
            height: 5
        )
        context.fill(
            Path(ellipseIn: coreRect),
            with: .color(Color(hex: palette.core).opacity(Double(coreOpacity)))
        )
    }
}

// MARK: - Shared overlay helper

extension VoiceGlowBeamView {
    /// Capsule-bottom glow layer sized to the parent, with room for bloom bleed.
    static func capsuleOverlay(
        frame: VoiceGlowFrame,
        palette: VoiceGlowPalette = .colorful,
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
            bloomHeight: 26
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.top, 2)
        // Bleed below the capsule so lobes are not clipped by layout bounds.
        .padding(.bottom, 10)
        .offset(y: 6)
    }
}
