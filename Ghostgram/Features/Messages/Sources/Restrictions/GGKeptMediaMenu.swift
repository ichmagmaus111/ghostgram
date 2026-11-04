import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import AppBundle
import UndoUI
import GGCore
import GGHooks
import GGFeaturesShared

/// «Не сжигать исчезающие медиа» keeps view-once media unopened for the sender. «Отметить открытым»
/// in the message's menu (press and hold the kept media in the chat) tells the sender on request and
/// leaves the local copy in place. View-once media opens in its own viewer, which has no «…» menu,
/// so the item lives where the media stays — in the chat.
///
/// Ghost mode offers the same action in chats where it hides read receipts, so this item stays out
/// of those chats (one item, not two). Secret chats report «opened» through their own layer and
/// are left alone: the media is kept there and the other side is not told.
enum GGKeptMediaMenu {
    private static let lock = NSLock()
    private static var reported = Set<MessageId>()

    static func register() {
        GGMessageMenuHooks.items.register({ menuContext in
            guard menuContext.messages.count == 1, let message = menuContext.messages.first, let item = GGKeptMediaMenu.item(message: message, context: menuContext.context) else {
                return []
            }
            return [GGMessageMenuEntry(position: .top, item: item)]
        })
    }

    private static func item(message: Message, context: AccountContext) -> ContextMenuItem? {
        guard GGMessagesSettings.keepSelfDestructingMedia.value else {
            return nil
        }
        guard message.flags.contains(.Incoming), message.ggRawContainsSecretMedia, message.id.namespace == Namespaces.Message.Cloud else { // raw: kept media reads as ordinary (secretMediaDisplay)
            return nil
        }
        let peerId = message.id.peerId
        // View-once media exists in private chats and basic groups; both are read with
        // messages.readMessageContents, which takes bare message ids.
        guard peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup else {
            return nil
        }
        if GGGhostPolicy.hides(.readReceipts, peerId: peerId, account: context.account.id.gg) {
            return nil
        }
        for attribute in message.attributes {
            if let attribute = attribute as? ConsumableContentMessageAttribute, attribute.consumed {
                return nil
            }
        }
        let messageId = message.id
        GGKeptMediaMenu.lock.lock()
        let alreadyReported = GGKeptMediaMenu.reported.contains(messageId)
        GGKeptMediaMenu.lock.unlock()
        if alreadyReported {
            return nil
        }
        return .action(ContextMenuActionItem(text: GGStrings.Restrictions.KeptMedia.markOpened, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Eye"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            let _ = (GGExplicitReadRequests.readMessageContents(account: context.account, peer: nil, ids: [messageId.id])
            |> deliverOnMainQueue).start(next: { success in
                if success {
                    GGKeptMediaMenu.lock.lock()
                    GGKeptMediaMenu.reported.insert(messageId)
                    GGKeptMediaMenu.lock.unlock()
                }
                GGKeptMediaMenu.toast(context: context, text: success ? GGStrings.Restrictions.KeptMedia.markedOpened : GGStrings.Restrictions.KeptMedia.failed)
            })
        }))
    }

    private static func toast(context: AccountContext, text: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), on: .root)
    }
}
