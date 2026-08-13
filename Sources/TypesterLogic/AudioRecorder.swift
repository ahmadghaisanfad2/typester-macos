import AVFoundation
import Cocoa
import CoreAudio

public class AudioRecorder {
    public init() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateEngine()
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateEngine()
        }
    }

    private var audioEngine: AVAudioEngine?
    private var lifecycle = AudioRecordingLifecycle()
    private var hasInputTap = false
    private var isPreparingEngine = false
    private var lastLevelEmit: CFAbsoluteTime = 0
    private var configChangeObserver: NSObjectProtocol?

    /// Target PCM sample rate for STT (16 kHz Soniox/Deepgram, 24 kHz OpenAI).
    public var targetSampleRate: Double = 16_000

    // MARK: - Callbacks

    public var onAudioBuffer: ((Data) -> Void)?
    /// Normalized mic level in 0...1, called on the main queue (~60 Hz).
    public var onAudioLevel: ((Float) -> Void)?
    public var onError: ((String) -> Void)?

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

    /// Pre-create the audio engine so the first dictate press is not blocked by CoreAudio init.
    /// Runs on the main thread shortly after launch — off-thread creation can bind a bad input format.
    public func prepareEngine() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard self.audioEngine == nil, !self.isPreparingEngine else { return }
            self.isPreparingEngine = true
            _ = self.makeEngine()
            self.isPreparingEngine = false
        }
    }

    public func startRecording() {
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
        let wasActive = lifecycle.stop()
        Debug.log("stopRecording() called, wasActive=\(wasActive)")
        removeInputTap()
        guard wasActive else { return }

        Debug.log("Stopping audio engine...")
        audioEngine?.stop()
        audioEngine?.reset()
        // Keep the engine warm — recreating AVAudioEngine is multi-second when Discord holds audio devices.
        lastLevelEmit = 0
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(0)
        }
        Debug.log("Audio engine stopped")
    }

    // MARK: - Private

    private func setInputDevice(_ deviceID: AudioDeviceID, for engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else { return }

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

    private func setupAndStart() {
        guard lifecycle.isStarting else { return }
        var audioEngine = makeEngine()
        applySelectedMicrophone(to: audioEngine)

        var inputNode = audioEngine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)
        if !Self.isValidInputFormat(inputFormat) {
            Debug.log("Input format invalid (sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)); recreating engine")
            discardEngine()
            audioEngine = makeEngine()
            applySelectedMicrophone(to: audioEngine)
            inputNode = audioEngine.inputNode
            inputFormat = inputNode.outputFormat(forBus: 0)
        }

        guard Self.isValidInputFormat(inputFormat) else {
            failStart("The selected microphone has no usable audio format.")
            return
        }

        let sampleRate = targetSampleRate
        // Target format: mono PCM Int16 at the provider's required rate
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            onError?("Failed to create target audio format")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            onError?("Failed to create audio converter")
            return
        }

        // Request ~60 Hz taps; CoreAudio may deliver larger buffers — always size convert from actual frames.
        let inputBufferSize = AVAudioFrameCount(
            max(256, min(1024, inputFormat.sampleRate / 60.0))
        )
        let rateRatio = sampleRate / max(inputFormat.sampleRate, 1)

        removeInputTap()
        inputNode.installTap(onBus: 0, bufferSize: inputBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            self.emitAudioLevel(from: buffer)

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
        hasInputTap = true

        do {
            Debug.log("Starting audio engine...")
            try audioEngine.start()
            lifecycle.finishStarting()
            Debug.log("Audio engine started successfully")
        } catch {
            Debug.log("Audio engine FAILED: \(error.localizedDescription)")
            failStart("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func applySelectedMicrophone(to engine: AVAudioEngine) {
        if let micIDString = SettingsStore.shared.selectedMicrophoneID,
           let micID = AudioDeviceID(micIDString) {
            setInputDevice(micID, for: engine)
        }
    }

    private func makeEngine() -> AVAudioEngine {
        if let existing = audioEngine {
            return existing
        }
        let engine = AVAudioEngine()
        audioEngine = engine
        observeConfigurationChanges(on: engine)
        return engine
    }

    /// Drop the kept-warm engine after sleep or hardware changes so the next
    /// dictate press builds a fresh graph instead of calling installTap on a dead one.
    private func invalidateEngine() {
        let wasActive = lifecycle.state != .idle
        discardEngine()
        lastLevelEmit = 0
        guard wasActive else { return }
        lifecycle.stop()
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(0)
            self?.onError?("Microphone configuration changed")
        }
    }

    private func discardEngine() {
        hasInputTap = false
        audioEngine?.stop()
        audioEngine = nil
    }

    private func observeConfigurationChanges(on engine: AVAudioEngine) {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateEngine()
        }
    }

    private static func isValidInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate >= 1 && format.channelCount >= 1
    }

    private func removeInputTap() {
        guard hasInputTap else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }

    private func failStart(_ message: String) {
        removeInputTap()
        audioEngine?.stop()
        audioEngine?.reset()
        lifecycle.failStarting()
        onError?(message)
    }

    private func emitAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard onAudioLevel != nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmit >= 1.0 / 60.0 else { return }
        lastLevelEmit = now

        let level = Self.normalizedLevel(from: buffer)
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
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
