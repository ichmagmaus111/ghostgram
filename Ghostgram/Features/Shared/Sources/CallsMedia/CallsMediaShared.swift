import Foundation
import GGCore

/// The part of GGCallsMedia that the extensions (notification service, share) also link: settings with
/// `.extensions`, NSE handlers, attribute declarations. Owner: W3-3.
public enum GGCallsMediaShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
        GGOutgoingPhotoSettings.declare()
    }
}

/// «Качество фото» and «Большие фото» (SG-F1 / SG-F2). App Group settings: photos sent from other
/// apps through the share extension follow them too. (Until 13.0 (190) they were global, under
/// `downloads.photoQuality` / `downloads.largePhotos`; moved by the migration
/// `downloads.photos.appGroup.v1`.)
public enum GGOutgoingPhotoSettings {
    /// JPEG quality of outgoing photos in percent ("60"…"100"); "" = as Telegram (60 % in chats,
    /// 70 % in stories). Default "70", Swiftgram's `outgoingPhotoQuality` (W6-SGD, owner's decision
    /// 2026-10-29): the explicit «as Telegram» choice is stored as "".
    public static let quality = GGSetting<String>("downloads.outgoingPhotoQuality", default: "70", scope: .appGroup, flags: [.extensions])
    /// Compressed photos up to 2560 px on the long side instead of 1280.
    public static let largePhotos = GGSetting<Bool>("downloads.outgoingLargePhotos", default: false, scope: .appGroup, flags: [.extensions])

    static func declare() {
        let _ = GGOutgoingPhotoSettings.quality
        let _ = GGOutgoingPhotoSettings.largePhotos
    }

    /// The `GGOutgoingImageHooks.parameters` handler of the app and of the share extension.
    public static func apply(maxSide: inout CGFloat, jpegQuality: inout Float, isHd: Bool) {
        if GGOutgoingPhotoSettings.largePhotos.value && !isHd {
            maxSide = max(maxSide, 2560.0)
        }
        if let quality = Int(GGOutgoingPhotoSettings.quality.value), quality > 0 {
            jpegQuality = Float(max(50, min(100, quality))) / 100.0
        }
    }
}
