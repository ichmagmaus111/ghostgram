import Foundation
import GGCore
import GGCameraPipeline
import GGFeaturesShared

/// One-time moves of the old app's settings of this zone. Only values the user really stored are
/// moved (a missing key keeps the new default, which is Telegram's behaviour). Files (own masks,
/// virtual camera media) are moved separately, off the launch thread, by the stores.
enum GGCameraMasksMigrations {
    static func register() {
        GGMigrations.registerGlobal(id: "cameraMasks.roundVideo.v1", GGCameraMasksMigrations.migrateRoundVideo)
        GGMigrations.registerGlobal(id: "cameraMasks.photoWatermark.v1", GGCameraMasksMigrations.migratePhotoWatermark)
        GGMigrations.registerGlobal(id: "cameraMasks.masks.v1", GGCameraMasksMigrations.migrateMasks)
        GGMigrations.registerGlobal(id: "cameraMasks.virtualCamera.v1", GGCameraMasksMigrations.migrateVirtualCamera)
        // Repairs of what builds up to 13.0 (190) carried over (MEDIA-11, MEDIA-13).
        GGMigrations.registerGlobal(id: "cameraMasks.photoWatermark.appGroup.v1", GGCameraMasksMigrations.movePhotoWatermarkToAppGroup)
        GGMigrations.registerGlobal(id: "cameraMasks.roundVideo.halfZoom.v1", GGCameraMasksMigrations.repairStartZoom)
        GGMigrations.registerGlobal(id: "cameraMasks.masks.catalogSelection.v1", GGCameraMasksMigrations.dropUnavailableCatalogMasks)
    }

    // MARK: Helpers

    private static func moveBool(_ legacy: GGLegacyDefaults, _ key: String, _ setting: GGSetting<Bool>) {
        if let value = legacy.bool(key) {
            setting.set(value)
        }
        legacy.removeLegacyKey(key)
    }

