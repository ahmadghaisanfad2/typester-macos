import AppKit

/// Plays short system sounds for dictation start/stop feedback.
public enum FeedbackSoundPlayer {
    public static func playStart() {
        guard SettingsStore.shared.playDictationSounds else { return }
        play(named: "Tink")
    }

    public static func playStop() {
        guard SettingsStore.shared.playDictationSounds else { return }
        play(named: "Pop")
    }

    private static func play(named name: String) {
        DispatchQueue.main.async {
            NSSound(named: NSSound.Name(name))?.play()
        }
    }
}
