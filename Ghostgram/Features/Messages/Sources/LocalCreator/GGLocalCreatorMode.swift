import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import UndoUI
import AppBundle
import GGCore
import GGHooks
import GGFeaturesShared

/// «Локальный режим создателя канала»: in a broadcast channel the user can not post to, the
/// composer opens as if the user created the channel. Nothing is faked towards the server: what is
/// written there is stored on this device only (a local message with a mark), so nothing fails on
/// the server. The set is per account (`chats.localCreatorChannels`), read from the settings
/// snapshot everywhere, so it is never stale after an account switch, an import or a reset.
///
/// Points: the profile «…» menu (`GGPeerInfoHooks.menuItems`), `GGRestrictionHooks.canSendMessages`
/// (pickers, galleries), `GGOutgoingHooks.messages` (GGOutgoingTransforms → `storeLocally`), and
/// the input panel decision in ChatInterfaceStateInputPanels.swift (`GGMessagesPolicy`).
enum GGLocalCreatorMode {
    static func register() {
        GGPeerInfoHooks.menuItems.register({ context in
            return GGLocalCreatorMode.menuItems(context)
        })
        GGRestrictionHooks.canSendMessages.register({ peer in
            return GGLocalCreatorMode.isLocalModeInAnyAccount(peer.id) ? true : nil
        })
    }

    /// `canSendMessagesToPeer` does not know the account: a channel id is global, so any account
    /// that put it in the local mode opens it (sending is still decided per account).
    static func isLocalModeInAnyAccount(_ peerId: PeerId) -> Bool {
        if peerId.namespace != Namespaces.Peer.CloudChannel {
            return false
        }
        let key = peerId.ggKey
        for account in GGSettingsStore.shared.registeredAccounts {
            if GGMessagesSettings.localCreatorChannels.value(for: account).contains(key) {
                return true
            }
        }
        return false
    }

    static func canUseLocalMode(_ peer: EnginePeer) -> Bool {
        guard case let .channel(channel) = peer, case .broadcast = channel.info else {
            return false
        }
        return !channel.hasPermission(.sendSomething)
    }

    static func setLocalMode(_ enabled: Bool, peerId: PeerId, accountId: GGAccountID) {
        var channels = GGMessagesSettings.localCreatorChannels.value(for: accountId)
        if enabled {
            channels.insert(peerId.ggKey)
        } else {
            channels.remove(peerId.ggKey)
        }
        GGMessagesSettings.localCreatorChannels.set(channels, for: accountId)
    }

    private static func menuItems(_ context: GGPeerInfoContext) -> [ContextMenuItem] {
        let peer = context.peer
        let accountId = context.context.account.id.gg
        let isEnabled = GGMessagesSettings.localCreatorChannels.value(for: accountId).contains(peer.id.ggKey)
        guard isEnabled || GGLocalCreatorMode.canUseLocalMode(peer) else {
            return []
        }
        let accountContext = context.context
        weak let controller = context.controller
        let title = isEnabled ? GGStrings.Chats.LocalCreator.disable : GGStrings.Chats.LocalCreator.enable
        return [.action(ContextMenuActionItem(text: title, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: isEnabled ? "Chat/Context Menu/Lock" : "Chat/Context Menu/Edit"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            GGLocalCreatorMode.setLocalMode(!isEnabled, peerId: peer.id, accountId: accountId)
            let presentationData = accountContext.sharedContext.currentPresentationData.with { $0 }
            let text = isEnabled ? GGStrings.Chats.LocalCreator.disabled : GGStrings.Chats.LocalCreator.enabled
            controller?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
                return false
            }), in: .current)
        }))]
    }

    /// Messages written in the local mode: stored as local outgoing messages of the channel (never
    /// sent). Forwards keep the original content.
    static func storeLocally(_ messages: [EnqueueMessage], account: Account, peerId: PeerId) {
        if messages.isEmpty {
            return
        }
        let timestamp = Int32(Date().timeIntervalSince1970)
        let _ = (account.postbox.transaction { transaction -> Void in
            var storeMessages: [StoreMessage] = []
            for message in messages {
                var text = ""
                var media: [Media] = []
                var attributes: [MessageAttribute] = []
                var threadId: Int64?
                var groupingKey: Int64?
                switch message {
                case let .message(messageText, messageAttributes, _, mediaReference, messageThreadId, _, _, localGroupingKey, _, _):
                    text = messageText
                    if let mediaReference {
                        media = [mediaReference.media]
                    }
                    attributes = messageAttributes.filter { $0 is TextEntitiesMessageAttribute }
                    threadId = messageThreadId
                    groupingKey = localGroupingKey
                case let .forward(source, messageThreadId, _, _, _):
                    guard let original = transaction.getMessage(source) else {
                        continue
                    }
                    text = original.text
                    media = original.media.filter { !($0 is TelegramMediaWebpage) }
                    attributes = original.attributes.filter { $0 is TextEntitiesMessageAttribute }
                    threadId = messageThreadId
                }
                if text.isEmpty && media.isEmpty {
                    continue
                }
                let entities = (attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities
                let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: attributes, media: media, textEntities: entities, isPinned: false)
                storeMessages.append(StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: Int64.random(in: Int64.min ... Int64.max), groupingKey: groupingKey, threadId: threadId, timestamp: timestamp, flags: [], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: peerId, text: text, attributes: attributes, media: media))
            }
            if !storeMessages.isEmpty {
                let _ = transaction.addMessages(storeMessages, location: .Random)
            }
        }).start()
    }
}
