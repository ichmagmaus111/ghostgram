import Foundation
import UIKit
import Display
import AppBundle
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import ChatListUI
import GGCore
import GGHooks
import GGFeaturesShared

/// The profile's «…» menu (`GGPeerInfoHooks.menuItems`): «Удалённые сообщения», «Изменённые
/// сообщения», «Закладки», and excluding this chat from anti-delete. The counts come from the
/// account's summaries in memory, the namespace from the index (secret chats included).
enum GGAntiDeletePeerMenu {
    private static func icon(_ name: String) -> (PresentationTheme) -> UIImage? {
        return { theme in
            return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
        }
    }

    static func items(_ peerInfo: GGPeerInfoContext) -> [ContextMenuItem] {
        if peerInfo.isSettings {
            return []
        }
        let context = peerInfo.context
        let chatPeerId = (peerInfo.chatPeer ?? peerInfo.peer).id
        let accountId = context.account.id
        var result: [ContextMenuItem] = []

        let push: (ViewController) -> Void = { [weak controller = peerInfo.controller] screen in
            if let navigationController = controller?.navigationController as? NavigationController {
                navigationController.pushViewController(screen)
            } else {
                GGAntiDeleteMessageMenu.rootNavigationController(context)?.pushViewController(screen)
            }
        }

        let deletedCount = GGAntiDeleteAccounts.shared.count(account: accountId, kind: .deleted, peerId: chatPeerId)
        if deletedCount > 0 {
            result.append(.action(ContextMenuActionItem(text: GGStrings.AntiDelete.PeerMenu.deleted(count: deletedCount), icon: GGAntiDeletePeerMenu.icon("Chat/Context Menu/Delete"), action: { _, f in
                f(.dismissWithoutContent)
                push(ggMakeAntiDeleteChatHistoryController(context: context, kind: .deleted, peerId: chatPeerId))
            })))
        }
        let editedCount = GGAntiDeleteAccounts.shared.count(account: accountId, kind: .edited, peerId: chatPeerId)
        if editedCount > 0 {
            result.append(.action(ContextMenuActionItem(text: GGStrings.AntiDelete.PeerMenu.edited(count: editedCount), icon: GGAntiDeletePeerMenu.icon("Chat/Context Menu/Edit"), action: { _, f in
                f(.dismissWithoutContent)
                push(ggMakeAntiDeleteChatHistoryController(context: context, kind: .edited, peerId: chatPeerId))
            })))
        }
        if GGBookmarkSettings.enabled.value && GGAntiDeleteAccounts.shared.hasBookmarks(account: accountId, peerId: chatPeerId) {
            result.append(.action(ContextMenuActionItem(text: GGStrings.Bookmarks.PeerMenu.title, icon: GGAntiDeletePeerMenu.icon("Chat/Context Menu/ReadingList"), action: { _, f in
                f(.dismissWithoutContent)
                push(ggMakeBookmarksController(context: context, peerId: chatPeerId))
            })))
        }

        let capturing = GGAntiDeleteSettings.enabled.value || GGAntiDeleteSettings.keepOwn.value || GGAntiDeleteSettings.keepSelfDestructing.value || GGAntiDeleteSettings.editHistory.value
        if capturing && chatPeerId != context.account.peerId {
            let key = chatPeerId.ggKey
            let excluded = GGAntiDeleteSettings.excludedPeers.value(for: accountId.gg).contains(key)
            result.append(.action(ContextMenuActionItem(text: excluded ? GGStrings.AntiDelete.PeerMenu.include : GGStrings.AntiDelete.PeerMenu.exclude, icon: GGAntiDeletePeerMenu.icon("Chat/Context Menu/Ban"), action: { _, f in
                f(.dismissWithoutContent)
                var peers = GGAntiDeleteSettings.excludedPeers.value(for: accountId.gg)
                if peers.contains(key) {
                    peers.remove(key)
                } else {
                    peers.insert(key)
                }
                GGAntiDeleteSettings.excludedPeers.set(peers, for: accountId.gg)
            })))
        }
        return result
    }
}

/// `GGChatListHooks.previewText`: the row shows the local edit of the last message, like the bubble.
enum GGAntiDeleteChatList {
    static func previewText(_ row: GGChatListRowContext) -> NSAttributedString? {
        guard let message = row.messages.first?._asMessage() else {
            return nil
        }
        var localEdit: GGLocalEditMessageAttribute?
        for attribute in message.attributes {
            if let attribute = attribute as? GGLocalEditMessageAttribute, attribute.isActive {
                localEdit = attribute
            }
        }
        guard let localEdit else {
            return nil
        }
        let presentationData = row.context.sharedContext.currentPresentationData.with { $0 }
        let font = Font.regular(floor(presentationData.listsFontSize.itemListBaseFontSize * 15.0 / 17.0))
        return NSAttributedString(string: localEdit.text.replacingOccurrences(of: "\n", with: " "), font: font, textColor: row.theme.chatList.messageTextColor)
    }
}
