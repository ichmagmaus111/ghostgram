import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatListUI
import GGCore
import GGHooks
import GGFeaturesShared

/// Entry point of the GGSecurity feature module. Owner: W3-4.
///
/// Settings, migrations and what the extensions need are in GGFeaturesShared
/// (`Sources/Security/`, registered before this module); here — the app: the common check
/// (`GGLocalAuthGate`), the chat lock, the secret folder, the account switch check and the account
/// button, screenshots, the passcode extras and the «Безопасность» menu.
public enum GGSecurityModule {
    private static var listRefreshDisposable: Disposable?

    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        GGSecurityMenu.register()
        GGChatLockHandlers.register()
        GGScreenshotPrivacy.register()
        GGPasscodeExtras.register()
        GGAccountSwitchGuard.shared.register()
        GGAccountHeaderButton.register()

        GGChatListHooks.folders.register({ signal, context in
            return GGSecretFolder.shared.folders(signal, context: context)
        })

        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGAuthEnvironment.shared.start(sharedContext: context.sharedContext)
            GGAccountSwitchGuard.shared.start(context: context)
            GGAccountsList.shared.start(context: context)
            GGSecretFolder.shared.startMembership(context: context)
            GGSecurityModule.observeListPolicies()
        })
        GGLifecycleHooks.applicationDidEnterBackground.register({
            // The folder first: the chat lock covers the folder's open chats by its state.
            GGSecretFolder.shared.lockAll()
            GGChatLock.shared.applicationDidEnterBackground()
        })
        GGLifecycleHooks.applicationDidBecomeActive.register({
            GGAuthEnvironment.shared.refreshDevice()
            GGChatLock.shared.applicationDidBecomeActive()
        })
    }

    /// «Пароль на чаты» and «Защищать все чаты» change what every chat list row shows; the rows of
    /// single chats are laid out again by `GGChatListHooks.accessoryPeers`, the whole lists — by one
    /// re-emission of the PresentationData (only on these two switches, never on a timer).
    private static func observeListPolicies() {
        if GGSecurityModule.listRefreshDisposable != nil {
            return
        }
        var isFirst = true
        GGSecurityModule.listRefreshDisposable = (combineLatest(GGSecuritySharedSettings.chatLockEnabled.signal, GGSecuritySharedSettings.chatLockAllChats.signal)
        |> deliverOnMainQueue).start(next: { _, _ in
            if isFirst {
                isFirst = false
                return
            }
            GGThemeHooks.invalidate()
        })
    }
}
