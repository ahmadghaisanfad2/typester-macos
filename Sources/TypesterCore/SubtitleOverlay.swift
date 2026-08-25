import Cocoa
import SwiftUI
import TypesterCore

enum SubtitlePresentationPhase: Equatable {
    case hidden
    case presenting
    case visible
    case dismissing
}

class SubtitleViewModel: ObservableObject {
    @Published var finalText: String = ""
    @Published var interimText: String = ""
    @Published var isActive: Bool = false
    @Published var targetAppName: String = ""
    @Published var targetAppIcon: NSImage?
    @Published var maxCapsuleWidth: CGFloat = 600
    /// Latest per-bar spectral targets (0...1). WaveformIcon springs toward
    /// these at display refresh, so the box is not @Published (no 60 Hz storm).
    fileprivate let spectrumTargets = SpectrumTargetBox(count: SubtitleViewModel.barCount)
    fileprivate static let barCount = 9
    /// When false, hide live transcript text; app name and waveform still show.
    @Published var showStreamPreview: Bool = true
    /// True while waiting for the provider to finalize / return the transcript.
    @Published var isProcessing: Bool = false
    @Published var processingLabel: String = "Transcribing"
    /// True while the pointer is over the pill's interactive area.
    @Published var isHovering: Bool = false
    /// Window/content lifecycle. Kept separate from recording state so dismissal
    /// can finish visually before the borderless window is ordered out.
    @Published var presentationPhase: SubtitlePresentationPhase = .hidden

    var hasText: Bool {
        !finalText.isEmpty || !interimText.isEmpty
    }

    /// Space between finalized and interim text so words never glue together.
    var interimJoiner: String? {
        guard !finalText.isEmpty, !interimText.isEmpty,
              !finalText.hasSuffix(" "), !interimText.hasPrefix(" ") else { return nil }
        return " "
    }

    /// Combined transcript; changes whenever either half changes (scroll key).
    var textRevision: String {
        finalText + "\u{2028}" + interimText
    }

    func show(appName: String, appIcon: NSImage?) {
        finalText = ""
        interimText = ""
        isProcessing = false
        processingLabel = "Transcribing"
        isHovering = false
        targetAppName = appName
        targetAppIcon = appIcon
        spectrumTargets.reset()
        showStreamPreview = SettingsStore.shared.showStreamPreview
        isActive = true
        presentationPhase = .presenting
    }

    func present() {
        presentationPhase = .visible
    }

    func beginDismissal() {
        guard presentationPhase != .hidden else { return }
        isActive = false
        isHovering = false
        presentationPhase = .dismissing
    }

    func finishHide() {
        presentationPhase = .hidden
        isActive = false
        finalText = ""
        interimText = ""
        isProcessing = false
        processingLabel = "Transcribing"
        isHovering = false
        targetAppName = ""
        targetAppIcon = nil
        spectrumTargets.reset()
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

    /// Compact post-stop waiting state (breathing waveform + small label).
    func showProcessing(label: String = "Transcribing") {
        isProcessing = true
        processingLabel = label
        interimText = ""
    }

    func clearProcessing() {
        isProcessing = false
    }

    func clearText() {
        finalText = ""
        interimText = ""
    }

    /// Per-band mic levels from the recorder's FFT; main thread, ~60 Hz.
    func updateSpectrum(_ bands: [Float]) {
        spectrumTargets.update(bands)
    }
}

/// Main-thread holder for the newest per-bar spectrum targets.
final class SpectrumTargetBox {
    private(set) var values: [CGFloat]

    init(count: Int) {
        values = Array(repeating: 0, count: count)
    }

    func update(_ bands: [Float]) {
        for index in values.indices {
            let band = index < bands.count ? bands[index] : 0
            values[index] = CGFloat(min(1, max(0, band)))
        }
    }

    func reset() {
        for index in values.indices { values[index] = 0 }
    }
}

/// Per-bar spring state advanced once per display frame (semi-implicit Euler).
final class BarSimulation {
    private(set) var positions: [CGFloat]
    private var velocities: [CGFloat]
    private var lastTime: TimeInterval?

    /// ωn ≈ 33 rad/s (~0.19 s settle), ζ = 0.85 — quick with a whisper of overshoot.
    private static let stiffness: CGFloat = 1100
    private static let damping: CGFloat = 2 * 0.85 * 1100.squareRoot()

    init(count: Int) {
        positions = Array(repeating: 0, count: count)
        velocities = Array(repeating: 0, count: count)
    }

    func reset() {
        for index in positions.indices {
            positions[index] = 0
            velocities[index] = 0
        }
        lastTime = nil
    }

