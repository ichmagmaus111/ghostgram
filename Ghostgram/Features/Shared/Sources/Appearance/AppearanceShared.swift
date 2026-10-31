import Foundation

/// The part of GGAppearance that the extensions (notification service, share) also link: settings with
/// `.extensions`, NSE handlers, attribute declarations. Owner: W2-4.
public enum GGAppearanceShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
        // Nothing to do (W2-4): appearance applies to the app's own screens only. The notification
        // service draws no UI and the share sheet keeps the upstream look, so no appearance setting
        // carries `.extensions`. The settings and the snapshot live in `GGAppearanceSettings`.
    }
}
