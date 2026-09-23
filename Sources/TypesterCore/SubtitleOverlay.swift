import Cocoa
import QuartzCore
import SwiftUI
import TypesterCore

enum SubtitlePresentationPhase: Equatable {
    case hidden
    /// Resting state of the floating pill: a small idle capsule on screen,
    /// click to start dictation. Only used when `showFloatingPill` is on.
    case collapsed
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
    /// Voice-glow mic level + processing flags; sampled on TimelineView.
    let voiceGlow = VoiceGlowTargetBox()
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
    /// Morph position of the single HUD: 0 = resting pill, 1 = expanded caption.
    /// Drives the capsule size, the shell opacity and the caption crossfade, so
    /// the transition grows in place instead of resizing the window under a
    /// fixed-size content.
    @Published var morph: Double = 0
    /// Natural (unclipped) size of the caption content, measured by the view.
    /// The controller sizes the window from this so the shell can never outgrow
    /// its window mid-morph.
    @Published var captionContentSize: CGSize = .zero

    var hasText: Bool {
        !finalText.isEmpty || !interimText.isEmpty
    }

    /// Join style for finalized deltas, matching the active provider. Soniox
    /// tokens carry their own word-boundary spacing; Deepgram spans do not.
    private var joinStyle: TranscriptTokenJoinStyle {
        SettingsStore.shared.sttProvider.transcriptJoinStyle
    }

    /// Space between finalized and interim text so words never glue together.
    /// Concatenate providers already carry their own spacing.
    var interimJoiner: String? {
        guard joinStyle == .spaceBetweenUnpadded else { return nil }
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
        voiceGlow.reset()
        voiceGlow.setActive(true)
        showStreamPreview = SettingsStore.shared.showStreamPreview
        isActive = true
        presentationPhase = .visible
    }

    func beginDismissal() {
        guard presentationPhase != .hidden else { return }
        isActive = false
        isHovering = false
        voiceGlow.setActive(false)
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
        voiceGlow.reset()
    }

    /// Morph the expanded caption back into the resting pill, keeping the
    /// window on screen. Used instead of `finishHide()` when the floating pill
    /// is enabled, so the HUD never disappears between dictations.
    func collapse() {
        isActive = false
        isProcessing = false
        processingLabel = "Transcribing"
        isHovering = false
        finalText = ""
        interimText = ""
        targetAppName = ""
        targetAppIcon = nil
        spectrumTargets.reset()
        voiceGlow.setProcessing(false)
        voiceGlow.reset()
        presentationPhase = .collapsed
    }

    func updateFinal(_ text: String) {
        guard showStreamPreview, !isProcessing else { return }
        finalText = TranscriptJoinPolicy.join(left: finalText, right: text, style: joinStyle)
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
        voiceGlow.setProcessing(true)
        voiceGlow.setActive(true)
    }

    func clearProcessing() {
        isProcessing = false
        voiceGlow.setProcessing(false)
        // Caption stays visible briefly after processing; keep glow until hide.
        voiceGlow.setActive(isActive)
    }

    func clearText() {
        finalText = ""
        interimText = ""
    }

    /// Per-band mic levels from the recorder's FFT; main thread, ~60 Hz.
    func updateSpectrum(_ bands: [Float]) {
        spectrumTargets.update(bands)
    }

    /// Overall mic level 0…1 for the Voice glow; main thread, ~60 Hz.
    func updateLevel(_ level: Float) {
        voiceGlow.update(level: level)
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

            // Bars only — no dim plate / wash behind them, so the Voice glow
            // reads as continuous under the waveform.
            context.fill(
                bars,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.98),
                        Color.white.opacity(0.72)
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
    var onToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fired when the caption's natural size changes, so the controller can
    /// resize the window to match before the shell ever outgrows it.
    var onContentSizeChange: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    /// One inset set for both states. The anchor is derived from the capsule
    /// plus these insets, so sharing them keeps the capsule's anchored edge on
    /// the same screen point whether the pill is resting or expanded — that is
    /// what lets the morph grow in place instead of drifting across the screen.
    static let insets = PillInsets(top: 26, left: 34, bottom: 32, right: 34)
    static let restingCapsule = CGSize(width: 44, height: 24)
    static let expandedCornerRadius: CGFloat = 20
    /// The resting pill is deliberately faint; hovering lifts it so it stays
    /// discoverable without shouting.
    static let restingOpacity: Double = 0.34
    static let hoverOpacity: Double = 0.9
    /// Floor that leaves room for the Stop / Cancel buttons revealed on hover.
    static let captionMinWidth: CGFloat = 200

    var body: some View {
        shell
            // Fill the window and pin the shell to its bottom-centre: any
            // mismatch between content and window then crops the top/sides
            // instead of sliding the capsule diagonally.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(CaptionSizeKey.self) { size in
                guard size.width > 1, size.height > 1 else { return }
                guard abs(size.width - viewModel.captionContentSize.width) > 0.5
                    || abs(size.height - viewModel.captionContentSize.height) > 0.5 else { return }
                viewModel.captionContentSize = size
                onContentSizeChange?()
            }
    }

