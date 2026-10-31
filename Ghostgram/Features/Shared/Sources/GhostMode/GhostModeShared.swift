import Foundation
import GGCore

/// The part of GGGhostMode that the extensions (notification service, share) also link: the
/// settings and the policy that decides what leaves the device (read receipts, story views,
/// "typing", online, send delay). Owner: W2-1.
public enum GGGhostModeShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
        GGGhostSettings.declare()
        GGGhostCoreHandlers.register()
    }
}
