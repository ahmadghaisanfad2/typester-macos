import Cocoa
import SwiftUI
import TypesterCore

class SubtitleViewModel: ObservableObject {
    @Published var finalText: String = ""
    @Published var interimText: String = ""
    @Published var isActive: Bool = false
    @Published var targetAppName: String = ""
    @Published var targetAppIcon: NSImage?
    @Published var maxCapsuleWidth: CGFloat = 600
    /// Latest mic envelope target (0...1). WaveformIcon interpolates toward this at display refresh.
    @Published var targetAudioLevel: CGFloat = 0.08
    fileprivate static let barCount = 7
    fileprivate static let levelFloor: CGFloat = 0.08
    /// When false, hide live transcript text; app name and waveform still show.
    @Published var showStreamPreview: Bool = true
    /// True while waiting for the provider to finalize / return the transcript.
    @Published var isProcessing: Bool = false
    /// True while the pointer is over the pill's interactive area.
    @Published var isHovering: Bool = false

    var displayText: String {
        guard showStreamPreview, !isProcessing else { return "" }
        if !finalText.isEmpty && !interimText.isEmpty
            && !finalText.hasSuffix(" ") && !interimText.hasPrefix(" ") {
            return finalText + " " + interimText
        }
        return finalText + interimText
    }

    func show(appName: String, appIcon: NSImage?) {
        finalText = ""
        interimText = ""
        isProcessing = false
        isHovering = false
        targetAppName = appName
        targetAppIcon = appIcon
        targetAudioLevel = Self.levelFloor
        showStreamPreview = SettingsStore.shared.showStreamPreview
        isActive = true
    }

    func hide() {
        isActive = false
        finalText = ""
        interimText = ""
        isProcessing = false
        isHovering = false
        targetAppName = ""
        targetAppIcon = nil
        targetAudioLevel = Self.levelFloor
    }

    func updateFinal(_ text: String) {
        guard showStreamPreview, !isProcessing else { return }
        finalText += text
        interimText = ""
    }

    func updateInterim(_ text: String) {
        guard showStreamPreview, !isProcessing else { return }
        interimText = text
    }

    /// Compact post-stop waiting state (spinner + small label).
    func showProcessing() {
        isProcessing = true
        interimText = ""
    }

    func clearProcessing() {
        isProcessing = false
    }

    func clearText() {
        finalText = ""
        interimText = ""
    }

    func updateAudioLevel(_ level: Float) {
        let sample = CGFloat(min(1, max(0, level)))
        // Fast attack, soft release — display layer interpolates at 60 FPS.
        if sample >= targetAudioLevel {
            targetAudioLevel = sample
        } else {
            targetAudioLevel = targetAudioLevel + (sample - targetAudioLevel) * 0.35
        }
    }
}

struct WaveformIcon: View {
    @ObservedObject var viewModel: SubtitleViewModel
    /// Mutable display envelope without publishing every frame (TimelineView already redraws).
    @State private var displayBox = WaveformDisplayBox()

    /// Compact symmetric weights (keeps the pill short).
    private static let weights: [CGFloat] = [0.45, 0.7, 0.9, 1.0, 0.9, 0.7, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !viewModel.isActive)) { context in
            let displayLevel = advanceDisplay()
            HStack(spacing: 1.5) {
                ForEach(0..<SubtitleViewModel.barCount, id: \.self) { index in
                    let weight = index < Self.weights.count ? Self.weights[index] : 0.5
                    // Light phase motion so bars feel alive without looking random.
                    let phase = sin(context.date.timeIntervalSinceReferenceDate * 10.5 + Double(index) * 0.7)
                    let shimmer = 0.88 + 0.12 * CGFloat(phase)
                    let level = max(SubtitleViewModel.levelFloor, displayLevel * weight * shimmer)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 2, height: 3.5 + level * 12)
                }
            }
            .frame(width: 26, height: 16)
        }
    }

    private func advanceDisplay() -> CGFloat {
        let target = max(SubtitleViewModel.levelFloor, viewModel.targetAudioLevel)
        if target >= displayBox.level {
            displayBox.level = target
        } else {
            displayBox.level += (target - displayBox.level) * 0.28
        }
        return displayBox.level
    }
}

private final class WaveformDisplayBox {
    var level: CGFloat = SubtitleViewModel.levelFloor
}

