import Foundation
import GGCore
import GGFeaturesShared

/// One sound of the call soundboard. The file lives in the soundboard directory (`GGCallSoundLibrary`);
/// only these metadata are in the settings registry.
struct GGCallSoundItem: Codable, Equatable, GGSettingValue {
    var id: String
    var title: String
    var fileName: String
    /// A sound imported by the old Ghostgram: the file is still in its old `Documents/ggcall/soundboard`.
    var isLegacy: Bool
    var createdAt: Double
}

/// One saved call recording of an account. The file is in that account's recordings directory.
struct GGCallRecordingItem: Codable, Equatable, GGSettingValue {
    enum Kind: String, Codable {
        case audio
        case video
    }

    var id: String
    var fileName: String
    var kind: Kind
    /// Peer of the 1:1 call (canonical key) and its name at the time of the call.
    var peer: GGPeerKey?
    var peerTitle: String
    var startDate: Double
    var duration: Double
    var size: Int64
}

enum GGDownloadBoostMode: String {
    case off
    case medium
    case maximum
}

/// Every setting of the zone. Declared once here; defaults only here.
enum GGCallsMediaSettings {
    // MARK: Calls

    /// `GGCallRecordingMode.rawValue` (one choice since 2026-10-27; replaced «аудиозвонки» / «видеозвонки»).
    static let recordCalls = GGSetting<String>("calls.record", default: GGCallRecordingMode.off.rawValue)
    static let recordOwnVoice = GGSetting<Bool>("calls.recordOwnVoice", default: false)
    static let silentMute = GGSetting<Bool>("calls.silentMute", default: false)
    static let disableRating = GGSetting<Bool>("calls.disableRating", default: false)
    static let statsOverlay = GGSetting<Bool>("calls.statsOverlay", default: false)
    /// Origin of the dragged stats panel, `[x, y]` relative to the screen; empty = default corner.
    static let statsPanelOrigin = GGSetting<[Double]>("calls.statsPanelOrigin", default: [], flags: [.noExport])
    static let soundboard = GGSetting<Bool>("calls.soundboard", default: false)
    /// 0.1…1.0.
    static let soundboardVolume = GGSetting<Double>("calls.soundboardVolume", default: 0.8)
    static let soundboardDuck = GGSetting<Bool>("calls.soundboardDuck", default: false)
    /// Files stay on this device, so the list is not exported.
    static let soundboardItems = GGSetting<[GGCallSoundItem]>("calls.soundboardItems", default: [], flags: [.noExport])
    static let forceTcp = GGSetting<Bool>("calls.forceTcp", default: false)
    /// Recordings of the account (files in the account's directory).
    static let recordings = GGAccountSetting<[GGCallRecordingItem]>("calls.recordings", default: [], flags: [.noExport])

    /// What «Записывать звонки» is set to.
    static var recordingMode: GGCallRecordingMode {
        return GGCallRecordingMode.resolved(GGCallsMediaSettings.recordCalls.value)
    }

    // MARK: Downloads and quality

    static let statusInChatList = GGSetting<Bool>("downloads.statusInChatList", default: false)
    static let statusInChat = GGSetting<Bool>("downloads.statusInChat", default: false)
    static let uploadBoost = GGSetting<Bool>("downloads.uploadBoost", default: false)
    /// `GGDownloadBoostMode` raw value.
    static let downloadBoost = GGSetting<String>("downloads.downloadBoost", default: GGDownloadBoostMode.off.rawValue)
    /// Declared in GGFeaturesShared (App Group): the share extension follows them too.
    static let photoQuality = GGOutgoingPhotoSettings.quality
    static let largePhotos = GGOutgoingPhotoSettings.largePhotos

    // MARK: Gallery

    /// On by default: Swiftgram adds both items always (W6-SGD, owner's decision 2026-10-29).
    static let copyPhotoItem = GGSetting<Bool>("gallery.copyPhoto", default: true)
    static let airPlayItem = GGSetting<Bool>("gallery.airPlay", default: true)

    // MARK: Subtitles

    static let subtitles = GGSetting<Bool>("subtitles.enabled", default: false)
    static let subtitlesTranslate = GGSetting<Bool>("subtitles.translate", default: false)
    /// Target language code; "" = the language of the app.
    static let subtitlesLanguage = GGSetting<String>("subtitles.language", default: "")

    static func declare() {
        let _ = GGCallsMediaSettings.recordCalls
        let _ = GGCallsMediaSettings.recordOwnVoice
        let _ = GGCallsMediaSettings.silentMute
        let _ = GGCallsMediaSettings.disableRating
        let _ = GGCallsMediaSettings.statsOverlay
        let _ = GGCallsMediaSettings.statsPanelOrigin
        let _ = GGCallsMediaSettings.soundboard
        let _ = GGCallsMediaSettings.soundboardVolume
        let _ = GGCallsMediaSettings.soundboardDuck
        let _ = GGCallsMediaSettings.soundboardItems
        let _ = GGCallsMediaSettings.forceTcp
        let _ = GGCallsMediaSettings.recordings

        let _ = GGCallsMediaSettings.statusInChatList
        let _ = GGCallsMediaSettings.statusInChat
        let _ = GGCallsMediaSettings.uploadBoost
        let _ = GGCallsMediaSettings.downloadBoost
        let _ = GGCallsMediaSettings.photoQuality
        let _ = GGCallsMediaSettings.largePhotos

        let _ = GGCallsMediaSettings.copyPhotoItem
        let _ = GGCallsMediaSettings.airPlayItem

        let _ = GGCallsMediaSettings.subtitles
        let _ = GGCallsMediaSettings.subtitlesTranslate
        let _ = GGCallsMediaSettings.subtitlesLanguage
    }
}
