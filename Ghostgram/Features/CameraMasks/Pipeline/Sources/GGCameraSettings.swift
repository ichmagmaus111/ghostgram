import Foundation
import GGCore

/// Every setting of the camera zone that the upstream camera modules read (round videos, the
/// gallery camera tile, watermarks). Declared once here, in a module that depends on GGCore only,
/// so `Camera`, `CameraNeo`, `CameraLegacy`, `MediaEditor` and the picker read the same registry the
/// menu writes. Defaults are Telegram's own behaviour: with every value at its default, all upstream
/// call sites take their original path.
///
/// Recording reads a snapshot (`GGRoundVideoConfig.recording()`) once per camera session, never
/// these values per frame.
public enum GGRoundVideoSettings {
    // MARK: Quality — 0 means «as Telegram does it»

    /// Side of the square in pixels: "standard" (Telegram's), "400", "512", "640".
    public static let resolution = GGSetting<String>("cameraMasks.roundVideo.resolution", default: "standard")
    /// Average video bitrate, kbit/s: 0 (Telegram's) or 500…4000 (a slider, step 500).
    public static let bitrate = GGSetting<Double>("cameraMasks.roundVideo.bitrate", default: 0.0)
    /// `GGRoundVideoCodec.rawValue`.
    public static let codec = GGSetting<String>("cameraMasks.roundVideo.codec", default: "h264")
    /// "30" or "60".
    public static let frameRate = GGSetting<String>("cameraMasks.roundVideo.frameRate", default: "30")
    /// `GGRoundVideoStabilization.rawValue`.
    public static let stabilization = GGSetting<String>("cameraMasks.roundVideo.stabilization", default: "standard")

    // MARK: Camera

    /// SG-F4: start round videos with the rear camera.
    public static let startWithRearCamera = GGSetting<Bool>("cameraMasks.roundVideo.rearCamera", default: false)
    /// `GGRoundVideoStartZoom.rawValue`.
    public static let startZoom = GGSetting<String>("cameraMasks.roundVideo.startZoom", default: "one")
    public static let rememberZoom = GGSetting<Bool>("cameraMasks.roundVideo.rememberZoom", default: false)
    public static let zoomSlider = GGSetting<Bool>("cameraMasks.roundVideo.zoomSlider", default: false)
    /// The back camera opens at 0.5× (the ultra-wide lens), at the start and after a flip
    /// (owner, 2026-10-28).
    public static let rearHalfZoom = GGSetting<Bool>("cameraMasks.roundVideo.rearHalfZoom", default: false)
    /// The zoom multiplier the user left the camera at (only kept while `rememberZoom` is on).
    public static let lastZoom = GGSetting<Double>("cameraMasks.roundVideo.lastZoom", default: 1.0, flags: [.noExport])
    public static let flipAnimation = GGSetting<Bool>("cameraMasks.roundVideo.flipAnimation", default: false)

    // MARK: Recording

    public static let countdown = GGSetting<Bool>("cameraMasks.roundVideo.countdown", default: false)
    public static let viewOnceByDefault = GGSetting<Bool>("cameraMasks.roundVideo.viewOnce", default: false)
    public static let sendAsRegularVideo = GGSetting<Bool>("cameraMasks.roundVideo.sendAsVideo", default: false)
    public static let saveCopyToGallery = GGSetting<Bool>("cameraMasks.roundVideo.saveToGallery", default: false)

    // MARK: Sound

    /// `GGRoundVideoMicrophoneMode.rawValue`; "default" leaves the audio session as Telegram sets it.
    public static let microphoneMode = GGSetting<String>("cameraMasks.roundVideo.microphone", default: "default")
    public static let normalizeAudio = GGSetting<Bool>("cameraMasks.roundVideo.normalize", default: false)
    public static let muteAudio = GGSetting<Bool>("cameraMasks.roundVideo.mute", default: false)

    // MARK: Watermark over the circle

    public static let watermark = GGSetting<Bool>("cameraMasks.roundVideo.watermark", default: false)
    public static let watermarkText = GGSetting<String>("cameraMasks.roundVideo.watermarkText", default: "")
    /// `GGRoundWatermarkPosition.rawValue`.
    public static let watermarkPosition = GGSetting<String>("cameraMasks.roundVideo.watermarkPosition", default: "bottom")
    /// `GGWatermarkFont.rawValue`.
    public static let watermarkFont = GGSetting<String>("cameraMasks.roundVideo.watermarkFont", default: "bold")
    /// % of the side, 2…12.
    public static let watermarkSize = GGSetting<Double>("cameraMasks.roundVideo.watermarkSize", default: 6.0)
    /// %, 10…100.
    public static let watermarkOpacity = GGSetting<Double>("cameraMasks.roundVideo.watermarkOpacity", default: 55.0)
    /// `GGWatermarkColor.rawValue`.
    public static let watermarkColor = GGSetting<String>("cameraMasks.roundVideo.watermarkColor", default: "white")

