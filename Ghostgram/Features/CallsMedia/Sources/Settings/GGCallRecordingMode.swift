import Foundation

/// What «Записывать звонки» records: one choice since 2026-10-27 instead of the two switches «аудиозвонки»
/// and «видеозвонки» (`calls.recordAudio`, `calls.recordVideo`). Foundation only: host-tested.
enum GGCallRecordingMode: String, CaseIterable {
    case off
    /// Every call as audio, also a call with video.
    case audio
    /// Every call as audio; once the call has video, the recording switches to video.
    case audioAndVideo

    /// The stored value as a mode; anything unknown is `off`.
    static func resolved(_ rawValue: String) -> GGCallRecordingMode {
        return GGCallRecordingMode(rawValue: rawValue) ?? .off
    }

    var isOn: Bool {
        return self != .off
    }

    var recordsVideo: Bool {
        return self == .audioAndVideo
    }

    /// The two switches of builds ≤ 185 (or of the old client) as the choice: video on → audio and
    /// video (a video-only setting did not exist as a choice), else audio on → audio, else off.
    /// nil when neither switch was ever stored (keep the default).
    static func merged(audio: Bool?, video: Bool?) -> GGCallRecordingMode? {
        if audio == nil && video == nil {
            return nil
        }
        if video == true {
            return .audioAndVideo
        }
        if audio == true {
            return .audio
        }
        return .off
    }
}
