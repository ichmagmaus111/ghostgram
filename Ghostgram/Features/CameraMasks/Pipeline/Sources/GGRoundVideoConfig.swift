import Foundation
import CoreGraphics
import CoreMedia
import VideoToolbox
import AVFoundation
import GGCore

/// What one round-video camera session records with. Taken once when the camera is created (the
/// settings screen can not be open at the same time), never re-read per frame.
public struct GGRoundVideoRecordingConfig: Equatable {
    /// Side of the recorded square; nil = the pipeline's own (CameraNeo 480, legacy 400).
    public let side: Int?
    /// Average video bitrate, kbit/s; nil = the pipeline's own.
    public let bitrateKbps: Int?
    /// HEVC was asked for and this device has a hardware HEVC encoder.
    public let useHEVC: Bool
    /// 30 or 60.
    public let frameRate: Int
    public let stabilization: GGRoundVideoStabilization
    /// The recording gets no audio track.
    public let muteAudio: Bool
    /// The back camera is the virtual camera with the ultra-wide lens, so the zoom reaches 0.5×:
    /// only while a zoom feature of Ghostgram can use it and the device has that lens.
    public let usesUltraWideCamera: Bool

    public static let standard = GGRoundVideoRecordingConfig(side: nil, bitrateKbps: nil, useHEVC: false, frameRate: 30, stabilization: .standard, muteAudio: false, usesUltraWideCamera: false)

    public init(side: Int?, bitrateKbps: Int?, useHEVC: Bool, frameRate: Int, stabilization: GGRoundVideoStabilization, muteAudio: Bool, usesUltraWideCamera: Bool) {
        self.side = side
        self.bitrateKbps = bitrateKbps
        self.useHEVC = useHEVC
        self.frameRate = frameRate
        self.stabilization = stabilization
        self.muteAudio = muteAudio
        self.usesUltraWideCamera = usesUltraWideCamera
    }

    /// Everything as Telegram does it: the camera modules take their untouched path.
    public var isStandard: Bool {
        return self == GGRoundVideoRecordingConfig.standard
    }

    /// A square side above the 640×480 capture format's short side needs the 1280×720 format.
    public func needsHighResolutionCapture(defaultSide: Int) -> Bool {
        return (self.side ?? defaultSide) > 480
    }

    public func outputSide(defaultSide: Int) -> Int {
        return self.side ?? defaultSide
    }

    public func bitrate(defaultKbps: Int) -> Int {
        return (self.bitrateKbps ?? defaultKbps) * 1000
    }
}

/// What Telegram's servers take as a round video: `round_video_encoding` of the account's app config
/// (`max_size`, bytes — the same limit TDLib keeps as `video_note_size_max`). A bigger file is not a
/// round video for the server and arrives as an ordinary video. Known once the round camera or a
/// gallery video sent as a round one has read the app config; until then nothing is capped.
public enum GGRoundVideoServerLimits {
    /// Telegram's round video audio, kbit/s.
    public static let audioKbps = 64
    /// The longest round video, s.
    public static let maximumDuration: Double = 60.0

    private static let lock = NSLock()
    private static var storedMaxBytes: Int?

    public static var maxBytes: Int? {
        GGRoundVideoServerLimits.lock.lock()
        defer {
            GGRoundVideoServerLimits.lock.unlock()
        }
        return GGRoundVideoServerLimits.storedMaxBytes
    }

    /// `round_video_encoding` of the app config; a missing or broken value keeps the last known one.
    public static func update(encoding: [String: Any]?) {
        guard let value = encoding?["max_size"] else {
            return
        }
        var maxBytes: Int?
        if let number = value as? Double, number.isFinite, number >= 1024.0 {
            maxBytes = Int(number)
        } else if let number = value as? Int, number >= 1024 {
            maxBytes = number
        }
        guard let maxBytes else {
            return
        }
        GGRoundVideoServerLimits.lock.lock()
        GGRoundVideoServerLimits.storedMaxBytes = maxBytes
        GGRoundVideoServerLimits.lock.unlock()
    }

    /// The highest video bitrate, kbit/s, at which a full-length round video with its sound stays
    /// under the limit (a tenth kept for the container and the bitrate's swings); nil = unknown.
    public static func maximumVideoKbps(audioKbps: Int) -> Int? {
        guard let maxBytes = GGRoundVideoServerLimits.maxBytes else {
            return nil
        }
        let totalKbps = Double(maxBytes) * 8.0 * 0.9 / GGRoundVideoServerLimits.maximumDuration / 1000.0
        return max(200, Int(totalKbps) - audioKbps)
    }
}

