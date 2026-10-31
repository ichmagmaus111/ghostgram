import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGSettingsUI
import GGFeaturesShared
import ChatListUI

/// Entry point of the GGAntiDelete feature module. Owner: W2-2.
/// The capture itself (Postbox attributes, the index, the notification service) is registered by
/// `GGAntiDeleteShared` (GGFeaturesShared); this module adds the menu, the chat UI and the
/// background maintenance of the app.
public enum GGAntiDeleteModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        GGAntiDeleteMenu.register()
        GGAntiDeleteMigrations.register()
        GGAntiDeleteQuickActions.register()

        // Bubbles of every type: transparency, status marks, the local edit, previous versions.
        GGMessageDecorationHooks.decorations.register({ decoration, context in
            GGAntiDeleteDecorations.decorate(&decoration, context)
        }, order: 100)

        // Message menu.
        GGMessageMenuHooks.items.register({ context in
            return GGAntiDeleteMessageMenu.items(context)
        })
        GGMessageMenuHooks.filter.register({ items, context in
            return GGAntiDeleteMessageMenu.filter(items, context)
        }, order: 100)

        // Profile «…».
        GGPeerInfoHooks.menuItems.register({ context in
            return GGAntiDeletePeerMenu.items(context)
        })

        // Chat list preview with the local edit; late, so a locked chat's hidden preview wins.
        GGChatListHooks.previewText.register({ row in
            return GGAntiDeleteChatList.previewText(row)
        }, order: 1000)

        // Reply to a deleted message → a quote, before the other outgoing transformers.
        GGOutgoingHooks.messages.register({ messages, context in
            GGAntiDeleteReplyQuote.transform(&messages, context: context)
        }, order: -100)
        GGChatScreenHooks.replySubject.register({ subject, request in
            GGAntiDeleteReplyQuote.warmUp(request)
            return subject
        })

        // A chat opens: archived media of its kept messages go back into the cache if it lost them.
        GGChatScreenHooks.lifecycle.register({ event, screen in
            guard case .willAppear = event, !screen.isPreview, let peerId = screen.chatLocation.peerId else {
                return
            }
            let context = screen.context
            if GGAntiDeleteAccounts.shared.count(account: context.account.id, kind: .deleted, peerId: peerId) == 0 {
                return
            }
            guard let basePath = GGAntiDeleteAccounts.shared.basePath(for: context.account.id) else {
                return
            }
            GGAntiDeleteMediaArchive.restore(postbox: context.account.postbox, basePath: basePath, peerId: peerId, completion: { restored in
                if !restored.isEmpty {
                    Queue.mainQueue().async {
                        GGMessageDecorationHooks.redraw(messageIds: restored)
                    }
                }
            })
        })

        // Excluded folders follow folder changes of every running account.
        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGAntiDeleteFolderSync.start(sharedContext: context.sharedContext)
            GGAntiDeleteModule.sharedContext = context.sharedContext
        })

        // Background work only on return to the app, throttled (GGCore scheduler).
        GGForegroundTaskScheduler.shared.register(id: "antiDelete.inbox", minimumInterval: 60.0, delay: 1.0, task: { done in
            GGAntiDeleteIndexQueue.shared.drainInbox(completion: {
                Queue.mainQueue().async {
                    done()
                }
            })
            return EmptyDisposable
        })
        GGForegroundTaskScheduler.shared.register(id: "antiDelete.autoClear", minimumInterval: 6.0 * 60.0 * 60.0, delay: 8.0, task: { done in
            return (GGAntiDeleteOperations.pruneAllAccounts()
            |> deliverOnMainQueue).start(completed: {
                done()
            })
        })
        GGForegroundTaskScheduler.shared.register(id: "antiDelete.folders", minimumInterval: 15.0 * 60.0, delay: 5.0, task: { done in
            guard let sharedContext = GGAntiDeleteModule.sharedContext else {
                done()
                return EmptyDisposable
            }
            return (GGAntiDeleteFolderSync.refreshAll(sharedContext: sharedContext)
            |> deliverOnMainQueue).start(completed: {
                done()
            })
        })
    }

    /// Set when the first account's UI is up (main thread); used by the foreground refresh.
    fileprivate static weak var sharedContext: SharedAccountContext?
}
