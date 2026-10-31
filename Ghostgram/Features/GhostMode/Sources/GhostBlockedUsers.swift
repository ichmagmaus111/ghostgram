import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import ChatListUI
import GGFeaturesShared

/// The blocked list of each account, for «Скрыть сообщения заблокированных». One loader per account,
/// only while the switch is on; it walks every page (the old code stopped at the first 200) and is
/// refreshed from the foreground scheduler — chat screens never create their own lists any more.
/// Lookups read an immutable set: the history builder asks for every message.
final class GGGhostBlockedPeers {
    static let shared = GGGhostBlockedPeers()

    private let sets = Atomic<[GGAccountID: Set<PeerId>]>(value: [:])
    // Main thread.
    private var loaders: [GGAccountID: (BlockedPeersContext, Disposable)] = [:]

    private init() {
    }

    func contains(_ peerId: PeerId, account: GGAccountID) -> Bool {
        return self.sets.with { $0[account]?.contains(peerId) ?? false }
    }

    /// Main thread.
    func reload(context: AccountContext) {
        let account = context.account.id.gg
        if self.loaders[account] != nil {
            return
        }
        let blockedContext = BlockedPeersContext(account: context.account, subject: .blocked)
        let disposable = (blockedContext.state
        |> deliverOnMainQueue).start(next: { [weak self, weak blockedContext] state in
            guard let self = self else {
                return
            }
            if state.canLoadMore {
                if !state.isLoadingMore {
                    blockedContext?.loadMore()
                }
                return
            }
            let peerIds = Set(state.peers.map { $0.peerId })
            let _ = self.sets.modify { current in
                var current = current
                current[account] = peerIds
                return current
            }
            // Done: drop the context, the set is what the hooks read.
            Queue.mainQueue().async {
                if let (_, disposable) = self.loaders.removeValue(forKey: account) {
                    disposable.dispose()
                }
            }
        })
        self.loaders[account] = (blockedContext, disposable)
    }

    func clear(account: GGAccountID) {
        if let (_, disposable) = self.loaders.removeValue(forKey: account) {
            disposable.dispose()
        }
        let _ = self.sets.modify { current in
            var current = current
            current.removeValue(forKey: account)
            return current
        }
    }

    /// Whether a message of a group or channel comes from a blocked author.
    func isHidden(_ message: Message, account: GGAccountID, accountPeerId: PeerId) -> Bool {
        if !GGGhostSettings.hideBlockedMessages.value(for: account) {
            return false
        }
        let namespace = message.id.peerId.namespace
        guard namespace == Namespaces.Peer.CloudGroup || namespace == Namespaces.Peer.CloudChannel else {
            return false
        }
        guard let author = message.author, author.id != accountPeerId, author.id != message.id.peerId else {
            return false
        }
        return self.contains(author.id, account: account)
    }

    static func register() {
        GGChatScreenHooks.hidesMessage.register({ message, context, _ in
            return GGGhostBlockedPeers.shared.isHidden(message, account: context.account.id.gg, accountPeerId: context.account.peerId)
        })
        GGChatListHooks.previewText.register({ rowContext in
            let context = rowContext.context
            guard let message = rowContext.messages.last?._asMessage() else {
                return nil
            }
            if !GGGhostBlockedPeers.shared.isHidden(message, account: context.account.id.gg, accountPeerId: context.account.peerId) {
                return nil
            }
            let fontSize = context.sharedContext.currentPresentationData.with { $0 }.listsFontSize.itemListBaseFontSize
            return NSAttributedString(string: GGStrings.GhostMode.Blocked.hiddenPreview, font: Font.regular(floor(fontSize * 15.0 / 17.0)), textColor: rowContext.theme.chatList.messageTextColor)
        }, order: 200)
        // The author line of a hidden message goes with it.
        GGChatListHooks.hidesLastMessageAuthor.register({ rowContext in
            let context = rowContext.context
            guard let message = rowContext.messages.last?._asMessage() else {
                return false
            }
            return GGGhostBlockedPeers.shared.isHidden(message, account: context.account.id.gg, accountPeerId: context.account.peerId)
        })
    }
}
