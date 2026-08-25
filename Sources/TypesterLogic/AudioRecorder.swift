import AVFoundation
import Cocoa
import CoreAudio

/// Tracks one watchdogged CoreAudio attempt, shared between its worker queue
/// and the main thread. The first of completion or abandonment wins; the
/// losing path is dropped. Internal so tests can exercise the claim logic.
final class EngineAttemptState {
    private let lock = NSLock()
    private var settled = false
    private var abandoned = false

    /// Claims the completion path; false once settled or abandoned.
    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled, !abandoned else { return false }
        settled = true
        return true
    }

    /// Claims the timeout path; false once settled or already abandoned.
    func claimAbandonment() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled, !abandoned else { return false }
        settled = true
        abandoned = true
        return true
    }

    /// Workers poll this between risky steps so an abandoned attempt can
    /// unwind and clean up after itself instead of leaving dangling state.
    var wasAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }
}

public class AudioRecorder {
    public init() {}
    private var audioEngine: AVAudioEngine?
    /// Captured while the input tap is installed so teardown never has to call
    /// the `inputNode` getter again — each call re-queries the HAL synchronously.
    private var tappedInputNode: AVAudioInputNode?
    private var lifecycle = AudioRecordingLifecycle()
    private var hasInputTap = false
    private var lastLevelEmit: CFAbsoluteTime = 0
    private var engineConfigObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Target PCM sample rate for STT (16 kHz Soniox/Deepgram, 24 kHz OpenAI).
    public var targetSampleRate: Double = 16_000

    // MARK: - Callbacks

    public var onAudioBuffer: ((Data) -> Void)?
    /// Normalized mic level in 0...1, called on the main queue (~60 Hz).
    public var onAudioLevel: ((Float) -> Void)?
    /// Log-spaced speech band levels in 0...1, called on the main queue (~60 Hz).
    public var onSpectrum: (([Float]) -> Void)?
    public var onError: ((String) -> Void)?

    private let spectrumAnalyzer = SpectrumAnalyzer()

    /// Upper bound for one synchronous CoreAudio/HAL round trip. Misbehaving
    /// audio devices can make these calls livelock; the watchdog abandons the
    /// attempt instead of letting it freeze the app. Generous because cold
    /// CoreAudio init legitimately takes multiple seconds on some machines.
    private static let halAttemptTimeout: TimeInterval = 15

    // MARK: - Engine-op chain
    // Engine-touching work runs one watchdogged attempt at a time on private
    // queues; all state decisions stay on the main thread. A wedged HAL call
    // strands only its own worker thread — the chain moves on once the
    // watchdog fires, so the app and future attempts stay responsive.

    private var engineOpInFlight = false
    private var pendingEngineOps: [() -> Void] = []

    private func enqueueEngineOp(_ op: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingEngineOps.append(op)
        pumpEngineOps()
    }

