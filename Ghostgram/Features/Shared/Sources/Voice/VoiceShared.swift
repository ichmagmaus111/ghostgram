import Foundation
import GGCore

/// The part of GGVoice that the extensions (notification service, share) also link: settings with
/// `.extensions`, NSE handlers, attribute declarations. Owner: W3-1.
///
/// The voice settings are declared here rather than in GGVoice because upstream modules below the
/// feature layer read them on their hot paths (TelegramUI: the recorder and the playlist; the bubble
/// nodes: word bubbles). Reading is a snapshot load (GGCore), nothing else.
public enum GGVoiceShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
        GGVoiceSettings.declare()
        GGVoiceMessageAttributes.register()
    }
}

/// Every setting of the «Голос» zone, declared once. User switches are off by default; the «where to
/// apply» switches only act under their master switch, so the master alone gives a working default.
public enum GGVoiceSettings {
    // MARK: Voice changer

    public static let morphEnabled = GGSetting<Bool>("voice.morph.enabled", default: false)
    /// Preset id: anonymous, female, male, child, robot, custom (`GGVoicePresetID`).
    public static let morphPreset = GGSetting<String>("voice.morph.preset", default: "anonymous")
    public static let morphVoiceMessages = GGSetting<Bool>("voice.morph.voiceMessages", default: true)
    public static let morphRoundVideos = GGSetting<Bool>("voice.morph.roundVideos", default: true)
    public static let morphCalls = GGSetting<Bool>("voice.morph.calls", default: false)

    // MARK: «Свой голос» (user units, see GGVoiceParams)

    public static let customName = GGSetting<String>("voice.custom.name", default: "")
    /// Semitones −12…12.
    public static let customPitch = GGSetting<Double>("voice.custom.pitch", default: 0.0)
    /// −100…100 %.
    public static let customTimbre = GGSetting<Double>("voice.custom.timbre", default: 0.0)
    /// dB −12…12.
    public static let customBass = GGSetting<Double>("voice.custom.bass", default: 0.0)
    public static let customMid = GGSetting<Double>("voice.custom.mid", default: 0.0)
    public static let customTreble = GGSetting<Double>("voice.custom.treble", default: 0.0)
    public static let customGain = GGSetting<Double>("voice.custom.gain", default: 0.0)
    /// 0…100 %.
    public static let customDistortion = GGSetting<Double>("voice.custom.distortion", default: 0.0)
    public static let customReverb = GGSetting<Double>("voice.custom.reverb", default: 0.0)
    public static let customEcho = GGSetting<Double>("voice.custom.echo", default: 0.0)
    public static let customCompression = GGSetting<Double>("voice.custom.compression", default: 0.0)
    public static let customBreathiness = GGSetting<Double>("voice.custom.breathiness", default: 0.0)
    public static let customChorus = GGSetting<Double>("voice.custom.chorus", default: 0.0)
    public static let customFlanger = GGSetting<Double>("voice.custom.flanger", default: 0.0)
    public static let customVibratoDepth = GGSetting<Double>("voice.custom.vibratoDepth", default: 0.0)
    public static let customWet = GGSetting<Double>("voice.custom.wet", default: 100.0)
    /// Hz 0…12.
    public static let customVibratoRate = GGSetting<Double>("voice.custom.vibratoRate", default: 5.0)
    /// Hz 0…1000, 0 = off.
    public static let customRingMod = GGSetting<Double>("voice.custom.ringMod", default: 0.0)
    /// Bits 2…16, 16 = off.
    public static let customBitcrush = GGSetting<Double>("voice.custom.bitcrush", default: 16.0)
    public static let customTelephone = GGSetting<Bool>("voice.custom.telephone", default: false)

    // MARK: Playback equalizer

    public static let eqEnabled = GGSetting<Bool>("voice.eq.enabled", default: false)
    /// flat, bass, vocal, treble, custom.
    public static let eqPreset = GGSetting<String>("voice.eq.preset", default: "flat")
    /// dB −12…12; 60 Hz, 230 Hz, 910 Hz, 3.6 kHz, 14 kHz.
    public static let eqBand0 = GGSetting<Double>("voice.eq.band0", default: 0.0)
    public static let eqBand1 = GGSetting<Double>("voice.eq.band1", default: 0.0)
    public static let eqBand2 = GGSetting<Double>("voice.eq.band2", default: 0.0)
    public static let eqBand3 = GGSetting<Double>("voice.eq.band3", default: 0.0)
    public static let eqBand4 = GGSetting<Double>("voice.eq.band4", default: 0.0)
    public static let eqAudio = GGSetting<Bool>("voice.eq.audio", default: true)
    public static let eqRoundVideos = GGSetting<Bool>("voice.eq.roundVideos", default: true)
    public static let eqVideos = GGSetting<Bool>("voice.eq.videos", default: true)

    public static var eqBands: [GGSetting<Double>] {
        return [GGVoiceSettings.eqBand0, GGVoiceSettings.eqBand1, GGVoiceSettings.eqBand2, GGVoiceSettings.eqBand3, GGVoiceSettings.eqBand4]
    }

    // MARK: Transcription (the engine has no setting: owner's decision 2026-10-21)