    // MARK: Gallery

    /// Every video picked from the gallery goes out as a round video.
    public static let galleryVideosAsRound = GGSetting<Bool>("cameraMasks.roundVideo.galleryAsRound", default: false)
    /// «Send as a round video» in the attachment picker's «…» menu (for the chosen videos only).
    public static let galleryMenuItem = GGSetting<Bool>("cameraMasks.roundVideo.galleryMenuItem", default: false)

    /// Settings the «reset the round video settings» row resets (the watermark and the gallery keys
    /// have their own rows and are reset with it as well).
    public static var resettableKeys: [GGRoundVideoAnySetting] {
        return [
            GGRoundVideoAnySetting(GGRoundVideoSettings.resolution),
            GGRoundVideoAnySetting(GGRoundVideoSettings.bitrate),
            GGRoundVideoAnySetting(GGRoundVideoSettings.codec),
            GGRoundVideoAnySetting(GGRoundVideoSettings.frameRate),
            GGRoundVideoAnySetting(GGRoundVideoSettings.stabilization),
            GGRoundVideoAnySetting(GGRoundVideoSettings.startWithRearCamera),
            GGRoundVideoAnySetting(GGRoundVideoSettings.startZoom),
            GGRoundVideoAnySetting(GGRoundVideoSettings.rememberZoom),
            GGRoundVideoAnySetting(GGRoundVideoSettings.zoomSlider),
            GGRoundVideoAnySetting(GGRoundVideoSettings.rearHalfZoom),
            GGRoundVideoAnySetting(GGRoundVideoSettings.lastZoom),
            GGRoundVideoAnySetting(GGRoundVideoSettings.flipAnimation),
            GGRoundVideoAnySetting(GGRoundVideoSettings.countdown),
            GGRoundVideoAnySetting(GGRoundVideoSettings.viewOnceByDefault),
            GGRoundVideoAnySetting(GGRoundVideoSettings.sendAsRegularVideo),
            GGRoundVideoAnySetting(GGRoundVideoSettings.saveCopyToGallery),
            GGRoundVideoAnySetting(GGRoundVideoSettings.microphoneMode),
            GGRoundVideoAnySetting(GGRoundVideoSettings.normalizeAudio),
            GGRoundVideoAnySetting(GGRoundVideoSettings.muteAudio),
            GGRoundVideoAnySetting(GGRoundVideoSettings.watermark),
            GGRoundVideoAnySetting(GGRoundVideoSettings.watermarkText),
            GGRoundVideoAnySetting(GGRoundVideoSettings.watermarkPosition),
            GGRoundVideoAnySetting(GGRoundVideoSettings.watermarkFont),
            GGRoundVideoAnySetting(GGRoundVideoSettings.watermarkSize),
            GGRoundVideoAnySetting(GGRoundVideoSettings.watermarkOpacity),
            GGRoundVideoAnySetting(GGRoundVideoSettings.watermarkColor),
            GGRoundVideoAnySetting(GGRoundVideoSettings.galleryVideosAsRound),
            GGRoundVideoAnySetting(GGRoundVideoSettings.galleryMenuItem)
        ]
    }

    static func declare() {
        let _ = GGRoundVideoSettings.resettableKeys
    }
}

/// A type-erased setting for the reset row.
public struct GGRoundVideoAnySetting {
    public let key: String
    public let isDefault: () -> Bool
    public let reset: () -> Void

    init<Value>(_ setting: GGSetting<Value>) {
        self.key = setting.key
        self.isDefault = {
            return setting.isDefault
        }
        self.reset = {
            setting.reset()
        }
    }
}

/// SG-F5: the camera tile in the attachment gallery.
public enum GGGalleryCameraSettings {
    /// No camera tile at all (the picker never starts the camera).
    public static let hideCamera = GGSetting<Bool>("cameraMasks.gallery.hideCamera", default: false)
    /// The tile stays but shows no live feed until it is tapped.
    public static let noLivePreview = GGSetting<Bool>("cameraMasks.gallery.noLivePreview", default: false)

