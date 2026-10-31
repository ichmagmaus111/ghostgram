import Foundation
import SwiftSignalKit
import TelegramCore
import GGCore
import GGFeaturesShared

/// Entry point of the GGGhostMode feature module. Owner: W2-1.
///
/// The decisions about what leaves the device live in `GGFeaturesShared` (`GGGhostModeShared`,
/// registered by the aggregator for the app and the extensions alike). This module is the app's
/// side: the menu, the chat-screen tracking, the explicit reads and the menu items.
public enum GGGhostModeModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        GGGhostMigrations.register()
        GGGhostMenu.register()
        GGGhostMenuItems.register()
        GGGhostChatTracking.register()
        GGGhostBlockedPeers.register()
        GGGhostTraces.register()
        GGGhostQuickActions.register()

        GGAccountHooks.accountWillBeRemoved.register({ id in
            let account = id.gg
            Queue.mainQueue().async {
                GGGhostAccounts.shared.accountWillBeRemoved(account)
                GGGhostBlockedPeers.shared.clear(account: account)
            }
        }, order: 100)

        // Throttled work on return to the app (never on every activation, never in the background):
        // the blocked lists of the accounts that hide them, and «Прочитать локально» re-applied
        // after a server reset of the read state.
        GGForegroundTaskScheduler.shared.register(id: "ghostMode.refresh", minimumInterval: 30.0 * 60.0, delay: 4.0, task: { done in
            let contexts = GGGhostAccounts.shared.contexts
            var signals: [Signal<Never, NoError>] = []
            for context in contexts {
                let account = context.account.id.gg
                if GGGhostSettings.hideBlockedMessages.value(for: account) {
                    // The current list stays in use until the new one is complete.
                    GGGhostBlockedPeers.shared.reload(context: context)
                }
                signals.append(GGGhostAccounts.reapplyLocalReads(context: context))
            }
            if signals.isEmpty {
                done()
                return EmptyDisposable
            }
            return combineLatest(signals).start(completed: {
                done()
            })
        })
    }
}
