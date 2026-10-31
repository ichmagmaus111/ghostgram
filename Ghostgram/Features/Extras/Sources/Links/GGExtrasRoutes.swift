import Foundation
import Display
import AccountContext
import GGCore
import GGHooks

/// Shortcut links (Swiftgram's `tg://sg/…` routes, the ones a user has a use for):
/// `ghostgram://contacts` (also `gg://contacts`) opens the contacts, `ghostgram://ios_settings` the
/// app's page in the iOS Settings. Handy for Shortcuts and widgets. `ghostgram://settings` (the menu)
/// is GGSettingsUI's own.
enum GGExtrasRoutes {
    static func register() {
        GGLifecycleHooks.openURL.register({ url, context, _ in
            guard let scheme = url.scheme?.lowercased(), scheme == "ghostgram" || scheme == "gg" else {
                return false
            }
            switch url.host?.lowercased() ?? "" {
            case "contacts":
                guard let rootController = context.sharedContext.mainWindow?.viewController as? TelegramRootControllerInterface else {
                    return false
                }
                rootController.openContacts()
                return true
            case "ios_settings", "iossettings":
                context.sharedContext.applicationBindings.openSettings()
                return true
            default:
                return false
            }
        }, order: 900)
    }
}