    private func pumpEngineOps() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !engineOpInFlight, !pendingEngineOps.isEmpty else { return }
        engineOpInFlight = true
        let op = pendingEngineOps.removeFirst()
        op()
    }

    private func finishEngineOp() {
        dispatchPrecondition(condition: .onQueue(.main))
        engineOpInFlight = false
        pumpEngineOps()
    }

    /// Runs `work` on a private queue and `completion` on the main queue,
    /// unless `work` exceeds the watchdog timeout, in which case `onTimeout`
    /// runs on the main queue and the attempt is abandoned — a late worker is
    /// expected to check `state` and clean up after itself.
    private func runHALAttempt<T>(
        label: String,
        timeout: TimeInterval = halAttemptTimeout,
        work: @escaping (EngineAttemptState) -> T?,
        completion: @escaping (T?) -> Void,
        onTimeout: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let state = EngineAttemptState()
        let queue = DispatchQueue(label: "com.typester.audio-hal.\(UUID().uuidString)", qos: .userInitiated)
        queue.async { [weak self] in
            let value = work(state)
            DispatchQueue.main.async {
                guard state.claimCompletion() else { return }
                completion(value)
                self?.finishEngineOp()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard state.claimAbandonment() else { return }
            Debug.log("[watchdog] \(label) exceeded \(Int(timeout))s — CoreAudio HAL unresponsive; attempt abandoned")
            onTimeout()
            self?.finishEngineOp()
        }
    }

    // MARK: - Sleep/wake resilience

    /// After macOS sleep/wake the CoreAudio device graph changes underneath a
    /// cached AVAudioEngine. Starting (or tapping) such an engine is a known
    /// crash source — the tap renders with a stale hardware format. Tear the
    /// engine down on wake / configuration change and rebuild it on demand.
    public func installSleepWakeHandlers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWake()
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
        }
    }

    private func handleSystemWake() {
        dispatchPrecondition(condition: .onQueue(.main))
        Debug.log("System woke — recycling audio engine")
        recycleEngine()
        if lifecycle.state == .recording || lifecycle.state == .starting {
            // A dictation was interrupted by sleep; restart cleanly so the
            // very next hotkey press cannot hit a dead engine.
            lifecycle.stop()
        }
        // Pre-warm a fresh engine for the next session.
        prepareEngine()
    }

    /// Stops and discards the cached engine. Safe to call from any state.
    private func recycleEngine() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard audioEngine != nil || hasInputTap else { return }
        enqueueEngineOp { [weak self] in
            self?.runTeardownAttempt(keepEngineWarm: false)
        }
    }

    private func observeEngineConfiguration(_ engine: AVAudioEngine) {
        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
        }
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Debug.log("AVAudioEngine configuration changed — recycling engine")
            let wasRecording = self.lifecycle.state == .recording
            self.recycleEngine()
            if wasRecording {
                self.lifecycle.stop()
                self.onError?("Microphone was reconfigured — try again")
            } else {
                self.prepareEngine()
            }
        }
    }

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Recording

    /// Pre-create the audio engine so the first dictate press is not blocked by
    /// CoreAudio init. The HAL queries behind `engine.inputNode` are
    /// synchronous mach RPCs that can livelock with a misbehaving audio
    /// device, so they run watchdogged on a private queue — never on the main
    /// thread, where a wedged query would freeze the whole app.
    public func prepareEngine() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.enqueueEngineOp { self.runPrepareAttempt() }
        }
    }

    private func runPrepareAttempt() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard audioEngine == nil else {
            finishEngineOp()
            return
        }
        runHALAttempt(label: "audio engine prewarm") { _ -> AVAudioEngine? in
            let engine = AVAudioEngine()
            _ = engine.inputNode.outputFormat(forBus: 0)
            return engine
        } completion: { [weak self] engine in
            guard let self, let engine else { return }
            guard self.audioEngine == nil else { return }
            self.audioEngine = engine
            self.observeEngineConfiguration(engine)
            Debug.log("Audio engine prewarmed")
        } onTimeout: {}
    }

    public func startRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        Debug.log("startRecording() called, state=\(lifecycle.state)")
        guard lifecycle.begin() else {
            Debug.log("startRecording() SKIPPED - recorder is already active")
            return
        }

        requestPermission { [weak self] granted in
            Debug.log("Mic permission: \(granted)")
            guard let self, self.lifecycle.resolvePermission(granted: granted) else {
                return
            }
            guard granted else {
                self.onError?("Microphone permission denied")
                return
            }
            self.setupAndStart()
        }
    }

    public func stopRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        let wasActive = lifecycle.stop()
        Debug.log("stopRecording() called, wasActive=\(wasActive)")
        guard wasActive else { return }

        Debug.log("Stopping audio engine...")
        // Keep the engine warm — recreating AVAudioEngine is multi-second when Discord holds audio devices.
        enqueueEngineOp { [weak self] in
            self?.runTeardownAttempt(keepEngineWarm: true)
        }
    }

    // MARK: - Start attempt

    private enum StartOutcome {
        case started(engine: AVAudioEngine, inputNode: AVAudioInputNode, engineIsNew: Bool)
        case failed(String, dropEngine: Bool)
    }

    private func setupAndStart() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard lifecycle.isStarting else { return }
        // Capture settings on the main thread; the attempt runs off-main.
        let selectedMicID = SettingsStore.shared.selectedMicrophoneID
        let targetRate = targetSampleRate
        enqueueEngineOp { [weak self] in
            self?.runStartAttempt(selectedMicID: selectedMicID, targetRate: targetRate)
        }
    }

    private func runStartAttempt(selectedMicID: String?, targetRate: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard lifecycle.isStarting else {
            finishEngineOp()
            return
        }
        let existingEngine = audioEngine

        runHALAttempt(label: "audio engine start") { [weak self] state -> StartOutcome? in
            guard let self else { return nil }
            return self.performEngineStart(
                engine: existingEngine ?? AVAudioEngine(),
                engineIsNew: existingEngine == nil,
                selectedMicID: selectedMicID,
                targetRate: targetRate,
                state: state
            )
        } completion: { [weak self] outcome in
            guard let self, let outcome else { return }
            self.handleStartOutcome(outcome)
        } onTimeout: { [weak self] in
            guard let self else { return }
            // The wedged worker may still hold the engine it was configuring;
            // it unwinds itself if it ever returns. Drop main-side references
            // so the next attempt builds a fresh engine.
            self.audioEngine = nil
            self.tappedInputNode = nil
            self.hasInputTap = false
            guard self.lifecycle.isStarting else { return }
            self.lifecycle.failStarting()
            self.onError?("The microphone is not responding. An audio device is blocking CoreAudio — try again, or quit and reopen Typester if this persists.")
        }
    }

    /// Runs on a private attempt queue. Every HAL-touching step is followed by
    /// an abandonment check so a timed-out attempt unwinds cleanly.
    private func performEngineStart(
        engine: AVAudioEngine,
        engineIsNew: Bool,
        selectedMicID: String?,
        targetRate: Double,
        state: EngineAttemptState
    ) -> StartOutcome? {
        if let micID = selectedMicID.flatMap(AudioDeviceID.init) {
            Self.setDevice(micID, on: engine)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        if state.wasAbandoned { return nil }

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return .failed("The selected microphone has no usable audio format.", dropEngine: engineIsNew)
        }

        let sampleRate = targetRate
        // Target format: mono PCM Int16 at the provider's required rate
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            return .failed("Failed to create target audio format", dropEngine: engineIsNew)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return .failed("Failed to create audio converter", dropEngine: engineIsNew)
        }

        // Request ~60 Hz taps; CoreAudio may deliver larger buffers — always size convert from actual frames.
        let inputBufferSize = AVAudioFrameCount(
            max(256, min(1024, inputFormat.sampleRate / 60.0))
        )
        let rateRatio = sampleRate / max(inputFormat.sampleRate, 1)

        // Clear any tap left behind by an interrupted previous session.
        inputNode.removeTap(onBus: 0)
        spectrumAnalyzer.reset()
        inputNode.installTap(onBus: 0, bufferSize: inputBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            self.emitAnalysis(from: buffer)

            // Capacity must follow the delivered frameLength (not the requested buffer hint).
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * rateRatio) + 64
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(outCapacity, 1)) else {
                return
            }

            var error: NSError?
            var provided = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if error != nil { return }

            if let channelData = outputBuffer.int16ChannelData {
                let frameLength = Int(outputBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: frameLength * 2)
                self.onAudioBuffer?(data)
            }
        }
        if state.wasAbandoned {
            inputNode.removeTap(onBus: 0)
            return nil
        }

        do {
            Debug.log("Starting audio engine...")
            try engine.start()
            Debug.log("Audio engine started successfully")
        } catch {
            Debug.log("Audio engine FAILED: \(error.localizedDescription)")
            // The failed engine is likely poisoned (stale device/format after
            // wake). Discard it so the next attempt builds a fresh one.
            return .failed("Failed to start audio engine: \(error.localizedDescription)", dropEngine: true)
        }
        if state.wasAbandoned {
            // The watchdog gave up on us mid-start; shut back down quietly.
            inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            return nil
        }

        return .started(engine: engine, inputNode: inputNode, engineIsNew: engineIsNew)
    }

    private func handleStartOutcome(_ outcome: StartOutcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch outcome {
        case .started(let engine, let inputNode, let engineIsNew):
            audioEngine = engine
            tappedInputNode = inputNode
            hasInputTap = true
            lastLevelEmit = 0
            if engineIsNew {
                observeEngineConfiguration(engine)
            }
            lifecycle.finishStarting()
        case .failed(let message, let dropEngine):
            hasInputTap = false
            tappedInputNode = nil
            lifecycle.failStarting()
            onError?(message)
            enqueueEngineOp { [weak self] in
                self?.runTeardownAttempt(keepEngineWarm: !dropEngine)
            }
        }
    }

    private static func setDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        guard let audioUnit = engine.inputNode.audioUnit else { return }

        var deviceIDCopy = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDCopy,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    // MARK: - Teardown attempt

    private func runTeardownAttempt(keepEngineWarm: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        let engine = audioEngine
        let inputNode = tappedInputNode
        let hadTap = hasInputTap

        runHALAttempt(label: "audio engine teardown") { _ -> AVAudioEngine? in
            if hadTap, let inputNode {
                inputNode.removeTap(onBus: 0)
            }
            engine?.stop()
            engine?.reset()
            return engine
        } completion: { [weak self] tornDownEngine in
            guard let self else { return }
            self.finishTeardown(engine: tornDownEngine, keepEngineWarm: keepEngineWarm)
        } onTimeout: { [weak self] in
            guard let self else { return }
            // Wedged teardown: drop references so the next session builds fresh.
            self.hasInputTap = false
            self.tappedInputNode = nil
            if !keepEngineWarm { self.audioEngine = nil }
        }
    }

    private func finishTeardown(engine: AVAudioEngine?, keepEngineWarm: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        hasInputTap = false
        tappedInputNode = nil
        lastLevelEmit = 0
        spectrumAnalyzer.reset()
        if keepEngineWarm {
            onAudioLevel?(0)
            onSpectrum?(Array(repeating: 0, count: spectrumAnalyzer.bandCount))
            Debug.log("Audio engine stopped")
            return
        }
        if let engineConfigObserver, engine != nil {
            NotificationCenter.default.removeObserver(engineConfigObserver)
            self.engineConfigObserver = nil
        }
        audioEngine = nil
        Debug.log("Audio engine recycled")
    }

    // MARK: - Analysis

    private func emitAnalysis(from buffer: AVAudioPCMBuffer) {
        guard onAudioLevel != nil || onSpectrum != nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmit >= 1.0 / 60.0 else { return }
        lastLevelEmit = now

        let level = Self.normalizedLevel(from: buffer)
        if onSpectrum != nil, let floatData = buffer.floatChannelData?[0] {
            spectrumAnalyzer.appendSamples(floatData, count: Int(buffer.frameLength))
        }
        let bands = onSpectrum != nil
            ? spectrumAnalyzer.bandLevels(sampleRate: Float(buffer.format.sampleRate))
            : []

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
            self?.onSpectrum?(bands)
        }
    }

    /// Peak + RMS hybrid, boosted for speech and clamped to 0...1.
    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        var peak: Float = 0
        if let floatData = buffer.floatChannelData?[0] {
            for i in 0..<frameLength {
                let s = floatData[i]
                let a = abs(s)
                if a > peak { peak = a }
                sum += s * s
            }
        } else if let int16Data = buffer.int16ChannelData?[0] {
            for i in 0..<frameLength {
                let s = Float(int16Data[i]) / Float(Int16.max)
                let a = abs(s)
                if a > peak { peak = a }
                sum += s * s
            }
        } else {
            return 0
        }

        let rms = sqrt(sum / Float(frameLength))
        // Speech levels are small; boost so talking fills the bars. Peak catches consonants.
        return min(1, max(0, max(rms * 12, peak * 0.85)))
    }
}