    func advance(now: TimeInterval, targets: [CGFloat]) {
        let dt = min(max(now - (lastTime ?? now), 0), 1.0 / 30.0)
        lastTime = now
        guard dt > 0 else { return }

        for index in positions.indices {
            let target = index < targets.count ? targets[index] : 0
            let acceleration = Self.stiffness * (target - positions[index]) - Self.damping * velocities[index]
            velocities[index] += acceleration * dt
            positions[index] += velocities[index] * dt
            // A shout must not fling a bar past the frame even for a frame.
            positions[index] = min(1.15, max(0, positions[index]))
        }
    }
}

struct WaveformIcon: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @State private var simulation = BarSimulation(count: SubtitleViewModel.barCount)
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    private static let frameWidth = CGFloat(SubtitleViewModel.barCount) * barWidth
        + CGFloat(SubtitleViewModel.barCount - 1) * barSpacing
    private static let frameHeight: CGFloat = 18
    private static let minBarHeight: CGFloat = 3.5
    private static let levelSpan: CGFloat = 12.5

    var body: some View {
        Group {
            if accessibilityReduceMotion {
                bars(levels: Array(repeating: 0.08, count: SubtitleViewModel.barCount))
            } else {
                TimelineView(.animation(paused: !viewModel.isActive)) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    bars(levels: advanceSimulation(now: now))
                }
            }
        }
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        .accessibilityLabel("Microphone level")
        .onChange(of: viewModel.isActive) { active in
            if active { simulation.reset() }
        }
    }

    /// Steps the springs toward this frame's targets and returns bar positions.
    private func advanceSimulation(now: TimeInterval) -> [CGFloat] {
        simulation.advance(now: now, targets: targets(now: now))
        return simulation.positions
    }

    private func bars(levels: [CGFloat]) -> some View {
        Canvas { context, size in
            var bars = Path()
            for (index, level) in levels.enumerated() {
                let height = Self.minBarHeight + level * Self.levelSpan
                let x = CGFloat(index) * (Self.barWidth + Self.barSpacing)
                bars.addRoundedRect(
                    in: CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: Self.barWidth,
                        height: height
                    ),
                    cornerSize: CGSize(width: Self.barWidth / 2, height: Self.barWidth / 2),
                    style: .continuous
                )
            }

            // Bloom pass: one shared blur whose opacity tracks overall energy.
            var glow = context
            glow.addFilter(.blur(radius: 3.5))
            glow.opacity = 0.10 + 0.34 * min(1, levels.reduce(0, +) / CGFloat(levels.count))
            glow.fill(bars, with: .color(.white))

            // Crisp bars with a soft top-biased gradient.
            context.fill(
                bars,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.98),
                        Color.white.opacity(0.70)
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
    }

    /// Display targets for this frame: live spectrum, processing breath, or idle.
    private func targets(now: TimeInterval) -> [CGFloat] {
        let count = SubtitleViewModel.barCount
        var result = [CGFloat](repeating: 0, count: count)

        if viewModel.isProcessing {
            // Slow traveling wave — "still working" in the waveform's own language.
            for index in 0..<count {
                let phase = sin(now * 2 * .pi / 1.7 - Double(index) * 0.55)
                result[index] = 0.10 + 0.20 * (0.5 + 0.5 * phase)
            }
            return result
        }

        let bands = viewModel.spectrumTargets.values
        for index in 0..<count {
            let band = index < bands.count ? bands[index] : 0
            // Micro idle drift so silence still breathes a little.
            let idle = 0.02 + 0.02 * sin(now * 1.9 + Double(index) * 0.9)
            result[index] = max(band, idle)
        }
        return result
    }
}

