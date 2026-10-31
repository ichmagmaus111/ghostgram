import Foundation
import Postbox
import TelegramCore
import GGCore

/// The part of GGAntiDelete that the extensions (notification service, share) also link: settings with
/// `.extensions`, NSE handlers, attribute declarations. Owner: W2-2.
public enum GGAntiDeleteShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
        GGAntiDeleteSettings.declare()

        // Attributes: before any Postbox opens, in every process that decodes messages.
        GGMessageAttributeHooks.declareEncodables.register({
            ggDeclareAntiDeleteAttributes()
        })

        // Capture, the same in the app and in the notification service (which marks the shared
        // Postbox itself and hands the index entries to the app).
        GGUpdateHooks.messagesWillBeDeleted.register({ request in
            return GGAntiDeleteCapture.messagesWillBeDeleted(request)
        })
        GGUpdateHooks.historyWillBeCleared.register({ request in
            return GGAntiDeleteCapture.historyWillBeCleared(request)
        })
        GGUpdateHooks.messageWillBeEdited.register({ request, attributes in
            return GGAntiDeleteCapture.messageWillBeEdited(request, attributes)
        })
        // A message stored again from the server (holes, validation) keeps its local attributes.
        GGMessageAttributeHooks.mergeAttributes.register({ previous, updated in
            GGAntiDeleteCapture.carryOverLocalAttributes(from: previous, into: &updated)
        })

        let isApp = GGCore.environment?.process.isApp ?? true
        if isApp {
            GGAccountHooks.accountWillStart.register({ context in
                GGAntiDeleteAccounts.shared.accountDidStart(context)
                if !context.isSupplementary {
                    GGAntiDeleteLegacyImport.importIfNeeded(accountId: context.id, postbox: context.postbox)
                }
            })
            GGAccountHooks.accountWillBeRemoved.register({ id in
                GGAntiDeleteAccounts.shared.accountWillBeRemoved(id)
            })
        }
    }
}
