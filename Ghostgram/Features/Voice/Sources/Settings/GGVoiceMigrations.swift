import Foundation
import GGCore
import GGFeaturesShared

/// Old Ghostgram keys → `voice.*`. Same bundle id, so the old UserDefaults are still there.
/// Not carried over (owner's decisions 2026-10-21): the transcription engine switches
/// (`FontCustomization.useTelegramServerTranscription`, SG `transcriptionBackend`), the voice clone
/// (`GG.voiceClone.*` and its model files), tempo and reverse (no longer parameters: one graph that never
/// changes the length, for voice messages, round videos and calls alike).
enum GGVoiceMigrations {
    static func register() {
        GGMigrations.registerGlobal(id: "voice.v1") { legacy in
            GGVoiceMigrations.migrateMorpher(legacy)
            GGVoiceMigrations.migrateEqualizer(legacy)
            GGVoiceMigrations.migrateTranscription(legacy)
            GGVoiceMigrations.migratePlayback(legacy)
            GGVoiceMigrations.dropRemoved(legacy)
        }
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private static func migrateMorpher(_ legacy: GGLegacyDefaults) {
        let presetIds: [Int: String] = [1: "anonymous", 2: "female", 3: "male", 4: "child", 5: "robot", 6: "custom"]
        let enabled = legacy.bool("VoiceMorpher.isEnabled") ?? false
        if let preset = legacy.int("VoiceMorpher.selectedPreset") {
            if let id = presetIds[preset] {
                GGVoiceSettings.morphPreset.set(id)
                GGVoiceSettings.morphEnabled.set(enabled)
            } else {
                // 0 = «off», 7 = the voice clone, which is not carried over: the changer stays off rather
                // than silently using another voice.
                GGVoiceSettings.morphEnabled.set(false)
            }
        }
        if let name = legacy.string("VoiceMorpher.customName") {
            GGVoiceSettings.customName.set(name)
        }
        if let value = legacy.double("VoiceMorpher.customPitchShift") {
            GGVoiceSettings.customPitch.set(GGVoiceMigrations.clamp(value / 100.0, -12.0 ... 12.0))
        }
        if let value = legacy.double("VoiceMorpher.customFormantShift") {
            GGVoiceSettings.customTimbre.set(GGVoiceMigrations.clamp(value / 1200.0 * 100.0, -100.0 ... 100.0))
        }
        let decibels: [(String, GGSetting<Double>)] = [
            ("VoiceMorpher.customBassEQ", GGVoiceSettings.customBass),
            ("VoiceMorpher.customMidEQ", GGVoiceSettings.customMid),
            ("VoiceMorpher.customTrebleEQ", GGVoiceSettings.customTreble),
            ("VoiceMorpher.customGain", GGVoiceSettings.customGain)
        ]
        for (key, setting) in decibels {
            if let value = legacy.double(key) {
                setting.set(GGVoiceMigrations.clamp(value, -12.0 ... 12.0))
            }
        }
        let percents: [(String, GGSetting<Double>)] = [
            ("VoiceMorpher.customDistortionAmount", GGVoiceSettings.customDistortion),
            ("VoiceMorpher.customReverbAmount", GGVoiceSettings.customReverb),
            ("VoiceMorpher.customDelayAmount", GGVoiceSettings.customEcho),
            ("VoiceMorpher.customCompression", GGVoiceSettings.customCompression),
            ("VoiceMorpher.customBreathiness", GGVoiceSettings.customBreathiness),
            ("VoiceMorpher.customChorusAmount", GGVoiceSettings.customChorus),
            ("VoiceMorpher.customFlangerAmount", GGVoiceSettings.customFlanger),
            ("VoiceMorpher.customVibratoDepth", GGVoiceSettings.customVibratoDepth),
            ("VoiceMorpher.customDryWetMix", GGVoiceSettings.customWet)
        ]
        for (key, setting) in percents {
            if let value = legacy.double(key) {
                setting.set(GGVoiceMigrations.clamp(value, 0.0 ... 100.0))
            }
        }
        if let value = legacy.double("VoiceMorpher.customVibratoRate") {
            GGVoiceSettings.customVibratoRate.set(GGVoiceMigrations.clamp(value, 0.0 ... 12.0))
        }
        if let value = legacy.double("VoiceMorpher.customRingModFreq") {
            GGVoiceSettings.customRingMod.set(GGVoiceMigrations.clamp(value, 0.0 ... 1000.0))
        }
        if let value = legacy.double("VoiceMorpher.customBitcrushBits") {
            GGVoiceSettings.customBitcrush.set(GGVoiceMigrations.clamp(value, 2.0 ... 16.0))
        }
        if let value = legacy.bool("VoiceMorpher.customPhoneFilter") {
            GGVoiceSettings.customTelephone.set(value)
        }
        let keys = ["isEnabled", "selectedPreset", "customName", "customPitchShift", "customRate", "customDistortionAmount", "customReverbAmount", "customDelayAmount", "customFormantShift", "customBassEQ", "customMidEQ", "customTrebleEQ", "customCompression", "customGain", "customVibratoRate", "customVibratoDepth", "customBreathiness", "customDryWetMix", "customChorusAmount", "customRingModFreq", "customBitcrushBits", "customFlangerAmount", "customPhoneFilter", "customReverseAudio"]
        for key in keys {
            legacy.removeLegacyKey("VoiceMorpher." + key)
        }
    }

    private static func migrateEqualizer(_ legacy: GGLegacyDefaults) {
        // The preset first, then the bands: choosing a preset rewrites the bands with its own gains
        // (GGVoiceEqualizer), so bands written before it were lost. Written after it, bands that
        // differ from the preset turn it into «Свой», as moving a band by hand does.
        if let preset = legacy.string("GG.eq.preset"), ["flat", "bass", "vocal", "treble", "custom"].contains(preset) {
            GGVoiceSettings.eqPreset.set(preset)
        }
        var hasGain = false
        for (index, setting) in GGVoiceSettings.eqBands.enumerated() {
            let key = "GG.eq.band.\(index)"
            if let value = legacy.double(key) {
                let clamped = GGVoiceMigrations.clamp(value, -12.0 ... 12.0)
                setting.set(clamped)
                hasGain = hasGain || abs(clamped) > 0.05
            }
            legacy.removeLegacyKey(key)
        }
        let audio = legacy.bool("GG.eq.voice")
        let round = legacy.bool("GG.eq.videoCircle")
        let video = legacy.bool("GG.eq.video")
        if audio != nil || round != nil || video != nil {
            GGVoiceSettings.eqAudio.set(audio ?? false)
            GGVoiceSettings.eqRoundVideos.set(round ?? false)
            GGVoiceSettings.eqVideos.set(video ?? false)
            // The old equalizer was «on» when some band had gain and some kind of media was ticked.
            GGVoiceSettings.eqEnabled.set(hasGain && ((audio ?? false) || (round ?? false) || (video ?? false)))
        }
        for key in ["GG.eq.voice", "GG.eq.videoCircle", "GG.eq.video", "GG.eq.preset"] {
            legacy.removeLegacyKey(key)
        }
    }

    private static func migrateTranscription(_ legacy: GGLegacyDefaults) {
        if let value = legacy.bool("MiscSettings.autoTranscribeOwnVoice") {
            GGVoiceSettings.autoTranscribe.set(value)
        }
        if let value = legacy.string("MiscSettings.voiceTranscriptionFormat"), let format = GGTranscriptionFormat(rawValue: value) {
            GGVoiceSettings.autoTranscribeFormat.set(format.rawValue)
        }
        if let value = legacy.bool("MiscSettings.autoTranscribeTranslate") {
            GGVoiceSettings.autoTranscribeTranslate.set(value)
        }
        if let value = legacy.string("MiscSettings.autoTranscribeTargetLanguage") {
            GGVoiceSettings.autoTranscribeLanguage.set(value)
        }
        for key in ["MiscSettings.autoTranscribeOwnVoice", "MiscSettings.voiceTranscriptionFormat", "MiscSettings.autoTranscribeTranslate", "MiscSettings.autoTranscribeTargetLanguage"] {
            legacy.removeLegacyKey(key)
        }
    }

    private static func migratePlayback(_ legacy: GGLegacyDefaults) {
        if let value = legacy.bool("disableNextVoiceAutoPlay") {
            GGVoiceSettings.disableAutoplay.set(value)
            legacy.removeLegacyKey("disableNextVoiceAutoPlay")
        }
        if let value = legacy.bool("forceBuiltInMic") {
            GGVoiceSettings.builtInMicrophone.set(value)
            legacy.removeLegacyKey("forceBuiltInMic")
        }
    }

    /// Keys and files of what is not carried over. The clone models were hundreds of megabytes in
    /// `Documents/voices`, in the iCloud backup: they are removed once, off the main thread.
    private static func dropRemoved(_ legacy: GGLegacyDefaults) {
        for key in ["FontCustomization.useTelegramServerTranscription", "transcriptionBackend", "GG.voiceClone.selectedVoiceId", "GG.voiceClone.cacheDiskLimitMB", "GG.voiceClone.catalog.json", "GG.voiceClone.catalogVersion", "GG.voiceClone.fetchedAt"] {
            legacy.removeLegacyKey(key)
        }
        DispatchQueue.global(qos: .utility).async {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }
            let voices = documents.appendingPathComponent("voices", isDirectory: true)
            if FileManager.default.fileExists(atPath: voices.path) {
                try? FileManager.default.removeItem(at: voices)
            }
        }
    }
}
