import SwiftUI
import AppKit

/// AppKit-drawn capsule with a single Core Graphics soft shadow.
/// Bakes a real Gaussian fade into the layer so borderless windows cannot clip it.
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

        // Single soft shadow pass (one Gaussian — denser near the pill, fades out).
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -3),
            blur: 20,
            color: NSColor.black.withAlphaComponent(0.24).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        // Gradient fill (no shadow).
        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [
            NSColor(white: 0.22, alpha: 1).cgColor,
            NSColor(white: 0.08, alpha: 1).cgColor,
            NSColor.black.cgColor
        ] as CFArray
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(
                gradient,
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