struct SubtitleView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    var onCancel: (() -> Void)?

    var body: some View {
        // Pad first so SoftShadowPillBackground is large enough for a real CG Gaussian
        // fade; the capsule is drawn inset by the same margins as this padding.
        pillContent
            .padding(.horizontal, 44)
            .padding(.top, 36)
            .padding(.bottom, 44)
            .background(
                SoftShadowPillBackground(
                    cornerRadius: 20,
                    margin: NSEdgeInsets(top: 36, left: 44, bottom: 44, right: 44)
                )
            )
            .fixedSize()
    }

    private var pillContent: some View {
        ZStack {
            regularContent
                // Keep the regular content in the layout while hovering so the
                // window does not resize underneath the pointer and flicker.
                .opacity(viewModel.isHovering ? 0 : 1)
                .allowsHitTesting(!viewModel.isHovering)

            if viewModel.isHovering {
                Button {
                    onCancel?()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel transcription")
                .help("Cancel transcription")
            }
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { isHovering in
            viewModel.isHovering = isHovering
        }
    }

    private var regularContent: some View {
        HStack(spacing: 8) {
            if let icon = viewModel.targetAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }

            if viewModel.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                    .frame(width: 14, height: 14)

                Text("Transcribing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .tracking(0.2)
            } else {
                WaveformIcon(viewModel: viewModel)

                if viewModel.showStreamPreview, !viewModel.displayText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(viewModel.displayText)
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .fixedSize()
                                .id("text")
                        }
                        .frame(maxWidth: viewModel.maxCapsuleWidth - 80)
                        .onChange(of: viewModel.displayText) { _ in
                            proxy.scrollTo("text", anchor: .trailing)
                        }
                        .onAppear {
                            proxy.scrollTo("text", anchor: .trailing)
                        }
                    }
                } else if !viewModel.targetAppName.isEmpty {
                    // Always show the active app name when preview is off or text has not arrived yet.
                    Text(viewModel.targetAppName)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }
}

class SubtitleOverlay {
    static let shared = SubtitleOverlay()

    let viewModel = SubtitleViewModel()
    private var window: NSWindow?
    var onCancel: (() -> Void)?

    private init() {}

    func show(appName: String, appIcon: NSImage?) {
        DispatchQueue.main.async {
            self.viewModel.maxCapsuleWidth = self.maxCapsuleWidth()
            self.viewModel.show(appName: appName, appIcon: appIcon)
            self.ensureWindow()
            self.window?.orderFront(nil)
            // Next runloop: SwiftUI has applied @Published changes before we measure.
            DispatchQueue.main.async { self.repositionWindow() }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.viewModel.hide()
            self.window?.orderOut(nil)
        }
    }

    func updateFinal(_ text: String) {
        DispatchQueue.main.async {
            guard self.viewModel.showStreamPreview else { return }
            self.viewModel.updateFinal(text)
            DispatchQueue.main.async { self.repositionWindow() }
        }
    }

    func updateInterim(_ text: String) {
        DispatchQueue.main.async {
            guard self.viewModel.showStreamPreview else { return }
            self.viewModel.updateInterim(text)
            DispatchQueue.main.async { self.repositionWindow() }
        }
    }

    func showProcessing() {
        DispatchQueue.main.async {
            self.viewModel.showProcessing()
            DispatchQueue.main.async { self.repositionWindow() }
        }
    }

    func clearProcessing() {
        DispatchQueue.main.async {
            self.viewModel.clearProcessing()
            DispatchQueue.main.async { self.repositionWindow() }
        }
    }

    func clearText() {
        DispatchQueue.main.async {
            self.viewModel.clearText()
            DispatchQueue.main.async { self.repositionWindow() }
        }
    }

    func updateAudioLevel(_ level: Float) {
        // Already expected on main from AudioRecorder; keep hop cheap.
        if Thread.isMainThread {
            viewModel.updateAudioLevel(level)
        } else {
            DispatchQueue.main.async {
                self.viewModel.updateAudioLevel(level)
            }
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        viewModel.maxCapsuleWidth = maxCapsuleWidth()
        let hosting = NSHostingView(
            rootView: SubtitleView(
                viewModel: viewModel,
                onCancel: { [weak self] in self?.onCancel?() }
            )
        )

        let window = NSWindow(
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
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        hosting.clipsToBounds = false
        window.contentView = hosting

        self.window = window
    }

    private func maxCapsuleWidth() -> CGFloat {
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        return screenWidth * 0.4
    }

    private func repositionWindow() {
        guard let window = window,
              let screen = NSScreen.main,
              let hosting = window.contentView as? NSHostingView<SubtitleView> else { return }

        let maxWidth = maxCapsuleWidth()
        if abs(viewModel.maxCapsuleWidth - maxWidth) > 0.5 {
            viewModel.maxCapsuleWidth = maxWidth
        }

        // Do not replace hosting.rootView — that remounts WaveformIcon and breaks animation.
        hosting.layoutSubtreeIfNeeded()

        let fittingSize = hosting.fittingSize
        guard fittingSize.width > 0 && fittingSize.height > 0 else { return }

        let shadowPad: CGFloat = 68
        let width = min(fittingSize.width, maxWidth + shadowPad)
        let height = fittingSize.height

        let x = screen.frame.midX - width / 2
        // Extra bottom padding is for the baked shadow fade; keep the capsule near the dock.
        let y = screen.frame.minY + 48
        let newFrame = NSRect(origin: NSPoint(x: x, y: y), size: NSSize(width: width, height: height))

        Debug.log("Overlay reposition: x=\(Int(x)) y=\(Int(y)) w=\(Int(width)) h=\(Int(height))")

        window.setFrame(newFrame, display: true)
    }
}
