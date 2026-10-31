// Examples of registering into GGHooks points. NOT part of any BUILD target and never registered in
// a real launch: it only shows the shapes. Real handlers live in the feature modules
// (Ghostgram/Features/<Zone>) and are registered from their `register()`.

import Foundation
import UIKit
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import GGCore
import GGHooks

enum GGHooksExamples {
    static func registerExamples() {
        // Policy inside a Postbox transaction: keep messages deleted by the other side.
        GGUpdateHooks.messagesWillBeDeleted.register({ request in
            if request.source != .remoteUpdate || request.isExtension {
                return Set()
            }
            // Mark with an own attribute via request.transaction.updateMessage(...) and keep.
            return Set(request.ids)
        })

        // Read receipts: keep everything on the device for secret chats (snapshot read only).
        GGPresenceHooks.sendReadReceipt.register({ request in
            if request.peerId.namespace == Namespaces.Peer.SecretChat {
                return false
            }
            return nil
        })

        // Outgoing text stage that keeps entities valid.
        GGOutgoingHooks.textStages.register({ text, _ in
            if text.text.hasSuffix("  ") {
                text.text = String(text.text.dropLast())
            }
        }, order: 100)

        // Message decoration: half-transparent messages from a muted author.
        GGMessageDecorationHooks.decorations.register({ decoration, context in
            if context.message.author?.id == context.context.account.peerId {
                return
            }
            decoration.alpha = 0.5
            decoration.statusPrefix = "· "
        })

        // A message menu item at the bottom.
        GGMessageMenuHooks.items.register({ menuContext in
            let item = ContextMenuItem.action(ContextMenuActionItem(text: "Example", icon: { _ in return nil }, action: { _, f in
                f(.default)
            }))
            return [GGMessageMenuEntry(position: .bottom, item: item)]
        })
    }
}