    static func declare() {
        let _ = GGGalleryCameraSettings.hideCamera
        let _ = GGGalleryCameraSettings.noLivePreview
    }
}

/// «Водяной знак на фото». Read once per photo as a snapshot (`GGPhotoWatermarkConfig.current()`).
/// App Group settings: photos sent from other apps through the share extension get the mark too.
/// (Until 13.0 (190) they were global, under `cameraMasks.photoWatermark.*`; moved by the migration
/// `cameraMasks.photoWatermark.appGroup.v1`.)
public enum GGPhotoWatermarkSettings {
    public static let enabled = GGSetting<Bool>("cameraMasks.outgoingWatermark.enabled", default: false, scope: .appGroup, flags: [.extensions])
    public static let text = GGSetting<String>("cameraMasks.outgoingWatermark.text", default: "", scope: .appGroup, flags: [.extensions])
    /// `GGPhotoWatermarkPosition.rawValue`.
    public static let position = GGSetting<String>("cameraMasks.outgoingWatermark.position", default: "bottomRight", scope: .appGroup, flags: [.extensions])
    /// `GGWatermarkFont.rawValue`.
    public static let font = GGSetting<String>("cameraMasks.outgoingWatermark.font", default: "bold", scope: .appGroup, flags: [.extensions])
    /// % of the short side, 2…12.
    public static let size = GGSetting<Double>("cameraMasks.outgoingWatermark.size", default: 4.0, scope: .appGroup, flags: [.extensions])
    /// %, 10…100.
    public static let opacity = GGSetting<Double>("cameraMasks.outgoingWatermark.opacity", default: 55.0, scope: .appGroup, flags: [.extensions])
    /// `GGWatermarkColor.rawValue`.
    public static let color = GGSetting<String>("cameraMasks.outgoingWatermark.color", default: "white", scope: .appGroup, flags: [.extensions])
    public static let tiled = GGSetting<Bool>("cameraMasks.outgoingWatermark.tiled", default: false, scope: .appGroup, flags: [.extensions])

    /// Also from the share extension's launch: the extension reads these.
    public static func declare() {
        let _ = GGPhotoWatermarkSettings.enabled
        let _ = GGPhotoWatermarkSettings.text
        let _ = GGPhotoWatermarkSettings.position
        let _ = GGPhotoWatermarkSettings.font
        let _ = GGPhotoWatermarkSettings.size
        let _ = GGPhotoWatermarkSettings.opacity
        let _ = GGPhotoWatermarkSettings.color
        let _ = GGPhotoWatermarkSettings.tiled
    }
}

public enum GGRoundVideoCodec: String, CaseIterable {
    case h264
    case hevc
}

public enum GGRoundVideoStabilization: String, CaseIterable {
    case standard
    case off
    case cinematic
}

/// 0.5× is not a start zoom: it is «0,5× на задней камере» (`GGRoundVideoSettings.rearHalfZoom`).
public enum GGRoundVideoStartZoom: String, CaseIterable {
    case one
    case two
    case last

    /// Fixed multiplier of the camera's neutral (1×) zoom; `last` is resolved by the config.
    public var multiplier: Double? {
        switch self {
        case .one:
            return 1.0
        case .two:
            return 2.0
        case .last:
            return nil
        }
    }
}

public enum GGRoundVideoMicrophoneMode: String, CaseIterable {
    /// The audio session as Telegram configures it.
    case standard = "default"
    /// `AVAudioSession.Mode.videoRecording`: no voice processing.
    case videoRecording
    /// `AVAudioSession.Mode.voiceChat`: the system's noise and echo cancellation.
    case voiceChat
}

public enum GGWatermarkFont: String, CaseIterable {
    case regular
    case bold
    case mono
    case italic
}

public enum GGWatermarkColor: String, CaseIterable {
    case white
    case black
    case red
    case yellow
}

/// Positions inside the circle: only horizontally centred ones, corners would be cut by the mask.
public enum GGRoundWatermarkPosition: String, CaseIterable {
    case bottom
    case top
    case center
}

public enum GGPhotoWatermarkPosition: String, CaseIterable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
    case center
}

public enum GGCameraPipelineSettings {
    /// Touches every declaration of this module (called from `GGCameraMasksModule.register()`).
    public static func declare() {
        GGRoundVideoSettings.declare()
        GGGalleryCameraSettings.declare()
        GGPhotoWatermarkSettings.declare()
    }
}
