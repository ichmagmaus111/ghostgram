import Foundation

/// Light aggregator linked into the app and into the extensions (notification service, share).
/// Each zone owns its `Sources/<Zone>/<Zone>Shared.swift`; nobody edits this file after wave 1.
public enum GGFeaturesShared {
    /// App process: called by `GGFeatures.registerAll()` before the feature modules register.
    public static func registerForApp() {
        GGFeaturesShared.registerZones()
    }

    /// Extension processes: called instead of `GGFeatures.registerAll()`, after `GGCore.bootstrap`
    /// and before `GGHookRegistry.freeze()`.
    public static func registerForExtension() {
        GGFeaturesShared.registerZones()
    }

    private static func registerZones() {
        GGGhostModeShared.register()
        GGAntiDeleteShared.register()
        GGMessagesShared.register()
        GGAppearanceShared.register()
        GGInterfaceShared.register()
        GGVoiceShared.register()
        GGCameraMasksShared.register()
        GGCallsMediaShared.register()
        GGSecurityShared.register()
        GGNetworkSpoofShared.register()
        GGProfileExportShared.register()
        // W5-SG: Swiftgram-parity features (settings, NSE flag, TelegramCore points).
        GGExtrasShared.register()
    }
}
