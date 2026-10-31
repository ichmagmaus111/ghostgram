import Foundation
import TelegramCore
import GGCore

/// The part of GGExtras (Swiftgram-parity features, W5-SG) that the extensions also link: the
/// settings (the notification service reads `hideAccountInNotifications`) and the handlers of the
/// points compiled into TelegramCore.
public enum GGExtrasShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`.
    public static func register() {
        GGExtrasSettings.declare()

        GGExtrasCoreHooks.restrictionText.register({ text, reason, platform in
            if !GGExtrasSettings.restrictionReasonCode.value || reason.isEmpty {
                return text
            }
            return text + "\n" + reason + "-" + platform
        })

        if GGCore.environment?.process.isApp ?? false {
            GGExtrasCoreHooks.searchesPartialWords.register({
                return GGExtrasSettings.searchPartialWords.value
            })
        }
    }
}
