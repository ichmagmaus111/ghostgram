import Foundation
import GGCore

/// Settings of the masks themselves (round videos, calls, the catalog, the virtual camera). The
/// camera-pipeline settings (round video quality, watermarks, gallery camera) live in
/// GGCameraPipeline, the anonymous mode in GGFeaturesShared.
enum GGMaskSettings {
    /// Masks in round videos: the button and panel on the camera screen, and processing.
    static let enabled = GGSetting<Bool>("cameraMasks.masks.enabled", default: false)
    /// `GGMaskSelection.storage`.
    static let selection = GGSetting<String>("cameraMasks.masks.selection", default: "")
    /// The same mask in calls (front camera).
    static let inCalls = GGSetting<Bool>("cameraMasks.masks.calls", default: false)
    /// Disk limit of downloaded catalog masks, MB: "50", "100", "200", "400", "800", "1024".
    static let cacheLimit = GGSetting<String>("cameraMasks.masks.cacheLimit", default: "200")
    /// Service state of the catalog: never exported.
    static let catalogETag = GGSetting<String>("cameraMasks.masks.catalogETag", default: "", flags: [.noExport])
    static let catalogFetchedAt = GGSetting<Double>("cameraMasks.masks.catalogFetchedAt", default: 0.0, flags: [.noExport])

    static func declare() {
        let _ = GGMaskSettings.enabled
        let _ = GGMaskSettings.selection
        let _ = GGMaskSettings.inCalls
        let _ = GGMaskSettings.cacheLimit
        let _ = GGMaskSettings.catalogETag
        let _ = GGMaskSettings.catalogFetchedAt
    }
}

/// One item of the virtual camera library: metadata here, the file in the app container.
struct GGVirtualCameraItem: Codable, Equatable, GGSettingValue {
    enum Kind: String, Codable {
        case image
        case gif
        case video
    }

    var id: String
    var title: String
    /// File name only (the container path changes between installs).
    var fileName: String
    var kind: Kind
    var createdAt: Double
}

enum GGVirtualCameraSettings {
    /// Calls send a picture, GIF or video instead of the camera.
    static let enabled = GGSetting<Bool>("cameraMasks.virtualCamera.enabled", default: false)
    /// Id of the chosen item; "" = none (the real camera).
    static let selected = GGSetting<String>("cameraMasks.virtualCamera.selected", default: "")
    /// A video starts over at the end (otherwise its last frame stays).
    static let loop = GGSetting<Bool>("cameraMasks.virtualCamera.loop", default: false)
    /// The library (files stay on this device: not exported).
    static let items = GGSetting<[GGVirtualCameraItem]>("cameraMasks.virtualCamera.items", default: [], flags: [.noExport])

    static func declare() {
        let _ = GGVirtualCameraSettings.enabled
        let _ = GGVirtualCameraSettings.selected
        let _ = GGVirtualCameraSettings.loop
        let _ = GGVirtualCameraSettings.items
    }

    static var selectedItem: GGVirtualCameraItem? {
        guard GGVirtualCameraSettings.enabled.value else {
            return nil
        }
        let id = GGVirtualCameraSettings.selected.value
        if id.isEmpty {
            return nil
        }
        return GGVirtualCameraSettings.items.value.first(where: { $0.id == id })
    }
}
