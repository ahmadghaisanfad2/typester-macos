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
    /// True while the window has to stay large enough for the expanded caption.
    /// The morph animates only inside SwiftUI, so `morph` already reads 0 the
    /// instant a collapse *starts*; the window (and the view's own layout) must
    /// wait for the animation to land before shrinking, or the collapsing shell
    /// would be clipped.
    @Published var expandedWindow = false

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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    /// One inset set for both states. The anchor is derived from the capsule
    /// plus these insets, so sharing them keeps the capsule's anchored edge on
    /// the same screen point whether the pill is resting or expanded — that is
    /// what lets the morph grow in place instead of drifting across the screen.
    static let insets = PillInsets(top: 24, left: 30, bottom: 30, right: 30)
    /// Deliberately slim: the resting pill is a hairline, not a lozenge.
    static let restingCapsule = CGSize(width: 42, height: 14)
    static let expandedCornerRadius: CGFloat = 20
    /// The resting pill is faint; hovering lifts it so it stays discoverable.
    static let restingOpacity: Double = 0.34
    static let hoverOpacity: Double = 0.9
    /// Floor that leaves room for the Stop / Cancel buttons revealed on hover.
    static let captionMinWidth: CGFloat = 200

    var body: some View {
        // The caption laid out at its natural size sets the *expanded* window
        // size through `fittingSize`, and each overlay reads the same geometry
        // with its own GeometryReader — a real container, which is reliable,
        // unlike a preference measured through a background. While resting the
        // layout is pinned to the pill's footprint instead: an oversized layout
        // in a smaller window gets centred, which would drop the capsule below
        // its anchor.
        captionContent
            .fixedSize()
            .opacity(captionOpacity)
            .mask { animatedCapsuleMask }
            .allowsHitTesting(isExpanded)
            .padding(Self.insets.edgeInsets)
            .frame(width: restingWindowSize?.width, height: restingWindowSize?.height)
            .background { capsuleShell }
            .overlay { capsuleInteraction }
            .opacity(shellOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Window footprint while resting. `nil` when the caption should size the
    /// window itself.
    private var restingWindowSize: CGSize? {
        guard !viewModel.expandedWindow else { return nil }
        return CGSize(
            width: Self.restingCapsule.width + Self.insets.left + Self.insets.right,
            height: Self.restingCapsule.height + Self.insets.top + Self.insets.bottom
        )
    }

    private var morph: CGFloat { CGFloat(viewModel.morph) }
    private var isExpanded: Bool { viewModel.morph > 0.5 }

    /// The caption only materialises once the shell has most of its size, so the
    /// growth reads as an inflating capsule rather than text sprouting mid-way.
    private var captionOpacity: Double {
        min(1, max(0, (viewModel.morph - 0.3) / 0.7))
    }

    private var shellOpacity: Double {
        let resting = viewModel.isHovering ? Self.hoverOpacity : Self.restingOpacity
        return resting + (1 - resting) * viewModel.morph
    }

    /// Capsule the shell grows into: the caption's own size, since the caption
    /// is laid out at its natural size.
    private func targetCapsule(inWindowOf size: CGSize) -> CGSize {
        CGSize(
            width: size.width - Self.insets.left - Self.insets.right,
            height: size.height - Self.insets.top - Self.insets.bottom
        )
    }

    /// The resting pill inflating into the caption.
    private func animatingCapsule(target: CGSize) -> CGSize {
        let full = CGSize(
            width: max(Self.restingCapsule.width, target.width),
            height: max(Self.restingCapsule.height, target.height)
        )
        return CGSize(
            width: Self.restingCapsule.width + (full.width - Self.restingCapsule.width) * morph,
            height: Self.restingCapsule.height + (full.height - Self.restingCapsule.height) * morph
        )
    }

    /// What the capsule draws. It never changes with hover: the bar growing and
    /// shrinking under the pointer made the actions flicker.
    private func drawnCapsule(target: CGSize) -> CGSize {
        animatingCapsule(target: target)
    }

    private var showsActions: Bool { isExpanded && viewModel.isHovering }

    private func cornerRadius(_ size: CGSize) -> CGFloat {
        min(size.height / 2, Self.expandedCornerRadius)
    }

    /// Crops the caption to the animating capsule, pinned to the bottom-centre.
    private var animatedCapsuleMask: some View {
        GeometryReader { proxy in
            let size = drawnCapsule(target: proxy.size)
            RoundedRectangle(cornerRadius: cornerRadius(size), style: .continuous)
                .frame(width: size.width, height: size.height)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
    }

    /// The capsule shell itself, behind the content. Sized to the animating
    /// capsule so the shadow deepens as the bar grows.
    private var capsuleShell: some View {
        GeometryReader { proxy in
            let size = drawnCapsule(target: targetCapsule(inWindowOf: proxy.size))
            SoftShadowPillBackground(
                cornerRadius: cornerRadius(size),
                margin: Self.insets.nsEdgeInsets,
                shadowScale: 0.28 + 0.72 * morph,
                // Flat dark plate while dictating so the in-capsule glow
                // (and border beam) is continuous — no glass rim cut.
                glowFill: viewModel.isActive || viewModel.isProcessing
            )
            .frame(
                width: size.width + Self.insets.left + Self.insets.right,
                height: size.height + Self.insets.top + Self.insets.bottom
            )
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            // The AppKit capsule must never take mouse events: it sits over the
            // whole bar and would swallow clicks meant for the actions.
            .allowsHitTesting(false)
        }
    }

    /// The capsule's single interactive surface.
    ///
    /// Hover and taps live here and nowhere else. A second hit-testable layer —
    /// the buttons as real `Button`s — took the hover away from this one the
    /// moment it appeared, so the actions flickered on and off under the
    /// pointer. Taps are routed by point instead, against the same rects the
    /// layout draws with.
    private var capsuleInteraction: some View {
        GeometryReader { proxy in
            let size = drawnCapsule(target: targetCapsule(inWindowOf: proxy.size))
            let radius = cornerRadius(size)
            actionVisuals(in: size)
                .opacity(showsActions ? 1 : 0)
                .frame(width: size.width, height: size.height)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.18)) { viewModel.isHovering = hovering }
                }
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        handleTap(at: value.location, in: size)
                    }
                )
                .contextMenu {
                    if viewModel.isActive {
                        Button("Cancel Dictation") { onCancel?() }
                    }
                    Button("Hide Pill") { SettingsStore.shared.showFloatingPill = false }
                }
                .help(isExpanded ? "Dictating — hover for Stop or Cancel" : "Click to start dictation")
                .padding(Self.insets.edgeInsets)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
    }

    /// Stop and Cancel, drawn to fill the capsule. The visuals are inert — the
    /// interaction surface routes the click.
    private func actionVisuals(in size: CGSize) -> some View {
        let rects = PillActionsLayout.actionRects(in: size)
        return ZStack {
            actionVisual(rects.stop, systemImage: "stop.fill", isPrimary: true)
            actionVisual(rects.cancel, systemImage: "xmark", isPrimary: false)
        }
    }

    private func actionVisual(_ rect: CGRect, systemImage: String, isPrimary: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white.opacity(0.95))
            .frame(width: rect.width, height: rect.height)
            .background(Color.white.opacity(isPrimary ? 0.20 : 0.10), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    Color.white.opacity(isPrimary ? 0.28 : 0.16),
                    lineWidth: 1
                )
            )
            .position(x: rect.midX, y: rect.midY)
    }

    private func handleTap(at point: CGPoint, in size: CGSize) {
        guard isExpanded else {
            onToggle?()
            return
        }
        guard showsActions else { return }
        switch PillActionsLayout.action(at: point, in: size) {
        case .stop: onStop?()
        case .cancel: onCancel?()
        case nil: break
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
        // The hover actions are a capsule-level overlay (above the hit area), so
        // only the caption body swaps out here.
        regularContent
            .frame(minHeight: 20)
            .opacity(viewModel.isHovering ? 0 : 1)
            .scaleEffect(viewModel.isHovering ? 0.985 : 1)
            .allowsHitTesting(!viewModel.isHovering)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
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
                    self.viewModel.expandedWindow = false
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
            // the morph never outgrows its window and never has to move. The
            // view drops its resting frame as soon as `expandedWindow` is set,
            // and that layout change lands on the next turn — so grow only after
            // the window has actually been re-measured.
            self.viewModel.expandedWindow = true
            self.repositionWindow()
            if let window = self.window {
                SpaceFollowingWindow.reaffirmWithTransitionPasses(window) {
                    self.repositionWindow()
                }
            }
            DispatchQueue.main.async {
                guard self.viewModel.expandedWindow else { return }
                self.repositionWindow()
                if wasResting {
                    self.animateMorph(to: 1)
                } else {
                    self.viewModel.morph = 1
                }
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
                    self.viewModel.expandedWindow = false
                    self.repositionWindow()
                    return
                }
                self.viewModel.expandedWindow = false
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
            viewModel.expandedWindow = false
            viewModel.collapse()
            repositionWindow()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShrink = nil
            guard self.isFloatingPillEnabled, self.viewModel.morph < 0.01 else { return }
            self.viewModel.expandedWindow = false
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

    /// Debug aid: renders the HUD's content *offscreen* at the size the
    /// controller picked. A plain `NSHostingView` is not layer-backed, so
    /// `cacheDisplay` actually draws it — unlike the live window, which renders
    /// through layers and comes out blank without a WindowServer session.
    func snapshotContentForDebug(to path: String) {
        let size = window?.frame.size ?? .zero
        guard size.width > 1, size.height > 1 else { return }
        // The live window clears hover as soon as the pointer is elsewhere, so
        // the hover actions can only be rendered by forcing the state here.
        if ProcessInfo.processInfo.environment["TYPESTER_FORCE_HOVER"] != nil {
            viewModel.isHovering = true
        }
        Debug.log(
            "snapshot: size=\(Int(size.width))x\(Int(size.height))"
                + " morph=\(String(format: "%.2f", viewModel.morph))"
                + " hovering=\(viewModel.isHovering)"
                + " captionWindow=\(viewModel.expandedWindow)"
        )
        let view = SubtitleView(
            viewModel: viewModel,
            onToggle: {},
            onStop: {},
            onCancel: {}
        )
        AppDelegate.snapshot(view: view, size: size, to: path)
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
            self.viewModel.expandedWindow = false
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
        SpaceFollowingWindow.configure(window)
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        hosting.clipsToBounds = false
        // NSHostingView otherwise imposes its content's *minimum* size on the
        // window, so every explicit setFrame smaller than the caption was
        // silently overridden and the window never matched the shell drawn
        // inside it. Keeping only the intrinsic size leaves `fittingSize`
        // accurate for sizing while giving the window back to us.
        hosting.sizingOptions = [.intrinsicContentSize]
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

    /// Capsule the shell can reach: the caption laid out at its natural size.
    ///
    /// The view's root is that caption plus the shadow insets, so `fittingSize`
    /// is the caption's true size in every state — no measurement plumbing, and
    /// no scrolling fallback while the content is still unknown.
    private func captionWindowSize(_ hosting: NSHostingView<SubtitleView>) -> CGSize {
        let fitting = hosting.fittingSize
        guard fitting.width > 1, fitting.height > 1 else {
            let screenWidth = NSScreen.main?.frame.width ?? 1440
            let insets = SubtitleView.insets
            return CGSize(
                width: screenWidth * 0.4 + insets.left + insets.right,
                height: 120 + insets.top + insets.bottom
            )
        }
        return fitting
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
        let size = viewModel.expandedWindow
            ? captionWindowSize(hosting)
            : CGSize(
                width: SubtitleView.restingCapsule.width + insets.left + insets.right,
                height: SubtitleView.restingCapsule.height + insets.top + insets.bottom
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

        Debug.log("Overlay reposition: x=\(Int(origin.x)) y=\(Int(origin.y)) w=\(Int(size.width)) h=\(Int(size.height)) captionWindow=\(viewModel.expandedWindow)")

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
    var edgeInsets: EdgeInsets {
        EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right)
    }

    var nsEdgeInsets: NSEdgeInsets {
        NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
}
