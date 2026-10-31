import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import AppBundle
import ChatListUI
import GGCore
import GGHooks
import GGFeaturesShared

/// Where «Пароль на чаты» (and the chats of a locked secret folder) reach into Telegram — through the
/// points, not through eleven edits of the chat screen:
/// - opening a chat (`openChat`) asks first; a peek or a chat screen reached any other way is covered
///   (`lifecycle`) and asks when it appears; reading stops while the cover is up;
/// - the chat list row shows «Чат защищён» instead of the text, no thumbnails, no author line;
/// - the search leaves the chat's messages out (every tab);
/// - pushes, banners, the widget and Siri — `GGChatProtection` in GGFeaturesShared;
/// - the profile's «…» menu protects / unprotects one chat (unprotecting asks first).
enum GGChatLockHandlers {
    static func register() {
        let lock = GGChatLock.shared

        GGChatScreenHooks.openChat.register({ params, proceed in
            return lock.interceptOpen(params, proceed: proceed)
        }, order: -100)
        GGChatScreenHooks.lifecycle.register({ event, screen in
            lock.screenEvent(event, screen: screen)
        })

        // Lists: first, so that no other preview handler shows the text of a protected chat.
        GGChatListHooks.previewText.register({ row in
            guard GGChatLockHandlers.hidesRow(row) else {
                return nil
            }
            let fontSize = row.context.sharedContext.currentPresentationData.with { $0 }.listsFontSize.itemListBaseFontSize
            return NSAttributedString(string: GGStrings.Security.ChatLock.previewText, font: Font.regular(floor(fontSize * 15.0 / 17.0)), textColor: row.theme.chatList.messageTextColor)
        }, order: -1000)
        GGChatListHooks.hidesMediaPreview.register({ row in
            return GGChatLockHandlers.hidesRow(row)
        })
        GGChatListHooks.hidesLastMessageAuthor.register({ row in
            return GGChatLockHandlers.hidesRow(row)
        })
        GGChatListHooks.hidesSearchMessages.register({ context, message in
            return lock.hidesContentInLists(account: context.account.id.gg, peerId: message.id.peerId)
        })
        // Rows of chats whose protection or folder lock changed are laid out again (the set changes
        // rarely: a chat added to / removed from the list, the folder opened / locked).
        GGChatListHooks.accessoryPeers.register({ context in
            return GGChatLockHandlers.relayoutPeers(context: context)
        })

        GGPeerInfoHooks.menuItems.register({ info in
            return GGChatLockHandlers.profileMenuItems(info)
        })
        // A profile opened outside the chat: its shared media stay covered until the check.
        GGProfileMediaLock.register()
    }

    private static func hidesRow(_ row: GGChatListRowContext) -> Bool {
        guard let peer = row.peer else {
            return false
        }
        let lock = GGChatLock.shared
        lock.notePeer(peer)
        return lock.hidesContentInLists(account: row.context.account.id.gg, peerId: peer.id)
    }

    private static func relayoutPeers(context: AccountContext) -> Signal<Set<EnginePeer.Id>, NoError> {
        let account = context.account.id.gg
        return combineLatest(
            GGSecuritySharedSettings.chatLockEnabled.signal,
            GGSecuritySharedSettings.chatLockPeers.signal(for: account),
            GGSecuritySharedSettings.secretFolderPeers.signal(for: account),
            GGSecretFolder.shared.unlockedSignal(account: account)
        )
        |> map { enabled, peers, folderPeers, folderUnlocked -> Set<EnginePeer.Id> in
            var result = Set<EnginePeer.Id>()
            if enabled {
                for key in peers {
                    result.insert(PeerId(ggKey: key))
                }
            }
            if !folderUnlocked {
                for key in folderPeers {
                    result.insert(PeerId(ggKey: key))
                }
            }
            return result
        }
        |> distinctUntilChanged
    }

    // MARK: Profile menu

    private static func profileMenuItems(_ info: GGPeerInfoContext) -> [ContextMenuItem] {
        guard !info.isSettings, GGSecuritySharedSettings.chatLockEnabled.value, !GGSecuritySharedSettings.chatLockAllChats.value else {
            return []
        }
        let peerId = info.chatPeer?.id ?? info.peer.id
        if peerId == info.context.account.peerId || !GGChatProtection.isLockable(peerId) {
            return []
        }
        let context = info.context
        let account = context.account.id.gg
        let key = peerId.ggKey
        let isProtected = GGSecuritySharedSettings.chatLockPeers.value(for: account).contains(key)
        let title = isProtected ? GGStrings.Security.ChatLock.unprotectChat : GGStrings.Security.ChatLock.protectChat
        return [.action(ContextMenuActionItem(text: title, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Lock"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            let apply: () -> Void = {
                var peers = GGSecuritySharedSettings.chatLockPeers.value(for: account)
                if isProtected {
                    peers.remove(key)
                } else {
                    peers.insert(key)
                }
                GGSecuritySharedSettings.chatLockPeers.set(peers, for: account)
            }
            if isProtected {
                // Taking a chat out of the protection is what an intruder would do: ask first.
                GGLocalAuthGate.shared.authenticate(context: context, reason: GGStrings.Security.Auth.reasonSettings, completion: { granted in
                    if granted {
                        apply()
                    }
                })
            } else {
                apply()
            }
        }))]
    }
}
