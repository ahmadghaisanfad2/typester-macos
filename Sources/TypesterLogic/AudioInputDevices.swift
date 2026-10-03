import AVFoundation
import CoreAudio

public struct AudioInputDevice: Equatable {
    public let id: AudioDeviceID
    /// Stable across reboots and reconnects, unlike `id`.
    public let uid: String
    public let name: String
}

public enum AudioInputDevices {
    /// Physical input devices, excluding virtual and aggregate ones.
    public static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id),
                  let name = stringProperty(kAudioObjectPropertyName, of: id) else { return nil }
            if let transport = transportType(of: id),
               transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate {
                return nil
            }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown, inputChannelCount(of: deviceID) > 0 else {
            return nil
        }
        return deviceID
    }

    public static func uid(for deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The device an engine's input node is currently bound to.
    static func currentDevice(of inputNode: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    @discardableResult
    static func bind(_ inputNode: AVAudioInputNode, to deviceID: AudioDeviceID) -> Bool {
        guard let unit = inputNode.audioUnit else { return false }
        var id = deviceID
        return AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}

/// Chooses the format for the input-node tap.
enum AudioTapFormat {
    /// AVFAudio requires the tap rate to equal the hardware rate. After a device
    /// switch the node's client format keeps the previous device's rate, and
    /// tapping with it raises an uncatchable exception — so the rate always
    /// comes from the hardware side.
    static func make(hardware: AVAudioFormat, client: AVAudioFormat) -> AVAudioFormat? {
        let base = client.channelCount > 0 ? client : hardware
        guard hardware.sampleRate > 0, base.channelCount > 0 else { return nil }
        var description = base.streamDescription.pointee
        description.mSampleRate = hardware.sampleRate
        var layout = base.channelLayout
        if layout == nil, base.channelCount > 2 {
            // AVAudioFormat refuses more than two channels without a layout.
            layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | base.channelCount)
        }
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)
    }
}

enum InputDeviceRouting {
    /// Switching the device of an engine that is already observed fires
    /// `AVAudioEngineConfigurationChange`, whose handler tears the engine down
    /// mid-recording. A device change therefore gets a fresh engine instead.
    static func needsFreshEngine(current: AudioDeviceID?, selected: AudioDeviceID?, systemDefault: AudioDeviceID?) -> Bool {
        guard let current, let target = selected ?? systemDefault else { return false }
        return current != target
    }
}

enum MicrophoneSelectionMigration {
    /// Earlier builds saved the raw `AudioDeviceID`, which CoreAudio reassigns
    /// across reboots and reconnects; carry it over as the device UID.
    static func migrate(storedLegacyID: String?, uidForDeviceID: (AudioDeviceID) -> String?) -> String? {
        guard let storedLegacyID, let id = AudioDeviceID(storedLegacyID) else { return nil }
        return uidForDeviceID(id)
    }
}
