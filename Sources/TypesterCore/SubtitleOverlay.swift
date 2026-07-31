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
    /// Recent normalized mic levels (oldest → newest), used by WaveformIcon.
    @Published var audioLevels: [CGFloat] = Array(repeating: 0.08, count: 5)
    /// When false, hide live transcript text; app name and waveform still show.
    @Published var showStreamPreview: Bool = true
    /// True while waiting for the provider to finalize / return the transcript.
    @Published var isProcessing: Bool = false

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
        targetAppName = appName
        targetAppIcon = appIcon
        audioLevels = Array(repeating: 0.08, count: 5)
        showStreamPreview = SettingsStore.shared.showStreamPreview
        isActive = true
    }

    func hide() {
        isActive = false
        finalText = ""
        interimText = ""
        isProcessing = false
        targetAppName = ""
        targetAppIcon = nil
        audioLevels = Array(repeating: 0.08, count: 5)
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
        let clamped = CGFloat(min(1, max(0, level)))
        // Soft floor so idle mic still shows a tiny bar; attack is immediate, decay is gentle.
        let displayed = max(0.08, clamped)
        var next = Array(audioLevels.dropFirst())
        next.append(displayed)
        // Decay older bars slightly so the wave reads left→right with the voice.
        for i in 0..<next.count - 1 {
            next[i] = max(0.08, next[i] * 0.85)
        }
        audioLevels = next
    }
}

struct WaveformIcon: View {
    @ObservedObject var viewModel: SubtitleViewModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let level = index < viewModel.audioLevels.count ? viewModel.audioLevels[index] : 0.08
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 4 + level * 12)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: viewModel.audioLevels)
    }
}

struct SubtitleView: View {
    @ObservedObject var viewModel: SubtitleViewModel

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
        .frame(minHeight: 20)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

class SubtitleOverlay {
    static let shared = SubtitleOverlay()

    let viewModel = SubtitleViewModel()
    private var window: NSWindow?

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
            rootView: SubtitleView(viewModel: viewModel)
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
        window.ignoresMouseEvents = true
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
