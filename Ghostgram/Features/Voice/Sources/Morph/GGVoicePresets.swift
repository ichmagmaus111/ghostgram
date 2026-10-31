import Foundation
import GGCore
import GGFeaturesShared
import GGVoiceDSP

/// The voice changer's presets. One parameter set drives the same C graph on all three paths
/// (voice messages, round videos, calls), so a preset sounds the same everywhere.
enum GGVoicePresetID: String, CaseIterable {
    case anonymous
    case female
    case male
    case child
    case robot
    case custom

    var title: String {
        switch self {
        case .anonymous:
            return GGStrings.Voice.Preset.anonymous
        case .female:
            return GGStrings.Voice.Preset.female
        case .male:
            return GGStrings.Voice.Preset.male
        case .child:
            return GGStrings.Voice.Preset.child
        case .robot:
            return GGStrings.Voice.Preset.robot
        case .custom:
            let name = GGVoiceSettings.customName.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? GGStrings.Voice.Preset.custom : name
        }
    }

    var subtitle: String {
        switch self {
        case .anonymous:
            return GGStrings.Voice.Preset.anonymousInfo
        case .female:
            return GGStrings.Voice.Preset.femaleInfo
        case .male:
            return GGStrings.Voice.Preset.maleInfo
        case .child:
            return GGStrings.Voice.Preset.childInfo
        case .robot:
            return GGStrings.Voice.Preset.robotInfo
        case .custom:
            return GGStrings.Voice.Preset.customInfo
        }
    }
}

/// Where a voice is changed. The anonymous mode (W3-2) overrides all three for its account.
enum GGVoiceScope {
    case voiceMessages
    case roundVideos
    case calls
}

enum GGVoicePresets {
    static func params(for preset: GGVoicePresetID) -> GGVoiceParams {
        var p = GGVoiceParams()
        GGVoiceParamsSetIdentity(&p)
        switch preset {
        case .anonymous:
            // Lower and darker, compressed, with breath and a slow random drift of the pitch: the drift is
            // the «hardening» against simply shifting the voice back, now in audible units.
            p.pitchSemitones = -3.5
            p.timbre = -0.35
            p.bassDb = 2.0
            p.trebleDb = -2.0
            p.distortion = 0.18
            p.reverbMix = 0.12
            p.reverbSize = 0.35
            p.jitter = 0.6
            p.breathiness = 0.15
            p.compression = 0.45
        case .female:
            p.pitchSemitones = 5.0
            p.timbre = 0.45
            p.trebleDb = 2.0
            p.reverbMix = 0.04
        case .male:
            p.pitchSemitones = -3.5
            p.timbre = -0.45
            p.bassDb = 3.0
            p.reverbMix = 0.03
        case .child:
            p.pitchSemitones = 7.0
            p.timbre = 0.65
            p.trebleDb = 3.0
            p.reverbMix = 0.05
        case .robot:
            p.ringModHz = 55.0
            p.ringModMix = 0.65
            p.distortion = 0.35
            p.bitcrushBits = 10.0
            p.telephone = 0.3
            p.reverbMix = 0.18
            p.reverbSize = 0.3
            p.echoMix = 0.12
            p.echoDelayMs = 70.0
            p.echoFeedback = 0.25
            p.compression = 0.5
        case .custom:
            p = GGVoicePresets.customParams()
        }
        return p
    }

    static func customParams() -> GGVoiceParams {
        var p = GGVoiceParams()
        GGVoiceParamsSetIdentity(&p)
        p.pitchSemitones = Float(GGVoiceSettings.customPitch.value)
        p.timbre = Float(GGVoiceSettings.customTimbre.value / 100.0)
        p.bassDb = Float(GGVoiceSettings.customBass.value)
        p.midDb = Float(GGVoiceSettings.customMid.value)
        p.trebleDb = Float(GGVoiceSettings.customTreble.value)
        p.gainDb = Float(GGVoiceSettings.customGain.value)
        p.distortion = Float(GGVoiceSettings.customDistortion.value / 100.0)
        p.reverbMix = Float(GGVoiceSettings.customReverb.value / 100.0)
        p.reverbSize = 0.5
        p.echoMix = Float(GGVoiceSettings.customEcho.value / 100.0)
        p.echoDelayMs = 180.0
        p.echoFeedback = 0.3
        p.compression = Float(GGVoiceSettings.customCompression.value / 100.0)
        p.breathiness = Float(GGVoiceSettings.customBreathiness.value / 100.0)
        p.chorus = Float(GGVoiceSettings.customChorus.value / 100.0)
        p.flanger = Float(GGVoiceSettings.customFlanger.value / 100.0)
        p.vibratoRateHz = Float(GGVoiceSettings.customVibratoRate.value)
        p.vibratoDepth = Float(GGVoiceSettings.customVibratoDepth.value / 100.0)
        p.ringModHz = Float(GGVoiceSettings.customRingMod.value)
        p.ringModMix = p.ringModHz > 0.0 ? 0.7 : 0.0
        p.bitcrushBits = Float(GGVoiceSettings.customBitcrush.value)
        p.telephone = GGVoiceSettings.customTelephone.value ? 1.0 : 0.0
        p.wet = Float(GGVoiceSettings.customWet.value / 100.0)
        return p
    }

    /// The selected preset (an unknown stored value falls back to the default, so the master switch
    /// always has something to apply — the old «on, but nothing chosen» state cannot happen).
    static var selectedPreset: GGVoicePresetID {
        return GGVoicePresetID(rawValue: GGVoiceSettings.morphPreset.value) ?? .anonymous
    }

    /// What to apply now on this path for this account, or nil (the sound stays untouched). Reads
    /// snapshots only. The anonymous mode wins over the user's own choice and needs no master switch.
    static func effectiveParams(scope: GGVoiceScope, account: GGAccountID?) -> GGVoiceParams? {
        if let account, let anonymous = GGAnonymousMode.voicePreset(for: account), let preset = GGVoicePresetID(rawValue: anonymous) {
            return GGVoicePresets.nonIdentity(GGVoicePresets.params(for: preset))
        }
        guard GGVoiceSettings.morphEnabled.value else {
            return nil
        }
        switch scope {
        case .voiceMessages:
            guard GGVoiceSettings.morphVoiceMessages.value else {
                return nil
            }
        case .roundVideos:
            guard GGVoiceSettings.morphRoundVideos.value else {
                return nil
            }
        case .calls:
            guard GGVoiceSettings.morphCalls.value else {
                return nil
            }
        }
        return GGVoicePresets.nonIdentity(GGVoicePresets.params(for: GGVoicePresets.selectedPreset))
    }

    static func nonIdentity(_ params: GGVoiceParams) -> GGVoiceParams? {
        var params = params
        return GGVoiceParamsIsIdentity(&params) ? nil : params
    }

    /// Byte image of a parameter set: equal sets need no new chain.
    static func fingerprint(_ params: GGVoiceParams?) -> Data? {
        guard var params else {
            return nil
        }
        return withUnsafeBytes(of: &params) { Data($0) }
    }
}
