import AppKit
import SwiftUI
import TypesterCore

/// Persistent Wispr Flow–style floating pill.
///
/// Click to start dictation; click again to stop. Draggable around the screen,
/// follows the active Space, and reflects recording / processing state.
final class FloatingDictationPill {
    static let shared = FloatingDictationPill()

    var onToggleDictation: (() -> Void)?
    var onCancelDictation: (() -> Void)?

    private var window: NSWindow?
    private var hosting: NSHostingView<FloatingDictationPillView>?
    private let viewModel = FloatingPillViewModel()
    private let spaceObserver = SpaceFollowingWindow.SpaceObserver()
    private var isVisible = false

    private init() {}

    func showIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if SettingsStore.shared.showFloatingPill {
                self.show()
            } else {
                self.hide()
            }
        }
    }

    func show() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let root = FloatingDictationPillView(
                model: self.viewModel,
                onToggle: { [weak self] in self?.onToggleDictation?() },
                onCancel: { [weak self] in self?.onCancelDictation?() }
            )
            let hosting = NSHostingView(rootView: root)
            self.hosting = hosting

            let window: NSWindow
            if let existing = self.window {
                window = existing
                window.contentView = hosting
            } else {
                window = DraggableHUDWindow(
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
            self.isVisible = true

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.isVisible = false
            self.spaceObserver.stop()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }
    }

    func setRecording(_ recording: Bool, appName: String = "") {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.isRecording = recording
            self?.viewModel.targetAppName = recording ? appName : ""
            self?.viewModel.isProcessing = false
        }
    }

    func setProcessing(_ processing: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.isProcessing = processing
            if processing {
                self?.viewModel.isRecording = false
            }
        }
    }

    private func layout(window: NSWindow, hosting: NSHostingView<FloatingDictationPillView>) {
        let fitting = hosting.fittingSize
        guard fitting.width > 0, fitting.height > 0,
              let screen = NSScreen.main else { return }

        // Preserve a previously dragged position; otherwise dock bottom-right.
        if window.frame.width < 1 || window.frame.height < 1 {
            let x = screen.visibleFrame.maxX - fitting.width - 28
            let y = screen.visibleFrame.minY + 96
            window.setFrame(NSRect(x: x, y: y, width: fitting.width, height: fitting.height), display: true)
        } else {
            let origin = window.frame.origin
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: fitting.width, height: fitting.height), display: true)
        }
    }

    private func beginSpaceFollowing() {
        spaceObserver.start(
            shouldReassert: { [weak self] in
                self?.isVisible == true
            },
            handler: { [weak self] in
                guard let self, let window = self.window,
                      let hosting = self.hosting else { return }
                SpaceFollowingWindow.reaffirm(window)
                self.layout(window: window, hosting: hosting)
            }
        )
    }
}

// MARK: - View model

final class FloatingPillViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var targetAppName = ""
    @Published var isHovering = false
}

// MARK: - Window that lets SwiftUI content handle clicks while remaining movable

final class DraggableHUDWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Pill view

struct FloatingDictationPillView: View {
    @ObservedObject var model: FloatingPillViewModel
    let onToggle: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecording ? Color(hex: 0xE5484D) : Codex.green)
                .frame(width: 8, height: 8)
                .shadow(
                    color: (model.isRecording ? Color(hex: 0xE5484D) : Codex.green)
                        .opacity(model.isRecording ? 0.7 : 0.35),
                    radius: model.isRecording ? 5 : 2
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(model.isProcessing ? "Transcribing" : (model.isRecording ? "Listening" : "Typester"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))

                if !model.targetAppName.isEmpty, model.isRecording {
                    Text(model.targetAppName)
                        .font(.mono(9.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            if model.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
            } else {
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.84))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        )
        .contentShape(Capsule())
        .onHover { hovering in
            model.isHovering = hovering
        }
        .scaleEffect(model.isHovering ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.12), value: model.isHovering)
        .onTapGesture {
            onToggle()
        }
        .contextMenu {
            if model.isRecording {
                Button("Cancel Dictation") {
                    onCancel()
                }
            }
            Button("Hide Pill") {
                SettingsStore.shared.showFloatingPill = false
            }
        }
        .help(model.isRecording ? "Click to stop dictation" : "Click to start dictation")
        .fixedSize()
    }
}