    private var morph: CGFloat { CGFloat(viewModel.morph) }
    private var isExpanded: Bool { viewModel.morph > 0.5 }

    /// The caption only materialises once the shell has most of its size, so the
    /// growth reads as an inflating capsule rather than text sprouting mid-way.
    private var captionOpacity: Double {
        min(1, max(0, (viewModel.morph - 0.3) / 0.7))
    }

    /// The resting pill inflating into the measured caption.
    private var capsuleSize: CGSize {
        let target = CGSize(
            width: max(Self.restingCapsule.width, viewModel.captionContentSize.width),
            height: max(Self.restingCapsule.height, viewModel.captionContentSize.height)
        )
        return CGSize(
            width: Self.restingCapsule.width + (target.width - Self.restingCapsule.width) * morph,
            height: Self.restingCapsule.height + (target.height - Self.restingCapsule.height) * morph
        )
    }

    private var cornerRadius: CGFloat {
        min(capsuleSize.height / 2, Self.expandedCornerRadius)
    }

    private var shellOpacity: Double {
        let resting = viewModel.isHovering ? Self.hoverOpacity : Self.restingOpacity
        return resting + (1 - resting) * viewModel.morph
    }

    private var shell: some View {
        // The resting pill has no content of its own — the capsule shell is all
        // there is, and `.frame` below is what sizes it. The caption is laid out
        // at its natural size and the frame crops it from the centre, so the bar
        // inflates in place instead of reflowing.
        captionContent
            .fixedSize()
            .background(captionSizeReader)
            .opacity(captionOpacity)
            .allowsHitTesting(isExpanded)
            .frame(width: capsuleSize.width, height: capsuleSize.height)
            // Clip to the capsule itself, not a rectangle, so content never pokes
            // through the rounded ends while the shell is growing.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Hit area is the capsule too: the transparent shadow bleed around it
            // must not start dictation.
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.18)) { viewModel.isHovering = hovering }
            }
            .onTapGesture { if !isExpanded { onToggle?() } }
            .contextMenu {
                if viewModel.isActive {
                    Button("Cancel Dictation") { onCancel?() }
                }
                Button("Hide Pill") { SettingsStore.shared.showFloatingPill = false }
            }
            .help(isExpanded ? "Dictating — hover for Stop or Cancel" : "Click to start dictation")
            .padding(.top, Self.insets.top)
            .padding(.leading, Self.insets.left)
            .padding(.bottom, Self.insets.bottom)
            .padding(.trailing, Self.insets.right)
            .background(
                SoftShadowPillBackground(
                    cornerRadius: cornerRadius,
                    margin: Self.insets.edgeInsets,
                    // Tighter shadow for the small resting pill; full depth once
                    // the caption is expanded.
                    shadowScale: 0.5 + 0.5 * morph,
                    // Flat dark plate while dictating so the in-capsule glow
                    // (and border beam) is continuous — no glass rim cut.
                    glowFill: viewModel.isActive || viewModel.isProcessing
                )
            )
            .opacity(shellOpacity)
            .fixedSize()
    }

    private var captionSizeReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CaptionSizeKey.self, value: proxy.size)
        }
    }

    private var captionContent: some View {
        pillContent
            .frame(minWidth: Self.captionMinWidth)
            .background {
                voiceGlowLayer
            }
    }

    @ViewBuilder
    private var voiceGlowLayer: some View {
        if viewModel.isActive {
            TimelineView(.animation(paused: !viewModel.isActive)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let frame = viewModel.voiceGlow.frame(at: now)
                VoiceGlowBeamView.capsuleBackground(
                    frame: frame,
                    palette: .colorful,
                    reachFraction: 0.7,
                    reduceMotion: accessibilityReduceMotion
                )
            }
            // Match SoftShadowPillBackground's inset capsule so the border beam
            // rides the true inner edge.
            .clipShape(RoundedRectangle(cornerRadius: Self.expandedCornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    private var pillContent: some View {
        // Keep the normal content as the sole layout anchor. The actions are an
        // overlay so their labels can never change the caption's measured size.
        regularContent
            .frame(minHeight: 20)
            .opacity(viewModel.isHovering ? 0 : 1)
            .scaleEffect(viewModel.isHovering ? 0.985 : 1)
            .allowsHitTesting(!viewModel.isHovering)
            .overlay(actionButtons)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
    }

    /// Revealed while the pointer is over the caption: finish (paste) or discard.
    private var actionButtons: some View {
        HStack(spacing: 8) {
            actionButton("Stop", systemImage: "stop.fill", isPrimary: true) { onStop?() }
            actionButton("Cancel", systemImage: "xmark", isPrimary: false) { onCancel?() }
        }
        .opacity(viewModel.isHovering ? 1 : 0)
        .scaleEffect(viewModel.isHovering ? 1 : 0.985)
        .allowsHitTesting(viewModel.isHovering)
        .accessibilityHidden(!viewModel.isHovering)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .tracking(0.2)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(isPrimary ? 0.20 : 0.10), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(isPrimary ? 0.28 : 0.16),
                        lineWidth: 1
                    )
                )
        }
        .focuslessButton()
        .contentShape(Capsule())
        .accessibilityLabel(isPrimary ? "Stop dictation" : "Cancel dictation")
        .help(isPrimary ? "Stop and paste the transcript" : "Discard this dictation")
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

/// Size of the caption content at its natural (unclipped) layout.
private struct CaptionSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

class SubtitleOverlay {
    static let shared = SubtitleOverlay()

    let viewModel = SubtitleViewModel()
    private var window: NSWindow?
    private var pendingHide: DispatchWorkItem?
    /// Shrinks the window back to pill size once the collapse morph has landed.
    private var pendingShrink: DispatchWorkItem?
    /// Must outlast `morphAnimation`, so the window is not resized mid-morph.
    private let morphDuration: TimeInterval = 0.34
    private static let morphAnimation: Animation = .spring(response: 0.28, dampingFraction: 1)
    private let spaceObserver = SpaceFollowingWindow.SpaceObserver()
    private var screenParametersToken: NSObjectProtocol?
    var onToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private init() {}

    private var isFloatingPillEnabled: Bool { SettingsStore.shared.showFloatingPill }

    /// True while the window has to stay large enough for the expanded caption
    /// shell. The morph animates only inside SwiftUI, so `morph` already reads 0
    /// the instant a collapse *starts*; the window must wait for the animation
    /// to land before it can shrink, or the shrinking shell would be clipped.
    private var needsCaptionWindow = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Grow the shell toward the caption (1) or back into the pill (0).
    private func animateMorph(to value: Double) {
        guard !reduceMotion else {
            viewModel.morph = value
            return
        }
        withAnimation(Self.morphAnimation) { viewModel.morph = value }
    }

    /// Match the on-screen presence to the `showFloatingPill` / `pillEdge`
    /// settings: rest as the small pill when enabled, disappear when disabled.
    func refreshFloatingPresence() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isFloatingPillEnabled {
                self.pendingHide?.cancel()
                self.pendingHide = nil
                self.pendingShrink?.cancel()
                self.pendingShrink = nil
                let wasHidden = self.window?.isVisible != true
                self.ensureWindow()
                if self.viewModel.presentationPhase == .hidden {
                    self.viewModel.collapse()
                    self.viewModel.morph = 0
                    self.needsCaptionWindow = false
                }
                self.beginSpaceFollowing()
                self.beginScreenParameterFollowing()
                self.repositionWindow()
                guard let window = self.window else { return }
                if wasHidden {
                    window.alphaValue = 0
                    window.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18
                        window.animator().alphaValue = 1
                    }
                } else {
                    window.orderFrontRegardless()
                }
            } else if self.viewModel.presentationPhase == .collapsed {
                self.dismissPill()
            }
        }
    }

    /// Setting turned off while resting: fade the pill out and order it away.
    private func dismissPill() {
        guard let window else {
            viewModel.finishHide()
            return
        }
        pendingHide?.cancel()
        pendingHide = nil
        pendingShrink?.cancel()
        pendingShrink = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.viewModel.finishHide()
            self.spaceObserver.stop()
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    func show(appName: String, appIcon: NSImage?) {
        DispatchQueue.main.async {
            self.pendingHide?.cancel()
            self.pendingHide = nil
            self.pendingShrink?.cancel()
            self.pendingShrink = nil
            self.viewModel.maxCapsuleWidth = self.maxCapsuleWidth()
            let wasResting = self.viewModel.presentationPhase == .collapsed
            self.viewModel.show(appName: appName, appIcon: appIcon)
            self.viewModel.presentationPhase = .visible
            self.ensureWindow()
            self.beginSpaceFollowing()
            self.beginScreenParameterFollowing()
            // Size the window for the *expanded* shell before growing into it, so
            // the morph never outgrows its window and never has to move.
            self.needsCaptionWindow = true
            self.repositionWindow()
            if wasResting {
                self.animateMorph(to: 1)
            } else {
                self.viewModel.morph = 1
            }
            if let window = self.window {
                SpaceFollowingWindow.reaffirmWithTransitionPasses(window) {
                    self.repositionWindow()
                }
            }
            // The caption's natural size arrives from the view a beat later
            // (first show, before anything has been measured) — tighten up then.
            DispatchQueue.main.async { self.repositionWindow() }
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
            self.pendingHide = nil
            self.pendingShrink?.cancel()
            self.pendingShrink = nil

            if self.isFloatingPillEnabled {
                // Morph back into the resting pill; the window stays large until
                // the shell has finished collapsing, so nothing is clipped.
                self.viewModel.presentationPhase = .collapsed
                self.animateMorph(to: 0)
                self.scheduleShrinkToRestingPill()
                return
            }

            // No resting pill: the caption shrinks away and the window goes too.
            self.viewModel.beginDismissal()
            self.animateMorph(to: 0)

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingHide = nil
                // The pill may have been enabled while the caption was fading
                // out; rest as the pill instead of ordering the window away.
                if self.isFloatingPillEnabled {
                    self.viewModel.collapse()
                    self.viewModel.morph = 0
                    self.needsCaptionWindow = false
                    self.repositionWindow()
                    return
                }
                self.needsCaptionWindow = false
                self.viewModel.finishHide()
                self.spaceObserver.stop()
                self.window?.orderOut(nil)
            }
            self.pendingHide = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.morphDuration,
                execute: workItem
            )
        }
    }

    /// Hand the window back to pill size once the collapse morph has landed.
    private func scheduleShrinkToRestingPill() {
        guard !reduceMotion else {
            needsCaptionWindow = false
            viewModel.collapse()
            repositionWindow()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShrink = nil
            guard self.isFloatingPillEnabled, self.viewModel.morph < 0.01 else { return }
            self.needsCaptionWindow = false
            self.viewModel.collapse()
            self.repositionWindow()
        }
        pendingShrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + morphDuration, execute: work)
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

    /// Overall mic level 0…1 for the Voice glow; any thread, coalesced to main.
    func updateLevel(_ level: Float) {
        if Thread.isMainThread {
            viewModel.updateLevel(level)
        } else {
            DispatchQueue.main.async {
                self.viewModel.updateLevel(level)
            }
        }
    }

    /// Debug aid: renders the overlay's content to PNG for visual checks.
    func snapshotForDebug(to path: String) {
        guard let window = window else { return }
        AppDelegate.snapshot(window: window, to: path)
    }

    /// Debug aid for `TYPESTER_PILL_MODE=collapsed`: rest as the small pill
    /// without touching the user's settings.
    func demoCollapsedPill() {
        DispatchQueue.main.async {
            self.pendingHide?.cancel()
            self.pendingHide = nil
            self.ensureWindow()
            self.viewModel.collapse()
            self.viewModel.morph = 0
            self.needsCaptionWindow = false
            self.beginSpaceFollowing()
            self.beginScreenParameterFollowing()
            self.repositionWindow()
            self.window?.orderFrontRegardless()
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        viewModel.maxCapsuleWidth = maxCapsuleWidth()
        let hosting = NSHostingView(
            rootView: SubtitleView(
                viewModel: viewModel,
                onToggle: { [weak self] in self?.onToggle?() },
                onStop: { [weak self] in self?.onStop?() },
                onCancel: { [weak self] in self?.onCancel?() },
                onContentSizeChange: { [weak self] in self?.repositionWindow() }
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
        SpaceFollowingWindow.configure(window)
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        hosting.clipsToBounds = false
        window.contentView = hosting

        self.window = window
        beginScreenParameterFollowing()
    }

    private func beginSpaceFollowing() {
        spaceObserver.start(
            shouldReassert: { [weak self] in
                guard let self, self.window != nil else { return false }
                // Reassert for the whole on-screen lifecycle, including the
                // resting pill — not only the fully visible phase.
                return self.viewModel.presentationPhase != .hidden
            },
            handler: { [weak self] in
                guard let self, let window = self.window else { return }
                SpaceFollowingWindow.reaffirmWithTransitionPasses(window) {
                    self.repositionWindow()
                }
            }
        )
    }

    /// Re-anchor when the Dock is resized / moved / toggled, or the display
    /// changes. macOS reports nothing for an auto-hiding Dock revealing itself,
    /// so this only covers configuration changes; `DockReserve` handles the
    /// reveal case by reserving the Dock's band up front. Notification-driven —
    /// no polling, no timers.
    private func beginScreenParameterFollowing() {
        guard screenParametersToken == nil else { return }
        screenParametersToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.window != nil else { return }
            guard self.viewModel.presentationPhase != .hidden else { return }
            self.repositionWindow()
        }
    }

    private func maxCapsuleWidth() -> CGFloat {
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        return screenWidth * 0.4
    }

    /// Capsule the shell can reach right now. Before the caption has been
    /// measured, assume the widest it can be so the window is never too small.
    private var targetCapsule: CGSize {
        let measured = viewModel.captionContentSize
        let measuredKnown = measured.width > 1 && measured.height > 1
        return CGSize(
            width: max(SubtitleView.restingCapsule.width, measuredKnown ? measured.width : maxCapsuleWidth()),
            height: max(SubtitleView.restingCapsule.height, measuredKnown ? measured.height : 120)
        )
    }

    private func repositionWindow() {
        guard let window = window,
              let screen = NSScreen.main,
              let hosting = window.contentView as? NSHostingView<SubtitleView> else { return }

        if abs(viewModel.maxCapsuleWidth - maxCapsuleWidth()) > 0.5 {
            viewModel.maxCapsuleWidth = maxCapsuleWidth()
        }

        // Do not replace hosting.rootView — that remounts WaveformIcon and breaks animation.
        hosting.layoutSubtreeIfNeeded()

        let insets = SubtitleView.insets
        // Resting: exactly the pill. Otherwise the window has to fit the whole
        // morph, since the shell grows inside it without moving the window.
        let capsule = needsCaptionWindow ? targetCapsule : SubtitleView.restingCapsule
        let size = CGSize(
            width: capsule.width + insets.left + insets.right,
            height: capsule.height + insets.top + insets.bottom
        )

        // Anchored to the configured edge, centered along it, and positioned so
        // the Dock can never cover the pill.
        let origin = PillAnchorPolicy.origin(
            windowSize: size,
            screen: (frame: screen.frame, visibleFrame: screen.visibleFrame),
            dock: DockPreferencesReader.current(),
            edge: SettingsStore.shared.pillEdge,
            insets: insets
        )
        let newFrame = NSRect(origin: origin, size: size)

        Debug.log("Overlay reposition: x=\(Int(origin.x)) y=\(Int(origin.y)) w=\(Int(size.width)) h=\(Int(size.height))")

        window.setFrame(newFrame, display: true)
    }
}

/// The Dock's own preferences. `NSScreen.visibleFrame` cannot be trusted for an
/// auto-hiding Dock (macOS reports it as if it were absent, and never updates
/// when it reveals), so the pill reserves the Dock's configured band instead.
enum DockPreferencesReader {
    static func current() -> DockPreferences {
        guard let dock = UserDefaults(suiteName: "com.apple.dock") else {
            return .fallback
        }
        let tile = dock.double(forKey: "tilesize")
        let large = dock.double(forKey: "largesize")
        return DockPreferences(
            autohide: dock.bool(forKey: "autohide"),
            orientation: dock.string(forKey: "orientation") ?? "bottom",
            tileSize: tile > 0 ? CGFloat(tile) : DockPreferences.fallback.tileSize,
            magnification: dock.bool(forKey: "magnification"),
            largeSize: large > 0 ? CGFloat(large) : DockPreferences.fallback.largeSize
        )
    }
}

extension PillInsets {
    var edgeInsets: NSEdgeInsets {
        NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
}
