import Foundation
import SwiftSignalKit
import GGCore
import GGFeaturesShared
import GGVoiceDSP

/// The playback equalizer's control side: publishes the gains to the C core (`GGAudioEqualizerSetParameters`)
/// when they change and keeps the preset and the bands consistent. The renderers (MediaPlayer, the video
/// player ChunkMediaPlayerV2 — videos and round videos stay on their upstream player) pick changes up on
/// their next block without resetting their filters, so a change does not click.
enum GGVoiceEqualizer {
    enum Preset: String, CaseIterable {
        case flat
        case bass
        case vocal
        case treble
        case custom

        var gains: [Double]? {
            switch self {
            case .flat:
                return [0.0, 0.0, 0.0, 0.0, 0.0]
            case .bass:
                return [8.0, 5.0, 0.0, -1.0, -2.0]
            case .vocal:
                return [-2.0, 0.0, 6.0, 4.0, -1.0]
            case .treble:
                return [-3.0, -1.0, 0.0, 5.0, 8.0]
            case .custom:
                return nil
            }
        }

        var title: String {
            switch self {
            case .flat:
                return GGStrings.Voice.Eq.presetFlat
            case .bass:
                return GGStrings.Voice.Eq.presetBass
            case .vocal:
                return GGStrings.Voice.Eq.presetVocal
            case .treble:
                return GGStrings.Voice.Eq.presetTreble
            case .custom:
                return GGStrings.Voice.Eq.presetCustom
            }
        }
    }

    private static var disposable: Disposable?
    private static var lastPublished: [Float]?
    private static var lastPreset: String?
    /// The bands of a newly chosen preset are being written. The revision is delivered synchronously
    /// on the main thread, so every band written re-enters `syncPresetAndBands` while the others
    /// still hold the old values: without this the first band «moved by hand» turned the preset
    /// into «Свой» at once.
    private static var isApplyingPreset = false

    static var currentGains: [Double] {
        return GGVoiceSettings.eqBands.map { $0.value }
    }

    /// Main thread, from `register()`: one subscription for the lifetime of the process.
    static func start() {
        if GGVoiceEqualizer.disposable != nil {
            return
        }
        GGVoiceEqualizer.lastPreset = GGVoiceSettings.eqPreset.value
        GGVoiceEqualizer.publish()
        GGVoiceEqualizer.disposable = (GGSettingsStore.shared.revision
        |> deliverOnMainQueue).start(next: { _ in
            if GGVoiceEqualizer.isApplyingPreset {
                // The outer pass publishes once every band is written.
                return
            }
            GGVoiceEqualizer.syncPresetAndBands()
            GGVoiceEqualizer.publish()
        })
    }

    /// A newly chosen preset sets the bands; a band moved by hand turns the preset into «Свой».
    private static func syncPresetAndBands() {
        let preset = GGVoiceSettings.eqPreset.value
        let bands = GGVoiceEqualizer.currentGains
        if preset != GGVoiceEqualizer.lastPreset {
            GGVoiceEqualizer.lastPreset = preset
            if let gains = Preset(rawValue: preset)?.gains, gains != bands {
                GGVoiceEqualizer.isApplyingPreset = true
                for (index, setting) in GGVoiceSettings.eqBands.enumerated() {
                    setting.set(gains[index])
                }
                GGVoiceEqualizer.isApplyingPreset = false
            }
        } else if let gains = Preset(rawValue: preset)?.gains, gains != bands {
            GGVoiceEqualizer.lastPreset = Preset.custom.rawValue
            GGVoiceSettings.eqPreset.set(Preset.custom.rawValue)
        }
    }

    private static func publish() {
        let enabled = GGVoiceSettings.eqEnabled.value
        let gains = GGVoiceEqualizer.currentGains.map { Float($0) }
        let audio = enabled && GGVoiceSettings.eqAudio.value
        let roundVideo = enabled && GGVoiceSettings.eqRoundVideos.value
        let video = enabled && GGVoiceSettings.eqVideos.value
        let snapshot = gains + [audio ? 1.0 : 0.0, roundVideo ? 1.0 : 0.0, video ? 1.0 : 0.0]
        if snapshot == GGVoiceEqualizer.lastPublished {
            return
        }
        GGVoiceEqualizer.lastPublished = snapshot
        gains.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                GGAudioEqualizerSetParameters(base, audio, roundVideo, video)
            }
        }
    }

    /// For the menu preview: the gains that are in effect for a preview (nil = off).
    static func previewGains() -> [Float]? {
        guard GGVoiceSettings.eqEnabled.value else {
            return nil
        }
        let gains = GGVoiceEqualizer.currentGains.map { Float($0) }
        return gains.contains(where: { abs($0) > 0.05 }) ? gains : nil
    }

    static func bandTitle(_ index: Int) -> String {
        let frequency = GGAudioEqualizerBandFrequency(Int32(index))
        if frequency >= 1000.0 {
            let kilohertz = Double(frequency) / 1000.0
            let formatted = kilohertz.truncatingRemainder(dividingBy: 1.0) == 0.0 ? String(Int(kilohertz)) : String(format: "%.1f", kilohertz)
            return GGStrings.Voice.Eq.kilohertz(value: formatted)
        }
        return GGStrings.Voice.Eq.hertz(value: String(Int(frequency)))
    }
}