    public static let wordBubbles = GGSetting<Bool>("voice.wordBubbles", default: false)
    public static let autoTranscribe = GGSetting<Bool>("voice.autoTranscribe.enabled", default: false)
    public static let autoTranscribeRoundVideos = GGSetting<Bool>("voice.autoTranscribe.roundVideos", default: false)
    /// plain, quote, bold, italic, underline, strikethrough, monospace, spoiler.
    public static let autoTranscribeFormat = GGSetting<String>("voice.autoTranscribe.format", default: "quote")
    public static let autoTranscribeTranslate = GGSetting<Bool>("voice.autoTranscribe.translate", default: false)
    /// Language code of the translation; "" = the language of Telegram's interface.
    public static let autoTranscribeLanguage = GGSetting<String>("voice.autoTranscribe.language", default: "")

    // MARK: Playback and recording

    /// Do not play the next unheard voice message / round video after the current one ends.
    public static let disableAutoplay = GGSetting<Bool>("voice.disableAutoplay", default: false)
    /// Record voice messages and round videos with the built-in microphone even with a headset (SG-F3).
    public static let builtInMicrophone = GGSetting<Bool>("voice.builtInMicrophone", default: false)
    /// Mirror of the upstream `MediaInputSettings.pauseMusicOnRecording` (inverted) so the menu row
    /// redraws when Data & Storage changes it. Upstream stays the only source of truth.
    public static let keepMusicMirror = GGSetting<Bool>("voice.keepMusicMirror", default: false, flags: [.noExport])

    static func declare() {
        let _ = GGVoiceSettings.morphEnabled
        let _ = GGVoiceSettings.morphPreset
        let _ = GGVoiceSettings.morphVoiceMessages
        let _ = GGVoiceSettings.morphRoundVideos
        let _ = GGVoiceSettings.morphCalls
        let _ = GGVoiceSettings.customName
        let _ = GGVoiceSettings.customPitch
        let _ = GGVoiceSettings.customTimbre
        let _ = GGVoiceSettings.customBass
        let _ = GGVoiceSettings.customMid
        let _ = GGVoiceSettings.customTreble
        let _ = GGVoiceSettings.customGain
        let _ = GGVoiceSettings.customDistortion
        let _ = GGVoiceSettings.customReverb
        let _ = GGVoiceSettings.customEcho
        let _ = GGVoiceSettings.customCompression
        let _ = GGVoiceSettings.customBreathiness
        let _ = GGVoiceSettings.customChorus
        let _ = GGVoiceSettings.customFlanger
        let _ = GGVoiceSettings.customVibratoDepth
        let _ = GGVoiceSettings.customWet
        let _ = GGVoiceSettings.customVibratoRate
        let _ = GGVoiceSettings.customRingMod
        let _ = GGVoiceSettings.customBitcrush
        let _ = GGVoiceSettings.customTelephone
        let _ = GGVoiceSettings.eqEnabled
        let _ = GGVoiceSettings.eqPreset
        let _ = GGVoiceSettings.eqBand0
        let _ = GGVoiceSettings.eqBand1
        let _ = GGVoiceSettings.eqBand2
        let _ = GGVoiceSettings.eqBand3
        let _ = GGVoiceSettings.eqBand4
        let _ = GGVoiceSettings.eqAudio
        let _ = GGVoiceSettings.eqRoundVideos
        let _ = GGVoiceSettings.eqVideos
        let _ = GGVoiceSettings.wordBubbles
        let _ = GGVoiceSettings.autoTranscribe
        let _ = GGVoiceSettings.autoTranscribeRoundVideos
        let _ = GGVoiceSettings.autoTranscribeFormat
        let _ = GGVoiceSettings.autoTranscribeTranslate
        let _ = GGVoiceSettings.autoTranscribeLanguage
        let _ = GGVoiceSettings.disableAutoplay
        let _ = GGVoiceSettings.builtInMicrophone
        let _ = GGVoiceSettings.keepMusicMirror
    }
}

/// An effect the voice recorder runs over every captured block before the waveform and the encoder
/// see it, so the real voice is never written anywhere. Created once per recording (recorder queue).
public protocol GGVoiceRecordingEffect: AnyObject {
    /// Mono Int16 samples, processed in place; the length never changes. Recorder queue.
    func process(_ samples: UnsafeMutablePointer<Int16>, count: Int, sampleRate: Int)
}

public enum GGVoiceRecordingHooks {
    /// Provider (first non-nil wins), asked when a voice message recording starts. GGVoice.
    public static let effect = GGHookPoint<() -> GGVoiceRecordingEffect?>("voice.recordingEffect")

    /// `ManagedAudioRecorderContext.init`. Without handlers: nil, upstream behaviour.
    public static func makeEffect() -> GGVoiceRecordingEffect? {
        if GGVoiceRecordingHooks.effect.isEmpty {
            return nil
        }
        for handler in GGVoiceRecordingHooks.effect.handlers {
            if let effect = handler() {
                return effect
            }
        }
        return nil
    }

    /// `SharedMediaPlayer.setActionAtEnd`: stop after a voice message / round video instead of
    /// playing the next unheard one.
    public static var disablesNextVoiceAutoplay: Bool {
        return GGVoiceSettings.disableAutoplay.value
    }
}
