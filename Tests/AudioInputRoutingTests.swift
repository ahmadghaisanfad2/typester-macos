import AVFoundation
import TypesterObjC
import XCTest
@testable import TypesterCore

final class AudioTapFormatTests: XCTestCase {
    private func format(_ rate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat {
        var description = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
        let layout = channels > 2
            ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
            : nil
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)!
    }

    func testMultichannelClientFormatSurvivesTheRateChange() {
        let tap = AudioTapFormat.make(hardware: format(48_000, 16), client: format(44_100, 16))
        XCTAssertEqual(tap?.sampleRate, 48_000)
        XCTAssertEqual(tap?.channelCount, 16)
    }

    // Reproduces the shipped crash: after a device switch the client side still
    // reports the old device's rate while the hardware runs at another one.
    func testUsesHardwareRateWhenClientFormatIsStale() {
        let tap = AudioTapFormat.make(hardware: format(48_000, 1), client: format(44_100, 1))
        XCTAssertEqual(tap?.sampleRate, 48_000)
        XCTAssertEqual(tap?.channelCount, 1)
    }

    func testKeepsClientChannelCountForMultichannelHardware() {
        let tap = AudioTapFormat.make(hardware: format(48_000, 16), client: format(48_000, 1))
        XCTAssertEqual(tap?.channelCount, 1)
    }

    func testRejectsHardwareWithoutAUsableRate() {
        let silent = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false)!
        XCTAssertNil(AudioTapFormat.make(hardware: silent, client: format(44_100, 1)))
    }
}

final class InputDeviceRoutingTests: XCTestCase {
    func testKeepsWarmEngineWhenItAlreadyUsesTheSelectedDevice() {
        XCTAssertFalse(InputDeviceRouting.needsFreshEngine(current: 114, selected: 114, systemDefault: 129))
    }

    func testRebuildsWhenTheSelectedDeviceDiffers() {
        XCTAssertTrue(InputDeviceRouting.needsFreshEngine(current: 129, selected: 114, systemDefault: 129))
    }

    func testRebuildsWhenReturningToSystemDefaultFromAnExplicitDevice() {
        XCTAssertTrue(InputDeviceRouting.needsFreshEngine(current: 114, selected: nil, systemDefault: 129))
    }

    func testKeepsEngineOnSystemDefault() {
        XCTAssertFalse(InputDeviceRouting.needsFreshEngine(current: 129, selected: nil, systemDefault: 129))
    }

    func testKeepsEngineWhenTheCurrentDeviceIsUnknown() {
        XCTAssertFalse(InputDeviceRouting.needsFreshEngine(current: nil, selected: 114, systemDefault: 129))
    }
}

final class MicrophoneSelectionMigrationTests: XCTestCase {
    func testLegacyNumericIDBecomesTheDeviceUID() {
        let uid = MicrophoneSelectionMigration.migrate(storedLegacyID: "114") { id in
            id == 114 ? "BuiltInMicrophoneDevice" : nil
        }
        XCTAssertEqual(uid, "BuiltInMicrophoneDevice")
    }

    func testLegacyIDForAMissingDeviceFallsBackToSystemDefault() {
        XCTAssertNil(MicrophoneSelectionMigration.migrate(storedLegacyID: "999") { _ in nil })
    }

    func testNoLegacyValueStaysOnSystemDefault() {
        XCTAssertNil(MicrophoneSelectionMigration.migrate(storedLegacyID: nil) { _ in "x" })
        XCTAssertNil(MicrophoneSelectionMigration.migrate(storedLegacyID: "not-a-number") { _ in "x" })
    }
}

final class AudioExceptionGuardTests: XCTestCase {
    // A second tap on one bus raises an Objective-C exception inside AVFAudio
    // (`nullptr == Tap()`); the guard must surface it as a Swift error.
    func testDuplicateTapBecomesAnErrorInsteadOfAbort() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

        try TYPAudioSafety.installTap(on: player, bus: 0, bufferSize: 1024, format: format) { _, _ in }
        XCTAssertThrowsError(
            try TYPAudioSafety.installTap(on: player, bus: 0, bufferSize: 1024, format: format) { _, _ in }
        ) { error in
            XCTAssertEqual((error as NSError).domain, TYPAudioSafetyErrorDomain)
        }
        player.removeTap(onBus: 0)
    }
}