    private static func moveText(_ legacy: GGLegacyDefaults, _ key: String, _ setting: GGSetting<String>, limit: Int) {
        if let value = legacy.string(key) {
            setting.set(String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)))
        }
        legacy.removeLegacyKey(key)
    }

    private static func moveNumber(_ legacy: GGLegacyDefaults, _ key: String, _ setting: GGSetting<Double>, range: ClosedRange<Double>) {
        if let value = legacy.double(key) {
            setting.set(min(range.upperBound, max(range.lowerBound, value.rounded())))
        }
        legacy.removeLegacyKey(key)
    }

    /// An old integer code → the new string value; unknown codes keep the default.
    private static func moveCode(_ legacy: GGLegacyDefaults, _ key: String, _ setting: GGSetting<String>, _ map: [Int: String]) {
        if let code = legacy.int(key), let value = map[code] {
            setting.set(value)
        }
        legacy.removeLegacyKey(key)
    }

    private static let fontCodes: [Int: String] = [0: GGWatermarkFont.regular.rawValue, 1: GGWatermarkFont.bold.rawValue, 2: GGWatermarkFont.mono.rawValue, 3: GGWatermarkFont.italic.rawValue]
    private static let colorCodes: [Int: String] = [0: GGWatermarkColor.white.rawValue, 1: GGWatermarkColor.black.rawValue, 2: GGWatermarkColor.red.rawValue, 3: GGWatermarkColor.yellow.rawValue]

    // MARK: Round videos (`RoundVideo.*`, two `MiscSettings.*` keys)

    private static func migrateRoundVideo(_ legacy: GGLegacyDefaults) {
        // 400 is Telegram's own side; 720 was offered but is above what the server takes as a
        // round video, so it becomes the largest side that still is one.
        if let side = legacy.int("RoundVideo.resolution") {
            switch side {
            case 512:
                GGRoundVideoSettings.resolution.set("512")
            case 640, 720:
                GGRoundVideoSettings.resolution.set("640")
            default:
                break
            }
        }
        legacy.removeLegacyKey("RoundVideo.resolution")
        // 1000 kbit/s was the old default and is Telegram's own rate: it stays «standard».
        if let kbps = legacy.int("RoundVideo.bitrateKbps"), kbps != 1000 {
            GGRoundVideoSettings.bitrate.set(min(4000.0, max(500.0, (Double(kbps) / 500.0).rounded() * 500.0)))
        }
        legacy.removeLegacyKey("RoundVideo.bitrateKbps")
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.fps", GGRoundVideoSettings.frameRate, [60: "60"])
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.codec", GGRoundVideoSettings.codec, [1: GGRoundVideoCodec.hevc.rawValue])
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.stabilization", GGRoundVideoSettings.stabilization, [0: GGRoundVideoStabilization.off.rawValue, 2: GGRoundVideoStabilization.cinematic.rawValue])
        // Code 0 (start at 0.5×) is «0,5× на задней камере» here: 0.5× exists only on the back camera.
        if legacy.int("RoundVideo.startZoom") == 0 {
            GGRoundVideoSettings.rearHalfZoom.set(true)
        }
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.startZoom", GGRoundVideoSettings.startZoom, [2: GGRoundVideoStartZoom.two.rawValue, 3: GGRoundVideoStartZoom.last.rawValue])
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.rememberZoom", GGRoundVideoSettings.rememberZoom)
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.zoomSlider", GGRoundVideoSettings.zoomSlider)
        if let zoom = legacy.double("RoundVideo.lastZoomFactor") {
            GGRoundVideoSettings.lastZoom.set(min(GGRoundVideoConfig.maximumZoom, max(0.5, zoom)))
        }
        legacy.removeLegacyKey("RoundVideo.lastZoomFactor")
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.sendAsRegularVideo", GGRoundVideoSettings.sendAsRegularVideo)
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.countdownEnabled", GGRoundVideoSettings.countdown)
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.viewOnceByDefault", GGRoundVideoSettings.viewOnceByDefault)
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.saveCopyToGallery", GGRoundVideoSettings.saveCopyToGallery)
        // Code 0 («video recording») was the old default; the new default leaves the session as
        // Telegram sets it, so only the explicit «conversation» choice is carried over.
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.micMode", GGRoundVideoSettings.microphoneMode, [1: GGRoundVideoMicrophoneMode.voiceChat.rawValue])
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.normalizeAudio", GGRoundVideoSettings.normalizeAudio)
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.muteAudio", GGRoundVideoSettings.muteAudio)
        GGCameraMasksMigrations.moveBool(legacy, "RoundVideo.watermarkEnabled", GGRoundVideoSettings.watermark)
        GGCameraMasksMigrations.moveText(legacy, "RoundVideo.watermarkText", GGRoundVideoSettings.watermarkText, limit: 48)
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.watermarkPosition", GGRoundVideoSettings.watermarkPosition, [0: GGRoundWatermarkPosition.bottom.rawValue, 1: GGRoundWatermarkPosition.top.rawValue, 2: GGRoundWatermarkPosition.center.rawValue])
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.watermarkFontStyle", GGRoundVideoSettings.watermarkFont, GGCameraMasksMigrations.fontCodes)
        GGCameraMasksMigrations.moveNumber(legacy, "RoundVideo.watermarkSize", GGRoundVideoSettings.watermarkSize, range: 2.0 ... 12.0)
        GGCameraMasksMigrations.moveNumber(legacy, "RoundVideo.watermarkOpacity", GGRoundVideoSettings.watermarkOpacity, range: 10.0 ... 100.0)
        GGCameraMasksMigrations.moveCode(legacy, "RoundVideo.watermarkColor", GGRoundVideoSettings.watermarkColor, GGCameraMasksMigrations.colorCodes)

        GGCameraMasksMigrations.moveBool(legacy, "MiscSettings.autoSendVideosAsRoundVideo", GGRoundVideoSettings.galleryVideosAsRound)
        // The one-shot «send the next video as a round video» flag is replaced by per-asset marks.
        legacy.removeLegacyKey("MiscSettings.sendNextAsRoundVideo")
        GGCameraMasksMigrations.moveBool(legacy, "MiscSettings.roundVideoFlipAnimation", GGRoundVideoSettings.flipAnimation)

        // SG-F4, round videos from the rear camera.
        GGCameraMasksMigrations.moveBool(legacy, "startTelescopeWithRearCam", GGRoundVideoSettings.startWithRearCamera)
        // SG-F5, the camera tile of the attachment gallery.
        GGCameraMasksMigrations.moveBool(legacy, "disableGalleryCamera", GGGalleryCameraSettings.hideCamera)
        GGCameraMasksMigrations.moveBool(legacy, "disableGalleryCameraPreview", GGGalleryCameraSettings.noLivePreview)
    }

    // MARK: Photo watermark (`MiscSettings.photoWatermark*`)

    private static func migratePhotoWatermark(_ legacy: GGLegacyDefaults) {
        GGCameraMasksMigrations.moveBool(legacy, "MiscSettings.photoWatermarkEnabled", GGPhotoWatermarkSettings.enabled)
        GGCameraMasksMigrations.moveText(legacy, "MiscSettings.photoWatermarkText", GGPhotoWatermarkSettings.text, limit: 40)
        GGCameraMasksMigrations.moveCode(legacy, "MiscSettings.photoWatermarkPosition", GGPhotoWatermarkSettings.position, [
            0: GGPhotoWatermarkPosition.bottomRight.rawValue,
            1: GGPhotoWatermarkPosition.topLeft.rawValue,
            2: GGPhotoWatermarkPosition.topRight.rawValue,
            3: GGPhotoWatermarkPosition.center.rawValue,
            4: GGPhotoWatermarkPosition.bottomLeft.rawValue
        ])
        GGCameraMasksMigrations.moveCode(legacy, "MiscSettings.photoWatermarkFontStyle", GGPhotoWatermarkSettings.font, GGCameraMasksMigrations.fontCodes)
        GGCameraMasksMigrations.moveNumber(legacy, "MiscSettings.photoWatermarkSize", GGPhotoWatermarkSettings.size, range: 2.0 ... 12.0)
        GGCameraMasksMigrations.moveNumber(legacy, "MiscSettings.photoWatermarkOpacity", GGPhotoWatermarkSettings.opacity, range: 10.0 ... 100.0)
        GGCameraMasksMigrations.moveCode(legacy, "MiscSettings.photoWatermarkColor", GGPhotoWatermarkSettings.color, GGCameraMasksMigrations.colorCodes)
        GGCameraMasksMigrations.moveBool(legacy, "MiscSettings.photoWatermarkTiled", GGPhotoWatermarkSettings.tiled)
    }

    // MARK: Masks and the anonymous mode

    /// A catalog mask can be used only while the catalog can be downloaded; the old app's copies of
    /// catalog masks are not carried over (`GGMaskStore.migrateLegacyMasks` drops them).
    private static func isUsable(_ selection: GGMaskSelection) -> Bool {
        switch selection {
        case .none:
            return false
        case .catalog:
            return GGMaskCatalog.isAvailable
        case .builtIn, .user:
            return true
        }
    }

    private static func migrateMasks(_ legacy: GGLegacyDefaults) {
        // A chosen mask applied to every round video in the old app: the new switch is turned on
        // only for users who had one this build can show (a catalog mask can not be prepared while
        // the catalog is off: the switch would be on and nothing would happen).
        if let stored = legacy.string("selectedVideoMaskSelection"), let selection = GGMaskSelection.fromLegacy(stored), GGCameraMasksMigrations.isUsable(selection) {
            GGMaskSettings.selection.set(selection.storage)
            GGMaskSettings.enabled.set(true)
        }
        legacy.removeLegacyKey("selectedVideoMaskSelection")
        if let megabytes = legacy.int("maskCacheDiskLimitMB") {
            let options = [50, 100, 200, 400, 800, 1024]
            let nearest = options.min(by: { abs($0 - megabytes) < abs($1 - megabytes) }) ?? 200
            GGMaskSettings.cacheLimit.set("\(nearest)")
        }
        legacy.removeLegacyKey("maskCacheDiskLimitMB")
        // «Apply automatically» never did anything (no reader in the old app): dropped.
        legacy.removeLegacyKey("videoMaskAutoApply")
        GGCameraMasksMigrations.moveBool(legacy, "videoMaskCallsEnabled", GGMaskSettings.inCalls)

        if let id = legacy.string("anonymousModeMaskId") {
            // An unusable one keeps the default anonymous mask, so the face is always covered.
            let selection = GGMaskSelection.fromLegacyMaskId(id)
            if GGCameraMasksMigrations.isUsable(selection) {
                GGAnonymousMode.mask.set(selection.storage)
            }
        }
        legacy.removeLegacyKey("anonymousModeMaskId")
        GGCameraMasksMigrations.moveText(legacy, "anonymousModeVoicePreset", GGAnonymousMode.voice, limit: 64)
        // The old mode was one switch for every account plus a snapshot of the voice changer it
        // restored on exit. The new mode is per account and never touches the user's own preset,
        // so the old state is not carried over: the mode starts off.
        for key in ["GG.anonymous.video.active", "GG.anonymous.voice.savedPresetId", "GG.anonymous.voice.savedEnabled", "GG.anonymous.voice.didSaveState"] {
            legacy.removeLegacyKey(key)
        }
        // The old catalog cache lived in UserDefaults; the new one is a file in Caches.
        legacy.removeLegacyKey("GG.masks.catalog.json")
        legacy.removeLegacyKey("GG.masks.catalog.fetchedAt")
    }

    // MARK: Repairs

    /// The photo watermark moved from global.json to the App Group file the share extension reads
    /// (MEDIA-12), under new keys: the values stored under the old ones are carried over.
    private static func movePhotoWatermarkToAppGroup(_ legacy: GGLegacyDefaults) {
        let prefix = "cameraMasks.photoWatermark."
        if let value = GGRetiredSettings.value(prefix + "enabled", as: Bool.self) {
            GGPhotoWatermarkSettings.enabled.set(value)
        }
        if let value = GGRetiredSettings.value(prefix + "text", as: String.self) {
            GGPhotoWatermarkSettings.text.set(value)
        }
        if let value = GGRetiredSettings.value(prefix + "position", as: String.self) {
            GGPhotoWatermarkSettings.position.set(value)
        }
        if let value = GGRetiredSettings.value(prefix + "font", as: String.self) {
            GGPhotoWatermarkSettings.font.set(value)
        }
        if let value = GGRetiredSettings.value(prefix + "size", as: Double.self) {
            GGPhotoWatermarkSettings.size.set(value)
        }
        if let value = GGRetiredSettings.value(prefix + "opacity", as: Double.self) {
            GGPhotoWatermarkSettings.opacity.set(value)
        }
        if let value = GGRetiredSettings.value(prefix + "color", as: String.self) {
            GGPhotoWatermarkSettings.color.set(value)
        }
        if let value = GGRetiredSettings.value(prefix + "tiled", as: Bool.self) {
            GGPhotoWatermarkSettings.tiled.set(value)
        }
        GGRetiredSettings.remove(prefixes: [prefix])
    }

    /// Builds up to 190 carried the old 0.5× start over as a start zoom no menu row offers; it is
    /// «0,5× на задней камере» now. A remembered zoom above the slider's end is cut to it.
    private static func repairStartZoom(_ legacy: GGLegacyDefaults) {
        if GGRoundVideoSettings.startZoom.value == "half" {
            GGRoundVideoSettings.startZoom.reset()
            GGRoundVideoSettings.rearHalfZoom.set(true)
        }
        if GGRoundVideoSettings.lastZoom.value > GGRoundVideoConfig.maximumZoom {
            GGRoundVideoSettings.lastZoom.set(GGRoundVideoConfig.maximumZoom)
        }
    }

    /// Builds up to 190 carried a catalog mask over and switched masks on, although the catalog is
    /// off and the old copies are gone: the choice is dropped (and masks switched off with it), the
    /// anonymous mask goes back to its default.
    private static func dropUnavailableCatalogMasks(_ legacy: GGLegacyDefaults) {
        if GGMaskCatalog.isAvailable {
            return
        }
        if case .catalog = GGMaskSelection(storage: GGMaskSettings.selection.value) {
            GGMaskSettings.selection.reset()
            GGMaskSettings.enabled.set(false)
        }
        if case .catalog = GGMaskSelection(storage: GGAnonymousMode.mask.value) {
            GGAnonymousMode.mask.reset()
        }
    }

    // MARK: Virtual camera (`ggCallVirtualCamera*`)

    private struct LegacyCallMediaItem: Decodable {
        let id: String
        let title: String
        let fileName: String
        let kind: String
        let createdAt: Double
    }

    private static func migrateVirtualCamera(_ legacy: GGLegacyDefaults) {
        if let raw = legacy.string("ggCallVirtualCameraItems"), let data = raw.data(using: .utf8), let items = try? JSONDecoder().decode([LegacyCallMediaItem].self, from: data) {
            // Audio items belong to the soundboard (calls zone), not to the camera.
            let converted: [GGVirtualCameraItem] = items.compactMap { item in
                guard let kind = GGVirtualCameraItem.Kind(rawValue: item.kind) else {
                    return nil
                }
                return GGVirtualCameraItem(id: item.id, title: item.title, fileName: item.fileName, kind: kind, createdAt: item.createdAt)
            }
            if !converted.isEmpty {
                GGVirtualCameraSettings.items.set(converted)
            }
        }
        legacy.removeLegacyKey("ggCallVirtualCameraItems")
        GGCameraMasksMigrations.moveBool(legacy, "ggCallVirtualCameraEnabled", GGVirtualCameraSettings.enabled)
        if let selected = legacy.string("ggCallVirtualCameraSelectedId"), GGVirtualCameraSettings.items.value.contains(where: { $0.id == selected }) {
            GGVirtualCameraSettings.selected.set(selected)
        }
        legacy.removeLegacyKey("ggCallVirtualCameraSelectedId")
        GGCameraMasksMigrations.moveBool(legacy, "ggCallVirtualCameraLoop", GGVirtualCameraSettings.loop)
    }
}
