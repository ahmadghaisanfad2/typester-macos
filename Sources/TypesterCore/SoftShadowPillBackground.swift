import SwiftUI
import AppKit

/// AppKit-drawn capsule with Core Graphics depth and a hairline top highlight.
/// Bakes real Gaussian fades into the layer so borderless windows cannot clip them.
final class SoftShadowPillNSView: NSView {
    var cornerRadius: CGFloat = 20
    /// When true the capsule is a stadium: the radius follows the *current*
    /// height at draw time. A radius passed in cannot be animated — it is read
    /// once per layout, not interpolated — so a resize animation with a fixed
    /// radius draws a big shape with the small shape's corners, which reads as
    /// a rectangle. Deriving it from the bounds keeps the ends round throughout.
    var isStadium: Bool = false
    /// Clear margin around the capsule where the shadow may fade.
    var margin: NSEdgeInsets = NSEdgeInsets(top: 36, left: 44, bottom: 44, right: 44)
    /// Multiplies both shadow blurs and offsets. Smaller pills need a tighter
    /// shadow so the fade still fits inside their (much smaller) margin.
    var shadowScale: CGFloat = 1
    /// When true (Voice glow active): flat dark fill, no glass rim — keeps the
    /// in-capsule glow fluid instead of cutting it with a bright edge plate.
    var glowFill: Bool = false

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        clipsToBounds = false
        // Redraw while a layout animation resizes the view, so a stadium
        // radius keeps following the height instead of being stretched.
        layer?.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let pill = CGRect(
            x: margin.left,
            y: margin.bottom,
            width: max(0, bounds.width - margin.left - margin.right),
            height: max(0, bounds.height - margin.top - margin.bottom)
        )
        guard pill.width > 1, pill.height > 1 else { return }

        let radius = isStadium ? pill.height / 2 : cornerRadius
        let path = CGPath(
            roundedRect: pill,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        // Two shadow passes: a wide ambient occlusion plus a tighter key shadow.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -7 * shadowScale),
            blur: 24 * shadowScale,
            color: NSColor.black.withAlphaComponent(0.28).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2 * shadowScale),
            blur: 9 * shadowScale,
            color: NSColor.black.withAlphaComponent(0.20).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        // Interior fill
        if glowFill {
            // Shadows only. The Voice glow canvas IS the capsule interior —
            // no separate dark/glass plate behind the app name or waveform.
        } else {
            // Cool graphite glass fill — a touch of blue so it reads as hardware,
            // not flat black, and still sits quietly over any app.
            context.saveGState()
            context.addPath(path)
            context.clip()
            let space = CGColorSpaceCreateDeviceRGB()
            let fill = [
                NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1).cgColor,
                NSColor(srgbRed: 0.085, green: 0.09, blue: 0.10, alpha: 1).cgColor,
                NSColor(srgbRed: 0.03, green: 0.032, blue: 0.04, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: fill, locations: [0, 0.55, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: pill.midX, y: pill.maxY),
                    end: CGPoint(x: pill.midX, y: pill.minY),
                    options: []
                )
            }
            context.restoreGState()

            // Hairline highlight: convert the edge to a stroke-shaped clip and fill
            // it with a top-biased white gradient (the classic macOS glass rim).
            // Skipped when glowFill is true so the Voice/border beam is not cut.
            context.saveGState()
            context.addPath(path)
            context.setLineWidth(1)
            context.replacePathWithStrokedPath()
            context.clip()
            let rim = [
                NSColor.white.withAlphaComponent(0.16).cgColor,
                NSColor.white.withAlphaComponent(0.05).cgColor,
                NSColor.white.withAlphaComponent(0.01).cgColor
            ] as CFArray
            if let rimGradient = CGGradient(colorsSpace: space, colors: rim, locations: [0, 0.45, 1]) {
                context.drawLinearGradient(
                    rimGradient,
                    start: CGPoint(x: pill.midX, y: pill.maxY),
                    end: CGPoint(x: pill.midX, y: pill.minY),
                    options: []
                )
            }
            context.restoreGState()
        }
    }
}

struct SoftShadowPillBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 20
    /// Stadium ends: the radius follows the current height, so it survives a
    /// resize animation.
    var isStadium: Bool = false
    var margin: NSEdgeInsets = NSEdgeInsets(top: 36, left: 44, bottom: 44, right: 44)
    var shadowScale: CGFloat = 1
    var glowFill: Bool = false

    func makeNSView(context: Context) -> SoftShadowPillNSView {
        let view = SoftShadowPillNSView()
        view.cornerRadius = cornerRadius
        view.isStadium = isStadium
        view.margin = margin
        view.shadowScale = shadowScale
        view.glowFill = glowFill
        return view
    }

    func updateNSView(_ nsView: SoftShadowPillNSView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.isStadium = isStadium
        nsView.margin = margin
        nsView.shadowScale = shadowScale
        nsView.glowFill = glowFill
        nsView.needsDisplay = true
    }
}
