import SwiftUI
import AppKit

/// Tiny transient toast confirming an automatically-learned correction.
/// Appears near the bottom of the screen (like the subtitle pill) and fades
/// out on its own; never takes focus or input. All entry points hop to the
/// main thread internally, so it is callable from any context.
final class LearningHUD {
    static let shared = LearningHUD()

    private var window: NSWindow?
    private var hideWorkItem: DispatchWorkItem?
    private let visibleDuration: TimeInterval = 2.2
    private let dismissalDuration: TimeInterval = 0.28

    private init() {}

    func show(corrections: [DetectedCorrection]) {
        guard !corrections.isEmpty else { return }
        let label: String
        if corrections.count == 1 {
            label = "Learned “\(corrections[0].right)”"
        } else {
            label = "Learned \(corrections.count) corrections"
        }
        show(text: label)
    }

    func show(text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hideWorkItem?.cancel()

            let hosting = NSHostingView(rootView: LearningHUDView(text: text))

            let window: NSWindow
            if let existing = self.window {
                window = existing
                window.contentView = hosting
            } else {
                window = NSWindow(
                    contentRect: .zero,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .stationary]
                window.ignoresMouseEvents = true
                window.contentView = hosting
                self.window = window
            }

            // Size to the fitted capsule and center it near the bottom of the
            // main screen, above where the dictation pill sits.
            let fitting = hosting.fittingSize
            guard fitting.width > 0, fitting.height > 0,
                  let screen = NSScreen.main else { return }
            let frame = NSRect(
                x: screen.frame.midX - fitting.width / 2,
                y: screen.frame.minY + 110,
                width: fitting.width,
                height: fitting.height
            )
            window.setFrame(frame, display: true)
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().alphaValue = 1
            }

            let hide = DispatchWorkItem { [weak self] in
                self?.dismiss()
            }
            self.hideWorkItem = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + self.visibleDuration, execute: hide)
        }
    }

    private func dismiss() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = dismissalDuration
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }
}

private struct LearningHUDView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Codex.green)

            Text(text)
                .font(.mono(11, .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
        )
        .fixedSize()
    }
}
