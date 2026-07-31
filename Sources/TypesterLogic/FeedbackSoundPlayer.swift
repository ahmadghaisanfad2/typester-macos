import AppKit

/// Plays short sounds for dictation start/stop feedback.
public enum FeedbackSoundPlayer {
    public static func playStart() {
        guard SettingsStore.shared.playDictationSounds else { return }
        playBundled(named: "dictation-start.wav", fallbackSystemName: "Submarine")
    }

    public static func playStop() {
        guard SettingsStore.shared.playDictationSounds else { return }
        playBundled(named: "dictation-stop.wav", fallbackSystemName: "Blow")
    }

    private static func playBundled(named filename: String, fallbackSystemName: String) {
        DispatchQueue.main.async {
            let volume = SettingsStore.shared.dictationSoundVolume
            if let sound = AssetLoader.loadSound(named: filename) {
                sound.volume = volume
                sound.play()
            } else if let sound = NSSound(named: NSSound.Name(fallbackSystemName)) {
                sound.volume = volume
                sound.play()
            }
        }
    }
}
