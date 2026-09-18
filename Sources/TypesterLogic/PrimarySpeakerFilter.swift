import Foundation

/// Locks dictation to the first labeled speaker after session start.
///
/// Unlabeled tokens (provider did not diarize) are always included.
/// `reset()` at the start of each dictation session so a new primary can lock.
/// Not internally synchronized — callers must use one thread (STT routing is main).
public final class PrimarySpeakerFilter {
    public private(set) var lockedSpeaker: String?

    public init() {}

    public func reset() {
        lockedSpeaker = nil
    }

    /// Returns whether a transcript token should be kept.
    public func shouldInclude(speaker: String?) -> Bool {
        guard let speaker, !speaker.isEmpty else { return true }
        if let locked = lockedSpeaker {
            return speaker == locked
        }
        lockedSpeaker = speaker
        return true
    }
}
