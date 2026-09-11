import AppKit
import SwiftUI
import TypesterCore

/// Shotbase-style floating helper that sits above System Settings while the
/// user grants Accessibility. Shows a short instruction and a draggable app
/// icon — the user drops it straight onto the permission list.
final class AccessibilityDragHelper {
    static let shared = AccessibilityDragHelper()

    private var window: NSWindow?
    private var hideWorkItem: DispatchWorkItem?
    private let spaceObserver = SpaceFollowingWindow.SpaceObserver()
    private var isPresented = false

    private init() {}

    /// Present the helper. Hides automatically once Accessibility is granted
    /// or after `autoHideSeconds` (pass 0 to keep until dismissed/granted).
    func show(autoHideSeconds: TimeInterval = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !TextPaster.checkAccessibilityPermission() else { return }
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                Debug.log("Skipping accessibility drag helper — not running from a .app bundle")
                return
            }

            self.hideWorkItem?.cancel()

            let root = AccessibilityDragHelperView(
                onDismiss: { [weak self] in self?.hide() },
                onOpenSettings: {
                    TextPaster.requestAccessibilityPermission()
                    TextPaster.openAccessibilitySettings()
                }
            )
            let hosting = NSHostingView(rootView: root)

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
                window.isMovableByWindowBackground = true
                SpaceFollowingWindow.configure(window)
                window.isMovable = true
                window.ignoresMouseEvents = false
                window.contentView = hosting
                self.window = window
            }

            window.alphaValue = 0
            SpaceFollowingWindow.reaffirm(window)
            self.layout(window: window, hosting: hosting)
            self.beginSpaceFollowing()
            self.isPresented = true

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }

            self.pollForGrant()

            if autoHideSeconds > 0 {
                let work = DispatchWorkItem { [weak self] in
                    self?.hide()
                }
                self.hideWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + autoHideSeconds, execute: work)
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.hideWorkItem?.cancel()
            self.isPresented = false
            self.spaceObserver.stop()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }
    }

    private func pollForGrant() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.isPresented else {
                timer.invalidate()
                return
            }
            if TextPaster.checkAccessibilityPermission() {
                timer.invalidate()
                // Brief pause so the user sees the list toggle flip.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.hide()
                }
            }
        }
    }

    private func layout(window: NSWindow, hosting: NSHostingView<AccessibilityDragHelperView>) {
        let fitting = hosting.fittingSize
        guard fitting.width > 0, fitting.height > 0,
              let screen = NSScreen.main else { return }
        // Center near the lower third — above the permission list in System Settings.
        let frame = NSRect(
            x: screen.visibleFrame.midX - fitting.width / 2,
            y: screen.visibleFrame.minY + 140,
            width: fitting.width,
            height: fitting.height
        )
        window.setFrame(frame, display: true)
    }

    private func beginSpaceFollowing() {
        spaceObserver.start(
            shouldReassert: { [weak self] in
                self?.isPresented == true
            },
            handler: { [weak self] in
                guard let self, let window = self.window,
                      let hosting = window.contentView as? NSHostingView<AccessibilityDragHelperView> else { return }
                SpaceFollowingWindow.reaffirm(window)
                self.layout(window: window, hosting: hosting)
            }
        )
    }
}

// MARK: - Helper UI

struct AccessibilityDragHelperView: View {
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("Drag Typester to the list above to allow Accessibility")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                DraggableAppIconTile()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Typester")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Button("Open System Settings", action: onOpenSettings)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0x6EB6FF))
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .padding(14)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        )
        .fixedSize()
    }
}
