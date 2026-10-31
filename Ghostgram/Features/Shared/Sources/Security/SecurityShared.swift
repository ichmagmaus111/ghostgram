import Foundation
import GGCore

/// The part of GGSecurity that the extensions (notification service, share) also link: settings with
/// `.extensions`, NSE handlers, attribute declarations. Owner: W3-4.
public enum GGSecurityShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
        // Account limit (W3-4b): 100 with and without Premium, app process only.
        GGAccountLimit.register()

        // W3-4: every setting of the zone, then what the extensions need — which chats are protected
        // (push text, Siri, banners, widget). Migrations only in the app, before the feature modules.
        GGSecuritySharedSettings.declare()
        GGSecuritySettings.declare()
        GGChatProtection.register()
        if GGCore.environment?.process.isApp ?? false {
            GGSecurityMigrations.register()
        }
    }
}
