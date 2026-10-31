import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import GGCore
import GGSettingsUI

/// The zone's menu: «Медиа и звонки › Звонки / Загрузки и качество» and the «Субтитры к видео»
/// section of «Сообщения › Перевод». Section orders on the skeleton tabs start at 300 (100 and 200
/// are the skeleton's preview and main sections); masks in calls (W3-2) use 800+. «Лента» and the
/// music status were removed by the owner on 2026-10-27 (with their tab «Лента и музыка»).
enum GGCallsMediaMenu {
    static let recordingsTab = GGMenuTabID("calls.recordings")
    static let soundsTab = GGMenuTabID("calls.sounds")

    static func register() {
        GGCallsMediaMenu.registerCalls()
        GGCallsMediaMenu.registerDownloads()
        GGCallsMediaMenu.registerSubtitles()
    }

    private static func toggle(_ id: String, section: GGMenuSectionID, order: Int, setting: GGSetting<Bool>, title: @escaping () -> String, subtitle: (() -> String)? = nil, isVisible: ((GGMenuContext) -> Bool)? = nil, keywords: @escaping () -> [String] = { [] }) -> GGMenuRow {
        return GGMenuRow(id: id, section: section, order: order, title: title, subtitle: subtitle, kind: .toggle(.global(setting)), isVisible: isVisible, searchKeywords: keywords)
    }

    // MARK: Calls

