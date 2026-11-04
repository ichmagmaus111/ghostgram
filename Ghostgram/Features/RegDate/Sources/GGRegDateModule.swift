import Foundation

/// Entry point of GGRegDate, «Дата регистрации» (owner's decision 2026-11-01): when an account was
/// created, in the profile of every user and bot. Swiftgram's layers in Ghostgram's architecture:
///
/// | Swiftgram | here |
/// |---|---|
/// | `SGRegDateScheme` | `Model/GGRegDateModel.swift` (contract), `Store/GGRegDateStore.swift` |
/// | `SGAPI` regdate | `Remote/GGRegDateAPI.swift` (no address: off), `Remote/GGRegDateRemoteResponse.swift` |
/// | `SGAPIToken`, `SGDeviceToken` | none: no web-app token, no DeviceCheck / App Attest |
/// | `SGRegDate` (cache + request) | `Provider/GGRegDate.swift`, `Evidence/GGRegDateEvidenceCollector.swift` |
/// | the estimate (server side in Swiftgram) | `Estimate/GGRegDateResolver.swift` (by ID, on the device) |
/// | `SGPeerInfoRows` | `Profile/GGRegDateProfileRow.swift` |
public enum GGRegDateModule {
    /// Declares the settings, the menu row, the profile row and the migration. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        GGRegDateSettings.declare()
        GGRegDateMenu.register()
        GGRegDateProfileRow.register()
        GGRegDateMigration.register()
    }
}
