import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PromptUI
import GGCore
import GGSettingsUI
import GGFeaturesShared

/// «Медиа и звонки › Голос». Section orders on the skeleton tab start at 300 (100 = preview, 200 = main).
enum GGVoiceMenu {
    static let customTab = GGMenuTabID("voice.custom")
    static let bandsTab = GGMenuTabID("voice.eqBands")

    static let morphSection = GGMenuSectionID("voice.morph")
    static let eqSection = GGMenuSectionID("voice.eq")
    static let transcriptionSection = GGMenuSectionID("voice.transcription")
    static let playbackSection = GGMenuSectionID("voice.playback")

    static func register() {
        GGVoiceMenu.registerPreview()
        GGVoiceMenu.registerMorph()
        GGVoiceMenu.registerCustomVoice()
        GGVoiceMenu.registerEqualizer()
        GGVoiceMenu.registerTranscription()
        GGVoiceMenu.registerPlayback()
    }

    private static func toggle(_ id: String, section: GGMenuSectionID, order: Int, setting: GGSetting<Bool>, title: @escaping () -> String, subtitle: (() -> String)? = nil, isVisible: ((GGMenuContext) -> Bool)? = nil, keywords: @escaping () -> [String] = { [] }) -> GGMenuRow {
        return GGMenuRow(id: id, section: section, order: order, title: title, subtitle: subtitle, kind: .toggle(.global(setting)), isVisible: isVisible, searchKeywords: keywords)
    }

    private static func slider(_ id: String, section: GGMenuSectionID, order: Int, setting: GGSetting<Double>, range: ClosedRange<Double>, step: Double, title: @escaping () -> String, format: @escaping (Double) -> String) -> GGMenuRow {
        return GGMenuRow(id: id, section: section, order: order, title: title, kind: .slider(.global(setting), range: range, step: step, format: format))
    }

    static func signed(_ value: Double, decimals: Bool = false) -> String {
        let rounded = decimals ? (value * 10.0).rounded() / 10.0 : value.rounded()
        let text: String
        if decimals && rounded.truncatingRemainder(dividingBy: 1.0) != 0.0 {
            text = String(format: "%.1f", abs(rounded))
        } else {
            text = String(Int(abs(rounded)))
        }
        if rounded > 0.0 {
            return "+" + text
        } else if rounded < 0.0 {
            return "−" + text
        }
        return text
    }

    static func percent(_ value: Double) -> String {
        return GGStrings.Voice.Unit.percent(value: String(Int(value.rounded())))
    }

    // MARK: Preview

    private static func registerPreview() {
        GGMenuRegistry.register(GGMenuRow(id: "voice.preview", section: .preview(of: .mediaVoice), order: 100, title: { "" }, kind: .preview(.custom(height: 138.0, make: { _ in
            return GGVoicePreviewView(frame: .zero)
        }))))
    }

    // MARK: Voice changer

