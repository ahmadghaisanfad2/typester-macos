import SwiftUI
import AppKit

/// AppKit-drawn capsule with Core Graphics depth and a hairline top highlight.
/// Bakes real Gaussian fades into the layer so borderless windows cannot clip them.
final class SoftShadowPillNSView: NSView {
    var cornerRadius: CGFloat = 20
    /// Clear margin around the capsule where the shadow may fade.
    var margin: NSEdgeInsets = NSEdgeInsets(top: 36, left: 44, bottom: 44, right: 44)

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        clipsToBounds = false
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

        let path = CGPath(
            roundedRect: pill,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // Two shadow passes: a wide ambient occlusion plus a tighter key shadow.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -7),
            blur: 24,
            color: NSColor.black.withAlphaComponent(0.28).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 9,
            color: NSColor.black.withAlphaComponent(0.20).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

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

struct SoftShadowPillBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 20
    var margin: NSEdgeInsets = NSEdgeInsets(top: 36, left: 44, bottom: 44, right: 44)

    func makeNSView(context: Context) -> SoftShadowPillNSView {
        let view = SoftShadowPillNSView()
        view.cornerRadius = cornerRadius
        view.margin = margin
        return view
    }

    func updateNSView(_ nsView: SoftShadowPillNSView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.margin = margin
        nsView.needsDisplay = true
    }
}