public enum GGRoundVideoConfig {
    /// Snapshot for a camera session that is about to start.
    public static func recording() -> GGRoundVideoRecordingConfig {
        let side: Int?
        switch GGRoundVideoSettings.resolution.value {
        case "400":
            side = 400
        case "512":
            side = 512
        case "640":
            side = 640
        default:
            side = nil
        }
        let bitrateValue = Int(GGRoundVideoSettings.bitrate.value.rounded())
        var bitrate: Int? = bitrateValue >= 500 ? min(4000, bitrateValue) : nil
        // A round video over Telegram's size limit arrives as an ordinary video (owner, 2026-10-28):
        // the chosen bitrate is lowered so that even a full 60 s one fits.
        if let value = bitrate, let maximum = GGRoundVideoServerLimits.maximumVideoKbps(audioKbps: GGRoundVideoServerLimits.audioKbps), value > maximum {
            bitrate = maximum
        }
        let wantsHEVC = GGRoundVideoSettings.codec.value == GGRoundVideoCodec.hevc.rawValue
        let frameRate = GGRoundVideoSettings.frameRate.value == "60" ? 60 : 30
        let stabilization = GGRoundVideoStabilization(rawValue: GGRoundVideoSettings.stabilization.value) ?? .standard
        return GGRoundVideoRecordingConfig(
            side: side,
            bitrateKbps: bitrate,
            useHEVC: wantsHEVC && GGRoundVideoConfig.hasHardwareHEVCEncoder,
            frameRate: frameRate,
            stabilization: stabilization,
            muteAudio: GGRoundVideoSettings.muteAudio.value,
            usesUltraWideCamera: GGRoundVideoConfig.wantsUltraWideCamera && GGRoundVideoConfig.hasUltraWideCamera
        )
    }

    /// A zoom feature can go below 1×: the slider, a remembered zoom, the back camera at 0.5×, or a
    /// start «as last time» that remembers a zoom below 1×.
    static var wantsUltraWideCamera: Bool {
        if GGRoundVideoSettings.zoomSlider.value || GGRoundVideoSettings.rearHalfZoom.value || GGRoundVideoSettings.rememberZoom.value {
            return true
        }
        return GGRoundVideoConfig.startsAtLastZoom && GGRoundVideoSettings.lastZoom.value < 0.99
    }

    /// «Стартовый зум: как в прошлый раз».
    static var startsAtLastZoom: Bool {
        return GGRoundVideoStartZoom(rawValue: GGRoundVideoSettings.startZoom.value) == .last
    }

    /// The back camera has an ultra-wide lens (a dual-wide or triple virtual camera). Probed once.
    public static let hasUltraWideCamera: Bool = {
        if #available(iOS 13.0, *) {
            if AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) != nil {
                return true
            }
            return AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) != nil
        }
        return false
    }()

    /// The highest zoom of a round video (the slider's end, a remembered zoom).
    public static let maximumZoom: Double = 5.0

    /// The lowest zoom a round video reaches on the back camera.
    public static var minimumZoom: Double {
        return GGRoundVideoConfig.hasUltraWideCamera ? 0.5 : 1.0
    }

    /// Side of the `.videoMessage` export preset (trimmed or multi-part round videos are re-encoded).
    public static func exportSide(_ upstream: CGFloat) -> CGFloat {
        if let side = GGRoundVideoConfig.recording().side {
            return CGFloat(side)
        }
        return upstream
    }

    /// Bitrate of the `.videoMessage` export preset, kbit/s.
    public static func exportBitrate(_ upstream: Int) -> Int {
        return GGRoundVideoConfig.recording().bitrateKbps ?? upstream
    }

    /// The export keeps HEVC for round videos when the user chose it (upstream always forces H.264
    /// for presets, which silently undid the setting on every trimmed round video).
    public static var exportUsesHEVC: Bool {
        return GGRoundVideoConfig.recording().useHEVC
    }

    /// The camera's starting zoom as a multiplier of its neutral (1×) factor; nil = leave it.
    /// «As last time» reads the remembered zoom on its own: it does not need «remember the zoom»,
    /// which is about the pinch not snapping back.
    public static func startZoomMultiplier() -> Double? {
        let start = GGRoundVideoStartZoom(rawValue: GGRoundVideoSettings.startZoom.value) ?? .one
        let multiplier = start.multiplier ?? GGRoundVideoSettings.lastZoom.value
        if abs(multiplier - 1.0) < 0.01 {
            return nil
        }
        return max(0.5, min(GGRoundVideoConfig.maximumZoom, multiplier))
    }

    /// Remembers the zoom the user left the camera at, while either «remember the zoom» or the start
    /// «as last time» uses it.
    public static func noteZoom(_ multiplier: Double) {
        guard GGRoundVideoSettings.rememberZoom.value || GGRoundVideoConfig.startsAtLastZoom else {
            return
        }
        let clamped = max(0.5, min(GGRoundVideoConfig.maximumZoom, multiplier))
        if abs(GGRoundVideoSettings.lastZoom.value - clamped) > 0.01 {
            GGRoundVideoSettings.lastZoom.set(clamped)
        }
    }

    /// Prepared watermark for a recording of this side, or nil when it is off or has no text.
    public static func watermark(side: Int) -> GGRoundVideoWatermark? {
        guard let config = GGRoundWatermarkConfig.current() else {
            return nil
        }
        return GGRoundVideoWatermark(config: config, side: side)
    }

    /// Probed once per process.
    public static let hasHardwareHEVCEncoder: Bool = {
        var encoderId: CFString?
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 1280,
            height: 720,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            encoderIDOut: &encoderId,
            supportedPropertiesOut: &properties
        )
        return status == noErr
    }()
}