    private static func registerMorph() {
        let screen = GGMenuScreenID.tab(.mediaVoice)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGVoiceMenu.morphSection, screen: screen, order: 300, header: { GGStrings.Voice.Menu.morphHeader }, footer: { _ in
            return GGStrings.Voice.Menu.morphFooter
        }))
        let morphOn: (GGMenuContext) -> Bool = { _ in
            return GGVoiceSettings.morphEnabled.value
        }
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.morph.enabled", section: GGVoiceMenu.morphSection, order: 100, setting: GGVoiceSettings.morphEnabled, title: { GGStrings.Voice.Menu.morph }, subtitle: { GGStrings.Voice.Menu.morphInfo }, keywords: { [GGStrings.Voice.Menu.keywordMorph, GGStrings.Voice.Menu.keywordAnonymous] }))
        let presetOptions = GGVoicePresetID.allCases.map { preset in
            return GGMenuChoiceOption(value: preset.rawValue, title: { preset.title })
        }
        GGMenuRegistry.register(GGMenuRow(id: "voice.morph.preset", section: GGVoiceMenu.morphSection, order: 200, title: { GGStrings.Voice.Menu.preset }, subtitle: { GGVoicePresets.selectedPreset.subtitle }, kind: .choice(.global(GGVoiceSettings.morphPreset), options: presetOptions), searchKeywords: { [GGStrings.Voice.Menu.keywordMorph] }))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.morph.voiceMessages", section: GGVoiceMenu.morphSection, order: 300, setting: GGVoiceSettings.morphVoiceMessages, title: { GGStrings.Voice.Menu.morphVoiceMessages }, subtitle: { GGStrings.Voice.Menu.morphVoiceMessagesInfo }, isVisible: morphOn))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.morph.roundVideos", section: GGVoiceMenu.morphSection, order: 400, setting: GGVoiceSettings.morphRoundVideos, title: { GGStrings.Voice.Menu.morphRoundVideos }, isVisible: morphOn))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.morph.calls", section: GGVoiceMenu.morphSection, order: 500, setting: GGVoiceSettings.morphCalls, title: { GGStrings.Voice.Menu.morphCalls }, subtitle: { GGStrings.Voice.Menu.morphCallsInfo }, isVisible: morphOn))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGVoiceMenu.customTab, parent: screen, title: { GGStrings.Voice.Custom.title }, topView: GGMenuTopView(content: .emoji("🎛"), text: { GGStrings.Voice.Custom.info }), searchKeywords: { [GGStrings.Voice.Menu.keywordMorph] }), linkIn: GGVoiceMenu.morphSection, order: 600, subtitle: { GGStrings.Voice.Menu.customInfo }, icon: .system("slider.horizontal.3"), label: { _ in
            return GGVoicePresets.selectedPreset == .custom ? GGStrings.Voice.Menu.selected : nil
        })

        // The anonymous mode (W3-2) offers the same presets; its choice overrides, nothing is rewritten.
        GGAnonymousMode.voicePresets.register({
            return GGVoicePresetID.allCases.map { preset in
                return GGAnonymousVoicePreset(id: preset.rawValue, title: { preset.title })
            }
        }, order: 100)
    }

    private static func registerCustomVoice() {
        let screen = GGMenuScreenID.tab(GGVoiceMenu.customTab)
        let pitch = GGMenuSectionID("voice.custom.pitch")
        let tone = GGMenuSectionID("voice.custom.tone")
        let effects = GGMenuSectionID("voice.custom.effects")
        let modulation = GGMenuSectionID("voice.custom.modulation")
        let mix = GGMenuSectionID("voice.custom.mix")
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .main(of: GGVoiceMenu.customTab), screen: screen, order: 200))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: pitch, screen: screen, order: 300, header: { GGStrings.Voice.Custom.pitchHeader }, footer: { _ in GGStrings.Voice.Custom.pitchFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: tone, screen: screen, order: 400, header: { GGStrings.Voice.Custom.toneHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: effects, screen: screen, order: 500, header: { GGStrings.Voice.Custom.effectsHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: modulation, screen: screen, order: 600, header: { GGStrings.Voice.Custom.modulationHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: mix, screen: screen, order: 700, header: { GGStrings.Voice.Custom.mixHeader }, footer: { _ in GGStrings.Voice.Custom.mixFooter }))

        GGMenuRegistry.register(GGMenuRow(id: "voice.custom.name", section: .main(of: GGVoiceMenu.customTab), order: 100, title: { GGStrings.Voice.Custom.name }, kind: .action({ context in
            context.present(promptController(context: context.context, text: GGStrings.Voice.Custom.namePrompt, value: GGVoiceSettings.customName.value, characterLimit: 32, apply: { value in
                if let value {
                    GGVoiceSettings.customName.set(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }))
        }), label: { _ in
            let name = GGVoiceSettings.customName.value
            return name.isEmpty ? nil : name
        }))
        GGMenuRegistry.register(GGMenuRow(id: "voice.custom.use", section: .main(of: GGVoiceMenu.customTab), order: 200, title: { GGStrings.Voice.Custom.use }, kind: .action({ _ in
            GGVoiceSettings.morphPreset.set(GGVoicePresetID.custom.rawValue)
        }), isVisible: { _ in
            return GGVoicePresets.selectedPreset != .custom
        }))

        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.pitch", section: pitch, order: 100, setting: GGVoiceSettings.customPitch, range: -12.0 ... 12.0, step: 0.5, title: { GGStrings.Voice.Custom.pitch }, format: { value in
            return GGStrings.Voice.Unit.semitones(value: GGVoiceMenu.signed(value, decimals: true))
        }))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.timbre", section: pitch, order: 200, setting: GGVoiceSettings.customTimbre, range: -100.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.timbre }, format: { value in
            return GGStrings.Voice.Unit.percent(value: GGVoiceMenu.signed(value))
        }))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.vibratoDepth", section: pitch, order: 300, setting: GGVoiceSettings.customVibratoDepth, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.vibratoDepth }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.vibratoRate", section: pitch, order: 400, setting: GGVoiceSettings.customVibratoRate, range: 0.0 ... 12.0, step: 0.5, title: { GGStrings.Voice.Custom.vibratoRate }, format: { value in
            return GGStrings.Voice.Eq.hertz(value: GGVoiceMenu.signed(value, decimals: true))
        }))

        let decibels: (Double) -> String = { value in
            return GGStrings.Voice.Unit.decibels(value: GGVoiceMenu.signed(value))
        }
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.bass", section: tone, order: 100, setting: GGVoiceSettings.customBass, range: -12.0 ... 12.0, step: 1.0, title: { GGStrings.Voice.Custom.bass }, format: decibels))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.mid", section: tone, order: 200, setting: GGVoiceSettings.customMid, range: -12.0 ... 12.0, step: 1.0, title: { GGStrings.Voice.Custom.mid }, format: decibels))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.treble", section: tone, order: 300, setting: GGVoiceSettings.customTreble, range: -12.0 ... 12.0, step: 1.0, title: { GGStrings.Voice.Custom.treble }, format: decibels))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.custom.telephone", section: tone, order: 400, setting: GGVoiceSettings.customTelephone, title: { GGStrings.Voice.Custom.telephone }))

        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.distortion", section: effects, order: 100, setting: GGVoiceSettings.customDistortion, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.distortion }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.reverb", section: effects, order: 200, setting: GGVoiceSettings.customReverb, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.reverb }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.echo", section: effects, order: 300, setting: GGVoiceSettings.customEcho, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.echo }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.breathiness", section: effects, order: 400, setting: GGVoiceSettings.customBreathiness, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.breathiness }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.compression", section: effects, order: 500, setting: GGVoiceSettings.customCompression, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.compression }, format: GGVoiceMenu.percent))

        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.chorus", section: modulation, order: 100, setting: GGVoiceSettings.customChorus, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.chorus }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.flanger", section: modulation, order: 200, setting: GGVoiceSettings.customFlanger, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.flanger }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.ringMod", section: modulation, order: 300, setting: GGVoiceSettings.customRingMod, range: 0.0 ... 1000.0, step: 10.0, title: { GGStrings.Voice.Custom.ringMod }, format: { value in
            return value < 1.0 ? GGStrings.Voice.Unit.off : GGStrings.Voice.Eq.hertz(value: String(Int(value.rounded())))
        }))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.bitcrush", section: modulation, order: 400, setting: GGVoiceSettings.customBitcrush, range: 2.0 ... 16.0, step: 1.0, title: { GGStrings.Voice.Custom.bitcrush }, format: { value in
            return value >= 15.5 ? GGStrings.Voice.Unit.off : GGStrings.Voice.Unit.bits(value: String(Int(value.rounded())))
        }))

        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.gain", section: mix, order: 100, setting: GGVoiceSettings.customGain, range: -12.0 ... 12.0, step: 1.0, title: { GGStrings.Voice.Custom.gain }, format: decibels))
        GGMenuRegistry.register(GGVoiceMenu.slider("voice.custom.wet", section: mix, order: 200, setting: GGVoiceSettings.customWet, range: 0.0 ... 100.0, step: 5.0, title: { GGStrings.Voice.Custom.wet }, format: GGVoiceMenu.percent))
        GGMenuRegistry.register(GGMenuRow(id: "voice.custom.reset", section: mix, order: 300, title: { GGStrings.Voice.Custom.reset }, kind: .action({ _ in
            GGVoiceMenu.resetCustomVoice()
        }), isDestructive: true))
    }

    private static func resetCustomVoice() {
        GGVoiceSettings.customPitch.reset()
        GGVoiceSettings.customTimbre.reset()
        GGVoiceSettings.customBass.reset()
        GGVoiceSettings.customMid.reset()
        GGVoiceSettings.customTreble.reset()
        GGVoiceSettings.customGain.reset()
        GGVoiceSettings.customDistortion.reset()
        GGVoiceSettings.customReverb.reset()
        GGVoiceSettings.customEcho.reset()
        GGVoiceSettings.customCompression.reset()
        GGVoiceSettings.customBreathiness.reset()
        GGVoiceSettings.customChorus.reset()
        GGVoiceSettings.customFlanger.reset()
        GGVoiceSettings.customVibratoDepth.reset()
        GGVoiceSettings.customVibratoRate.reset()
        GGVoiceSettings.customRingMod.reset()
        GGVoiceSettings.customBitcrush.reset()
        GGVoiceSettings.customTelephone.reset()
        GGVoiceSettings.customWet.reset()
    }

    // MARK: Equalizer

    private static func registerEqualizer() {
        let screen = GGMenuScreenID.tab(.mediaVoice)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGVoiceMenu.eqSection, screen: screen, order: 400, header: { GGStrings.Voice.Eq.header }, footer: { _ in GGStrings.Voice.Eq.footer }))
        let eqOn: (GGMenuContext) -> Bool = { _ in
            return GGVoiceSettings.eqEnabled.value
        }
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.eq.enabled", section: GGVoiceMenu.eqSection, order: 100, setting: GGVoiceSettings.eqEnabled, title: { GGStrings.Voice.Eq.enabled }, keywords: { [GGStrings.Voice.Eq.keyword] }))
        let presetOptions = GGVoiceEqualizer.Preset.allCases.map { preset in
            return GGMenuChoiceOption(value: preset.rawValue, title: { preset.title })
        }
        GGMenuRegistry.register(GGMenuRow(id: "voice.eq.preset", section: GGVoiceMenu.eqSection, order: 200, title: { GGStrings.Voice.Eq.preset }, kind: .choice(.global(GGVoiceSettings.eqPreset), options: presetOptions), isVisible: eqOn, searchKeywords: { [GGStrings.Voice.Eq.keyword] }))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGVoiceMenu.bandsTab, parent: screen, title: { GGStrings.Voice.Eq.bandsTitle }, topView: GGMenuTopView(content: .emoji("🎚"), text: { GGStrings.Voice.Eq.bandsInfo }), searchKeywords: { [GGStrings.Voice.Eq.keyword] }), linkIn: GGVoiceMenu.eqSection, order: 300, subtitle: { GGStrings.Voice.Eq.bandsSubtitle }, icon: .system("slider.vertical.3"), label: { _ in
            return GGVoiceSettings.eqEnabled.value ? GGVoiceEqualizer.Preset(rawValue: GGVoiceSettings.eqPreset.value)?.title : nil
        })
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.eq.audio", section: GGVoiceMenu.eqSection, order: 400, setting: GGVoiceSettings.eqAudio, title: { GGStrings.Voice.Eq.audio }, isVisible: eqOn))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.eq.roundVideos", section: GGVoiceMenu.eqSection, order: 500, setting: GGVoiceSettings.eqRoundVideos, title: { GGStrings.Voice.Eq.roundVideos }, isVisible: eqOn))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.eq.videos", section: GGVoiceMenu.eqSection, order: 600, setting: GGVoiceSettings.eqVideos, title: { GGStrings.Voice.Eq.videos }, isVisible: eqOn))

        let decibels: (Double) -> String = { value in
            return GGStrings.Voice.Unit.decibels(value: GGVoiceMenu.signed(value))
        }
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .main(of: GGVoiceMenu.bandsTab), screen: .tab(GGVoiceMenu.bandsTab), order: 200, footer: { _ in GGStrings.Voice.Eq.bandsFooter }))
        for (index, setting) in GGVoiceSettings.eqBands.enumerated() {
            GGMenuRegistry.register(GGVoiceMenu.slider("voice.eq.band\(index)", section: .main(of: GGVoiceMenu.bandsTab), order: 100 + index * 100, setting: setting, range: -12.0 ... 12.0, step: 1.0, title: { GGVoiceEqualizer.bandTitle(index) }, format: decibels))
        }
    }

    // MARK: Transcription

    private static func registerTranscription() {
        let screen = GGMenuScreenID.tab(.mediaVoice)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGVoiceMenu.transcriptionSection, screen: screen, order: 500, header: { GGStrings.Voice.Transcription.header }, footer: { context in
            return context.context.isPremium ? GGStrings.Voice.Transcription.footerPremium : GGStrings.Voice.Transcription.footerApple
        }))
        let autoOn: (GGMenuContext) -> Bool = { _ in
            return GGVoiceSettings.autoTranscribe.value
        }
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.wordBubbles", section: GGVoiceMenu.transcriptionSection, order: 100, setting: GGVoiceSettings.wordBubbles, title: { GGStrings.Voice.Transcription.wordBubbles }, subtitle: { GGStrings.Voice.Transcription.wordBubblesInfo }, keywords: { [GGStrings.Voice.Transcription.keyword] }))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.autoTranscribe.enabled", section: GGVoiceMenu.transcriptionSection, order: 200, setting: GGVoiceSettings.autoTranscribe, title: { GGStrings.Voice.AutoTranscribe.enabled }, subtitle: { GGStrings.Voice.AutoTranscribe.enabledInfo }, keywords: { [GGStrings.Voice.Transcription.keyword] }))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.autoTranscribe.roundVideos", section: GGVoiceMenu.transcriptionSection, order: 300, setting: GGVoiceSettings.autoTranscribeRoundVideos, title: { GGStrings.Voice.AutoTranscribe.roundVideos }, isVisible: autoOn))
        let formatOptions = GGTranscriptionFormat.allCases.map { format in
            return GGMenuChoiceOption(value: format.rawValue, title: { format.title })
        }
        GGMenuRegistry.register(GGMenuRow(id: "voice.autoTranscribe.format", section: GGVoiceMenu.transcriptionSection, order: 400, title: { GGStrings.Voice.AutoTranscribe.format }, subtitle: { GGStrings.Voice.AutoTranscribe.formatExample(format: (GGTranscriptionFormat(rawValue: GGVoiceSettings.autoTranscribeFormat.value) ?? .quote).title) }, kind: .choice(.global(GGVoiceSettings.autoTranscribeFormat), options: formatOptions), isVisible: autoOn))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.autoTranscribe.translate", section: GGVoiceMenu.transcriptionSection, order: 500, setting: GGVoiceSettings.autoTranscribeTranslate, title: { GGStrings.Voice.AutoTranscribe.translate }, isVisible: autoOn))
        var languageOptions = [GGMenuChoiceOption(value: "", title: { GGStrings.Voice.AutoTranscribe.languageTelegram })]
        for code in GGVoiceMenu.translationLanguages {
            languageOptions.append(GGMenuChoiceOption(value: code, title: { GGVoiceMenu.languageName(code) }))
        }
        GGMenuRegistry.register(GGMenuRow(id: "voice.autoTranscribe.language", section: GGVoiceMenu.transcriptionSection, order: 600, title: { GGStrings.Voice.AutoTranscribe.language }, kind: .choice(.global(GGVoiceSettings.autoTranscribeLanguage), options: languageOptions), isVisible: { _ in
            return GGVoiceSettings.autoTranscribe.value && GGVoiceSettings.autoTranscribeTranslate.value
        }))
    }

    /// Language codes of the translation target (names come from the system, in Ghostgram's language).
    static let translationLanguages = ["en", "ru", "uk", "be", "kk", "uz", "de", "fr", "es", "it", "pt", "pl", "tr", "ar", "fa", "he", "hi", "id", "ja", "ko", "zh"]

    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: GGLocalization.shared.languageCode)
        guard let name = locale.localizedString(forLanguageCode: code) else {
            return code
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Playback and recording

    private static func registerPlayback() {
        let screen = GGMenuScreenID.tab(.mediaVoice)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGVoiceMenu.playbackSection, screen: screen, order: 600, header: { GGStrings.Voice.Playback.header }, footer: { _ in GGStrings.Voice.Playback.footer }))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.disableAutoplay", section: GGVoiceMenu.playbackSection, order: 100, setting: GGVoiceSettings.disableAutoplay, title: { GGStrings.Voice.Playback.disableAutoplay }, subtitle: { GGStrings.Voice.Playback.disableAutoplayInfo }))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.builtInMicrophone", section: GGVoiceMenu.playbackSection, order: 200, setting: GGVoiceSettings.builtInMicrophone, title: { GGStrings.Voice.Playback.builtInMicrophone }, subtitle: { GGStrings.Voice.Playback.builtInMicrophoneInfo }, keywords: { [GGStrings.Voice.Playback.keywordMicrophone] }))
        GGMenuRegistry.register(GGVoiceMenu.toggle("voice.keepMusic", section: GGVoiceMenu.playbackSection, order: 300, setting: GGVoiceSettings.keepMusicMirror, title: { GGStrings.Voice.Playback.keepMusic }, subtitle: { GGStrings.Voice.Playback.keepMusicInfo }))
    }
}