    private static func registerCalls() {
        let screen = GGMenuScreenID.tab(.mediaCalls)
        let recording = GGMenuSectionID("calls.recording")
        let microphone = GGMenuSectionID("calls.microphone")
        let callScreen = GGMenuSectionID("calls.screen")
        let sounds = GGMenuSectionID("calls.soundboard")
        let network = GGMenuSectionID("calls.network")

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: recording, screen: screen, order: 300, header: { GGStrings.Calls.Menu.recordingHeader }, footer: { _ in GGStrings.Calls.Menu.recordingFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: microphone, screen: screen, order: 400, header: { GGStrings.Calls.Menu.microphoneHeader }, footer: { _ in GGStrings.Calls.Menu.silentMuteFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: callScreen, screen: screen, order: 500, header: { GGStrings.Calls.Menu.screenHeader }, footer: { _ in GGStrings.Calls.Menu.screenFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: sounds, screen: screen, order: 600, header: { GGStrings.Calls.Menu.soundboardHeader }, footer: { _ in GGStrings.Calls.Menu.soundboardFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: network, screen: screen, order: 700, header: { GGStrings.Calls.Menu.networkHeader }, footer: { _ in GGStrings.Calls.Menu.forceTcpFooter }))

        let isRecording: (GGMenuContext) -> Bool = { _ in
            return GGCallsMediaSettings.recordingMode.isOn
        }
        // One choice instead of «аудиозвонки» + «видеозвонки» (2026-10-27).
        GGMenuRegistry.register(GGMenuRow(id: "calls.record", section: recording, order: 100, title: { GGStrings.Calls.Menu.record }, subtitle: { GGStrings.Calls.Menu.recordInfo }, kind: .choice(.global(GGCallsMediaSettings.recordCalls), options: [
            GGMenuChoiceOption(value: GGCallRecordingMode.off.rawValue, title: { GGStrings.Calls.Menu.recordOff }),
            GGMenuChoiceOption(value: GGCallRecordingMode.audio.rawValue, title: { GGStrings.Calls.Menu.recordAudioOnly }),
            GGMenuChoiceOption(value: GGCallRecordingMode.audioAndVideo.rawValue, title: { GGStrings.Calls.Menu.recordAudioAndVideo })
        ]), searchKeywords: { [GGStrings.Calls.Menu.keywordRecording] }))
        GGMenuRegistry.register(toggle("calls.recordOwnVoice", section: recording, order: 200, setting: GGCallsMediaSettings.recordOwnVoice, title: { GGStrings.Calls.Menu.recordOwnVoice }, isVisible: isRecording))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGCallsMediaMenu.recordingsTab, parent: screen, title: { GGStrings.Calls.Recordings.title }, makeScreen: { context in
            return ggMakeCallRecordingsScreen(menuContext: context)
        }), linkIn: recording, order: 400, subtitle: { GGStrings.Calls.Menu.recordingsInfo }, icon: .bundle("Chat/Context Menu/VoiceChat"), label: { context in
            return GGStrings.Calls.Menu.recordingsCount(count: GGCallsMediaSettings.recordings.value(for: context.accountID).count)
        })

        GGMenuRegistry.register(toggle("calls.silentMute", section: microphone, order: 100, setting: GGCallsMediaSettings.silentMute, title: { GGStrings.Calls.Menu.silentMute }, subtitle: { GGStrings.Calls.Menu.silentMuteInfo }))

        GGMenuRegistry.register(toggle("calls.disableRating", section: callScreen, order: 100, setting: GGCallsMediaSettings.disableRating, title: { GGStrings.Calls.Menu.disableRating }))
        GGMenuRegistry.register(toggle("calls.statsOverlay", section: callScreen, order: 200, setting: GGCallsMediaSettings.statsOverlay, title: { GGStrings.Calls.Menu.statsOverlay }, subtitle: { GGStrings.Calls.Menu.statsOverlayInfo }))

        let soundboardOn: (GGMenuContext) -> Bool = { _ in
            return GGCallsMediaSettings.soundboard.value
        }
        GGMenuRegistry.register(toggle("calls.soundboard", section: sounds, order: 100, setting: GGCallsMediaSettings.soundboard, title: { GGStrings.Calls.Menu.soundboard }, keywords: { [GGStrings.Calls.Menu.keywordSounds] }))
        GGMenuRegistry.register(GGMenuRow(id: "calls.soundboardVolume", section: sounds, order: 200, title: { GGStrings.Calls.Menu.soundboardVolume }, kind: .slider(.global(GGCallsMediaSettings.soundboardVolume), range: 0.1 ... 1.0, step: 0.05, format: { value in
            return "\(Int((value * 100.0).rounded())) %"
        }), isVisible: soundboardOn))
        GGMenuRegistry.register(toggle("calls.soundboardDuck", section: sounds, order: 300, setting: GGCallsMediaSettings.soundboardDuck, title: { GGStrings.Calls.Menu.soundboardDuck }, subtitle: { GGStrings.Calls.Menu.soundboardDuckInfo }, isVisible: soundboardOn))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGCallsMediaMenu.soundsTab, parent: screen, title: { GGStrings.Calls.Sounds.title }, makeScreen: { context in
            return ggMakeSoundLibraryScreen(menuContext: context)
        }), linkIn: sounds, order: 400, subtitle: { GGStrings.Calls.Menu.soundsInfo }, icon: .bundle("Chat/Context Menu/AddMusic"), label: { _ in
            return GGStrings.Calls.Menu.soundsCount(count: GGCallsMediaSettings.soundboardItems.value.count)
        })

        GGMenuRegistry.register(toggle("calls.forceTcp", section: network, order: 100, setting: GGCallsMediaSettings.forceTcp, title: { GGStrings.Calls.Menu.forceTcp }))
    }

    // MARK: Downloads and quality

    private static func registerDownloads() {
        let screen = GGMenuScreenID.tab(.mediaDownloads)
        let status = GGMenuSectionID("downloads.status")
        let boost = GGMenuSectionID("downloads.boost")
        let photos = GGMenuSectionID("downloads.photos")
        let gallery = GGMenuSectionID("downloads.gallery")

        GGMenuRegistry.register(GGMenuRow(id: "downloads.preview", section: .preview(of: .mediaDownloads), order: 100, title: { "" }, kind: .preview(.miniChatList(GGMiniChatListConfiguration(scope: "downloads", height: 152.0, rows: { _ in
            var rows = Array(GGPreviewChatListRow.samples().prefix(2))
            if GGCallsMediaSettings.statusInChatList.value, !rows.isEmpty {
                rows[0].text = "⬇︎ " + GGStrings.Downloads.Preview.fileName + " · 42 %"
                rows[0].isTyping = false
            }
            return rows
        })))))

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: status, screen: screen, order: 300, header: { GGStrings.Downloads.Menu.statusHeader }, footer: { _ in GGStrings.Downloads.Menu.statusFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: boost, screen: screen, order: 400, header: { GGStrings.Downloads.Menu.boostHeader }, footer: { _ in GGStrings.Downloads.Menu.boostFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: photos, screen: screen, order: 500, header: { GGStrings.Downloads.Menu.photosHeader }, footer: { _ in GGStrings.Downloads.Menu.photosFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: gallery, screen: screen, order: 600, header: { GGStrings.Downloads.Menu.galleryHeader }, footer: { _ in GGStrings.Downloads.Menu.galleryFooter }))

        GGMenuRegistry.register(toggle("downloads.statusInChatList", section: status, order: 100, setting: GGCallsMediaSettings.statusInChatList, title: { GGStrings.Downloads.Menu.statusInChatList }))
        GGMenuRegistry.register(toggle("downloads.statusInChat", section: status, order: 200, setting: GGCallsMediaSettings.statusInChat, title: { GGStrings.Downloads.Menu.statusInChat }))

        // Both boosts ask once before they switch on: the server may answer with flood waits.
        GGMenuRegistry.register(GGMenuRow(id: "downloads.uploadBoost", section: boost, order: 100, title: { GGStrings.Downloads.Menu.uploadBoost }, kind: .custom({ context in
            return ItemListSwitchItem(presentationData: context.itemListPresentationData, systemStyle: .glass, title: GGStrings.Downloads.Menu.uploadBoost, value: GGCallsMediaSettings.uploadBoost.value, enableInteractiveChanges: false, maximumNumberOfLines: 2, sectionId: context.sectionId, style: .blocks, updated: { value in
                if value {
                    GGCallsMediaMenu.confirmBoost(context: context, apply: {
                        GGCallsMediaSettings.uploadBoost.set(true)
                    })
                } else {
                    GGCallsMediaSettings.uploadBoost.set(false)
                }
            })
        }), searchKeywords: { [GGStrings.Downloads.Menu.keywordSpeed] }))
        GGMenuRegistry.register(GGMenuRow(id: "downloads.downloadBoost", section: boost, order: 200, title: { GGStrings.Downloads.Menu.downloadBoost }, kind: .action({ context in
            GGCallsMediaMenu.chooseDownloadBoost(context: context)
        }), searchKeywords: { [GGStrings.Downloads.Menu.keywordSpeed] }, label: { _ in
            return GGCallsMediaMenu.downloadBoostTitle(GGDownloadBoostMode(rawValue: GGCallsMediaSettings.downloadBoost.value) ?? .off)
        }))

        var qualityOptions = [GGMenuChoiceOption(value: "", title: { GGStrings.Downloads.Menu.photoQualityDefault })]
        for value in ["60", "70", "80", "90", "100"] {
            qualityOptions.append(GGMenuChoiceOption(value: value, title: { value + " %" }))
        }
        GGMenuRegistry.register(GGMenuRow(id: "downloads.photoQuality", section: photos, order: 100, title: { GGStrings.Downloads.Menu.photoQuality }, kind: .choice(.global(GGCallsMediaSettings.photoQuality), options: qualityOptions)))
        GGMenuRegistry.register(toggle("downloads.largePhotos", section: photos, order: 200, setting: GGCallsMediaSettings.largePhotos, title: { GGStrings.Downloads.Menu.largePhotos }, subtitle: { GGStrings.Downloads.Menu.largePhotosInfo }))

        GGMenuRegistry.register(toggle("gallery.copyPhoto", section: gallery, order: 100, setting: GGCallsMediaSettings.copyPhotoItem, title: { GGStrings.Gallery.Menu.copyPhoto }))
        GGMenuRegistry.register(toggle("gallery.airPlay", section: gallery, order: 200, setting: GGCallsMediaSettings.airPlayItem, title: { GGStrings.Gallery.Menu.airPlay }, subtitle: { GGStrings.Gallery.Menu.airPlayInfo }))
    }

    private static func confirmBoost(context: GGMenuContext, apply: @escaping () -> Void) {
        let presentationData = context.presentationData
        context.present(textAlertController(context: context.context, title: GGStrings.Downloads.Boost.warningTitle, text: GGStrings.Downloads.Boost.warningText, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: GGStrings.Downloads.Boost.warningConfirm, action: {
                apply()
            })
        ]))
    }

    private static func downloadBoostTitle(_ mode: GGDownloadBoostMode) -> String {
        switch mode {
        case .off:
            return GGStrings.Downloads.Boost.off
        case .medium:
            return GGStrings.Downloads.Boost.medium
        case .maximum:
            return GGStrings.Downloads.Boost.maximum
        }
    }

    private static func chooseDownloadBoost(context: GGMenuContext) {
        let current = GGDownloadBoostMode(rawValue: GGCallsMediaSettings.downloadBoost.value) ?? .off
        var actions: [(title: String, isDestructive: Bool, action: () -> Void)] = []
        for mode in [GGDownloadBoostMode.off, .medium, .maximum] {
            let title = (mode == current ? "✓ " : "") + GGCallsMediaMenu.downloadBoostTitle(mode)
            actions.append((title, false, {
                if mode == .off || current != .off {
                    GGCallsMediaSettings.downloadBoost.set(mode.rawValue)
                } else {
                    GGCallsMediaMenu.confirmBoost(context: context, apply: {
                        GGCallsMediaSettings.downloadBoost.set(mode.rawValue)
                    })
                }
            }))
        }
        ggPresentMediaActionSheet(context: context.context, title: GGStrings.Downloads.Menu.downloadBoost, actions: actions, present: { context.present($0) })
    }

    // MARK: Subtitles

    private static func registerSubtitles() {
        let section = GGMenuSectionID("subtitles.main")
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: section, screen: .tab(.messagesTranslation), order: 400, header: { GGStrings.Subtitles.Menu.header }, footer: { _ in GGStrings.Subtitles.Menu.footer }))
        GGMenuRegistry.register(toggle("subtitles.enabled", section: section, order: 100, setting: GGCallsMediaSettings.subtitles, title: { GGStrings.Subtitles.Menu.enabled }, subtitle: { GGStrings.Subtitles.Menu.enabledInfo }, keywords: { [GGStrings.Subtitles.Menu.keyword] }))
        GGMenuRegistry.register(toggle("subtitles.translate", section: section, order: 200, setting: GGCallsMediaSettings.subtitlesTranslate, title: { GGStrings.Subtitles.Menu.translate }, isVisible: { _ in GGCallsMediaSettings.subtitles.value }))
        var options = [GGMenuChoiceOption(value: "", title: { GGStrings.Subtitles.Menu.languageAuto })]
        for code in ["en", "ru", "uk", "be", "kk", "de", "fr", "es", "it", "pt", "pl", "tr", "ar", "fa", "he", "hi", "zh", "ja", "ko"] {
            options.append(GGMenuChoiceOption(value: code, title: {
                // Language names come from the system in the language of the interface.
                let interface = Locale(identifier: GGLocalization.shared.languageCode)
                return interface.localizedString(forLanguageCode: code) ?? code
            }))
        }
        GGMenuRegistry.register(GGMenuRow(id: "subtitles.language", section: section, order: 300, title: { GGStrings.Subtitles.Menu.language }, kind: .choice(.global(GGCallsMediaSettings.subtitlesLanguage), options: options), isVisible: { _ in GGCallsMediaSettings.subtitles.value && GGCallsMediaSettings.subtitlesTranslate.value }))
    }
}
