import AVFoundation
import Cocoa
import CoreAudio

public class AudioRecorder {
    public init() {}
    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var lastLevelEmit: CFAbsoluteTime = 0

    // MARK: - Callbacks

    public var onAudioBuffer: ((Data) -> Void)?
    /// Normalized mic level in 0...1, called on the main queue (~30 Hz).
    public var onAudioLevel: ((Float) -> Void)?
    public var onError: ((String) -> Void)?

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
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

    public func startRecording() {
        Debug.log("startRecording() called, isRecording=\(isRecording)")
        guard !isRecording else {
            Debug.log("startRecording() SKIPPED - already recording")
            return
        }

        requestPermission { [weak self] granted in
            Debug.log("Mic permission: \(granted)")
            guard granted else {
                self?.onError?("Microphone permission denied")
                return
            }
            self?.setupAndStart()
        }
    }

    public func stopRecording() {
        Debug.log("stopRecording() called, isRecording=\(isRecording)")
        guard isRecording else {
            Debug.log("stopRecording() SKIPPED - not recording")
            return
        }

        Debug.log("Stopping audio engine...")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
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
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }

        // Set selected microphone if specified
        if let micIDString = SettingsStore.shared.selectedMicrophoneID,
           let micID = AudioDeviceID(micIDString) {
            setInputDevice(micID, for: audioEngine)
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz mono PCM (Soniox requirement)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
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

        let inputBufferSize: AVAudioFrameCount = 4096
        let outputBufferSize = AVAudioFrameCount(Double(inputBufferSize) * (16000.0 / inputFormat.sampleRate))

        inputNode.installTap(onBus: 0, bufferSize: inputBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            self.emitAudioLevel(from: buffer)

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputBufferSize) else {
                return
            }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
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

        do {
            Debug.log("Starting audio engine...")
            try audioEngine.start()
            isRecording = true
            Debug.log("Audio engine started successfully")
        } catch {
            Debug.log("Audio engine FAILED: \(error.localizedDescription)")
            onError?("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func emitAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard onAudioLevel != nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmit >= 1.0 / 30.0 else { return }
        lastLevelEmit = now

        let level = Self.normalizedRMS(from: buffer)
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
        }
    }

    /// RMS of the buffer, boosted for speech and clamped to 0...1.
    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        if let floatData = buffer.floatChannelData?[0] {
            for i in 0..<frameLength {
                let s = floatData[i]
                sum += s * s
            }
        } else if let int16Data = buffer.int16ChannelData?[0] {
            for i in 0..<frameLength {
                let s = Float(int16Data[i]) / Float(Int16.max)
                sum += s * s
            }
        } else {
            return 0
        }

        let rms = sqrt(sum / Float(frameLength))
        // Speech RMS is typically small; boost so normal talking fills the bars.
        return min(1, max(0, rms * 12))
    }
}