struct SubtitleView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    var onCancel: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

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
            .opacity(presentationOpacity)
            .scaleEffect(presentationScale, anchor: .bottom)
            .offset(y: presentationOffset)
            .animation(presentationAnimation, value: viewModel.presentationPhase)
    }

    private var presentationScale: CGFloat {
        switch viewModel.presentationPhase {
        case .hidden: return 0.94
        case .presenting: return 0.88
        case .visible: return 1
        case .dismissing: return 0.94
        }
    }

    private var presentationOpacity: Double {
        viewModel.presentationPhase == .visible ? 1 : 0
    }

    private var presentationOffset: CGFloat {
        switch viewModel.presentationPhase {
        case .hidden: return 8
        case .presenting: return 10
        case .visible: return 0
        case .dismissing: return 9
        }
    }

    private var presentationAnimation: Animation {
        if accessibilityReduceMotion {
            return .easeInOut(duration: 0.16)
        }
        return .spring(response: 0.34, dampingFraction: 0.8, blendDuration: 0.08)
    }

    private var pillContent: some View {
        // Keep the normal content as the sole layout anchor. The cancel action
        // is an overlay so its label can never change the pill's measured size.
        regularContent
            .frame(minHeight: 20)
            .opacity(viewModel.isHovering ? 0 : 1)
            .scaleEffect(viewModel.isHovering ? 0.985 : 1)
            .allowsHitTesting(!viewModel.isHovering)
            .overlay(cancelButton)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.isHovering = isHovering
                }
            }
    }

    private var cancelButton: some View {
        Button {
            onCancel?()
        } label: {
            Label("Cancel", systemImage: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .tracking(0.2)
                // Horizontal padding keeps the label comfortable without
                // adding any height to the existing pill content area.
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        }
        .focuslessButton()
        .contentShape(Capsule())
        .opacity(viewModel.isHovering ? 1 : 0)
        .scaleEffect(viewModel.isHovering ? 1 : 0.985)
        .allowsHitTesting(viewModel.isHovering)
        .accessibilityHidden(!viewModel.isHovering)
        .accessibilityLabel("Cancel transcription")
        .help("Cancel transcription")
    }

    private var regularContent: some View {
        HStack(spacing: 8) {
            if let icon = viewModel.targetAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }

            if viewModel.isProcessing {
                WaveformIcon(viewModel: viewModel)

                Text(viewModel.processingLabel)
                    .font(.mono(10.5, .semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .lineLimit(1)
            } else {
                WaveformIcon(viewModel: viewModel)

                if viewModel.showStreamPreview, viewModel.hasText {
                    transcript
                } else if !viewModel.targetAppName.isEmpty {
                    // Always show the active app name when preview is off or text has not arrived yet.
                    Text(viewModel.targetAppName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                        .tracking(0.1)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Finalized words at full brightness, interim words dimmed — certainty is legible.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    if !viewModel.finalText.isEmpty {
                        Text(viewModel.finalText)
                            .foregroundColor(.white.opacity(0.95))
                    }
                    if let joiner = viewModel.interimJoiner {
                        Text(joiner)
                            .foregroundColor(.white.opacity(0.48))
                    }
                    if !viewModel.interimText.isEmpty {
                        Text(viewModel.interimText)
                            .foregroundColor(.white.opacity(0.48))
                    }
                }
                .font(.system(size: 15))
                .fixedSize()
                .id("text")
            }
            .frame(maxWidth: viewModel.maxCapsuleWidth - 80)
            .onChange(of: viewModel.textRevision) { _ in
                proxy.scrollTo("text", anchor: .trailing)
            }
            .onAppear {
                proxy.scrollTo("text", anchor: .trailing)
            }
        }
    }
}

class SubtitleOverlay {
    static let shared = SubtitleOverlay()

    let viewModel = SubtitleViewModel()
    private var window: NSWindow?
    private var pendingHide: DispatchWorkItem?
    private let dismissalDuration: TimeInterval = 0.36
    var onCancel: (() -> Void)?

    private init() {}

    func show(appName: String, appIcon: NSImage?) {
        DispatchQueue.main.async {
            self.pendingHide?.cancel()
            self.pendingHide = nil
            self.viewModel.maxCapsuleWidth = self.maxCapsuleWidth()
            self.viewModel.show(appName: appName, appIcon: appIcon)
            self.ensureWindow()
            self.window?.orderFront(nil)
            // First lay out the compact starting state, then animate to the
            // resting state on the next runloop. This keeps the shadow and
            // window frame stable while the pill does its small spring pop.
            self.repositionWindow()
            DispatchQueue.main.async {
                guard self.viewModel.presentationPhase == .presenting else { return }
                self.viewModel.present()
                self.repositionWindow()
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.window != nil else {
                self.viewModel.finishHide()
                return
            }

            self.pendingHide?.cancel()
            self.viewModel.beginDismissal()
            self.repositionWindow()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.viewModel.finishHide()
                self.window?.orderOut(nil)
                self.pendingHide = nil
            }
            self.pendingHide = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.dismissalDuration,
                execute: workItem
            )
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

    func showProcessing(label: String = "Transcribing") {
        DispatchQueue.main.async {
            self.viewModel.showProcessing(label: label)
            DispatchQueue.main.async { self.repositionWindow() }
        }
    }

    func showReconnecting() {
        showProcessing(label: "Reconnecting…")
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

    /// Per-band mic levels from the recorder's FFT; any thread, coalesced to main.
    func updateSpectrum(_ bands: [Float]) {
        if Thread.isMainThread {
            viewModel.updateSpectrum(bands)
        } else {
            DispatchQueue.main.async {
                self.viewModel.updateSpectrum(bands)
            }
        }
    }

    /// Debug aid: renders the overlay's content to PNG for visual checks.
    func snapshotForDebug(to path: String) {
        guard let window = window else { return }
        AppDelegate.snapshot(window: window, to: path)
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
