import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGFeaturesShared

/// The chat screens and the user's own actions:
///
/// - which chat is on screen (an exception that shows online while it is open; a modal over the
///   chat — gallery, sheet — does not count as leaving it);
/// - reads ghost mode kept for a chat are sent when the chat is opened and ghost mode no longer
///   holds them (the receipt goes out at the natural moment, not in a burst when ghost mode is
///   switched off — that would reveal at once everything read while it was on);
/// - «Читать при действиях»: sending or reacting reads that chat on the server — that chat only,
///   up to the message, and never for a delayed or scheduled send;
/// - one "offline" after a send that the server counted as activity;
/// - the tail of hidden messages of blocked users is read with the chat, so it does not stay unread.
enum GGGhostChatTracking {
    static func register() {
        GGChatScreenHooks.lifecycle.register({ event, screen in
            GGGhostChatTracking.handle(event, screen: screen)
        }, order: 100)
        GGOutgoingHooks.didEnqueue.register({ context, ids in
            GGGhostChatTracking.didSend(account: context.account, peerId: context.peerId, ids: ids)
        }, order: 100)
        GGOutgoingHooks.didReact.register({ context, messageIds in
            GGGhostChatTracking.didReact(account: context.account, peerId: context.peerId, messageIds: messageIds)
        }, order: 100)
        GGOutgoingHooks.didSendStandalone.register({ context in
            GGGhostChatTracking.didSendStandalone(context)
        }, order: 100)
        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGGhostAccounts.shared.note(context)
        }, order: 100)
    }

    // MARK: Chat screens

    private static func handle(_ event: GGChatScreenEvent, screen: GGChatScreen) {
        if screen.isPreview {
            return
        }
        guard let peerId = screen.chatLocation.peerId else {
            return
        }
        let context = screen.context
        let account = context.account.id.gg
        GGGhostAccounts.shared.note(context)
        switch event {
        case .willAppear:
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).start(next: { peer in
                if let peer = peer {
                    GGGhostPeerTraits.shared.learn(peer, account: account)
                }
            })
        case .didAppear:
            GGGhostPresence.shared.setActiveChat(peerId, account: account)
            if GGGhostReadLedger.shared.hasKeptRead(account: account, peerId: peerId) && !GGGhostPolicy.hides(.readReceipts, peerId: peerId, account: account) {
                let _ = GGGhostExplicitReads.flushKeptReads(account: context.account, peerId: peerId).start()
            }
            GGGhostChatTracking.readHiddenTail(context: context, peerId: peerId)
        case .willDisappear:
            weak let controller = screen.controller
            GGGhostChatTracking.readHiddenTail(context: context, peerId: peerId)
            // A modal over the chat leaves it at the top of its navigation stack; a push or a pop
            // does not. Decide after the transition has started.
            DispatchQueue.main.async {
                if let controller = controller, let navigationController = controller.navigationController as? NavigationController, navigationController.viewControllers.last === controller {
                    return
                }
                if GGGhostPresence.shared.activeChat(account: account) == peerId {
                    GGGhostPresence.shared.setActiveChat(nil, account: account)
                }
            }
        }
    }

    /// How many messages below the newest one are looked at for unread visible messages; a longer
    /// unread run is left as it is.
    private static let hiddenTailScanLimit = 200

    /// Messages of blocked users are hidden from the history, so the chat's read marker stops at the
    /// last visible message and a hidden tail would stay unread forever. Read it with the chat — but
    /// only the hidden tail: while any visible incoming message above the read marker is still unread,
    /// nothing is read (that would mark the whole chat read on the server).
    private static func readHiddenTail(context: AccountContext, peerId: PeerId) {
        let account = context.account.id.gg
        if !GGGhostSettings.hideBlockedMessages.value(for: account) {
            return
        }
        guard peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudChannel else {
            return
        }
        let accountPeerId = context.account.peerId
        let _ = (context.account.postbox.transaction { transaction -> MessageIndex? in
            guard let state = transaction.getCombinedPeerReadState(peerId), state.count > 0 else {
                return nil
            }
            guard let top = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud), let message = transaction.getMessage(top.id) else {
                return nil
            }
            if !GGGhostBlockedPeers.shared.isHidden(message, account: account, accountPeerId: accountPeerId) {
                return nil
            }
            // Walk down from the newest message to the read marker: every unread incoming message on
            // the way must be a hidden one. (`scanTopMessages` does not stop on `false`: the flags do.)
            var reachedRead = false
            var hasVisibleUnread = false
            var scanned = 0
            transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: GGGhostChatTracking.hiddenTailScanLimit, { message in
                if reachedRead || hasVisibleUnread || scanned >= GGGhostChatTracking.hiddenTailScanLimit {
                    return false
                }
                scanned += 1
                if state.isIncomingMessageIndexRead(message.index) {
                    reachedRead = true
                    return false
                }
                if message.flags.contains(.Incoming) && !GGGhostBlockedPeers.shared.isHidden(message, account: account, accountPeerId: accountPeerId) {
                    hasVisibleUnread = true
                    return false
                }
                return true
            })
            if hasVisibleUnread || !reachedRead {
                return nil
            }
            return top
        }
        |> mapToSignal { index -> Signal<Void, NoError> in
            guard let index = index else {
                return .complete()
            }
            return context.engine.messages.applyMaxReadIndexInteractively(index: index)
        }).start()
    }

    // MARK: Own actions

    private static func didSend(account: Account, peerId: PeerId, ids: [MessageId?]) {
        let sent = ids.compactMap { $0 }.filter { id in
            if Namespaces.Message.allNonRegular.contains(id.namespace) {
                return false
            }
            return !Namespaces.Message.allEphemeral.contains(id.namespace)
        }
        // A delayed send stays in the scheduled namespace: no read, no "offline", nothing that
        // would give away the moment of sending.
        if sent.isEmpty || peerId == account.peerId {
            return
        }
        let accountId = account.id.gg
        if GGGhostPolicy.hides(.readReceipts, peerId: peerId, account: accountId) && GGGhostPolicy.readsOnAction(in: peerId, account: accountId) {
            GGGhostChatTracking.readOnAction(account: account, peerId: peerId, messageId: nil, threadFrom: sent.first)
        }
        if GGGhostPolicy.hides(.online, peerId: peerId, account: accountId) {
            Queue.mainQueue().async {
                if let context = GGGhostAccounts.shared.context(for: accountId) {
                    GGGhostAccounts.shared.scheduleOfflineAfterSend(context: context)
                }
            }
        }
    }

    /// A standalone send of the app (the quick forward from a chat): the same «offline» as after an
    /// ordinary send. A scheduled message is no activity. Network queue.
    private static func didSendStandalone(_ context: GGStandaloneSendContext) {
        if context.isScheduled || context.peerId == context.accountPeerId {
            return
        }
        guard let accountId = GGAccountHooks.accountId(forAccountPeerId: context.accountPeerId)?.gg else {
            return
        }
        if !GGGhostPolicy.hides(.online, peerId: context.peerId, account: accountId) {
            return
        }
        Queue.mainQueue().async {
            if let accountContext = GGGhostAccounts.shared.context(for: accountId) {
                GGGhostAccounts.shared.scheduleOfflineAfterSend(context: accountContext)
            }
        }
    }

    private static func didReact(account: Account, peerId: PeerId, messageIds: [MessageId]) {
        let accountId = account.id.gg
        guard let target = messageIds.max(by: { $0.id < $1.id }) else {
            return
        }
        if target.namespace != Namespaces.Message.Cloud {
            return
        }
        if GGGhostPolicy.hides(.readReceipts, peerId: peerId, account: accountId) && GGGhostPolicy.readsOnAction(in: peerId, account: accountId) {
            GGGhostChatTracking.readOnAction(account: account, peerId: peerId, messageId: target, threadFrom: target)
        }
    }

    /// Reads one chat (or its topic) on the server up to `messageId` (nil: its newest message), then
    /// on the device. Only this chat: there is no global "allow everything for N seconds" window.
    private static func readOnAction(account: Account, peerId: PeerId, messageId: MessageId?, threadFrom: MessageId?) {
        let engine = TelegramEngine(account: account)
        let _ = (account.postbox.transaction { transaction -> (MessageIndex?, Int64?) in
            var threadId: Int64?
            if let threadFrom = threadFrom, let peer = transaction.getPeer(peerId), peer.isForumOrMonoForum {
                threadId = transaction.getMessage(threadFrom)?.threadId
            }
            if let messageId = messageId {
                return (transaction.getMessage(messageId)?.index, threadId)
            }
            if let threadId = threadId {
                return (transaction.getMessageHistoryThreadTopMessage(peerId: peerId, threadId: threadId, namespaces: Set([Namespaces.Message.Cloud])), threadId)
            }
            if peerId.namespace == Namespaces.Peer.SecretChat {
                return (transaction.getTopPeerMessageIndex(peerId: peerId), nil)
            }
            return (transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud), nil)
        }
        |> mapToSignal { index, threadId -> Signal<Never, NoError> in
            guard let index = index else {
                return .complete()
            }
            let local: Signal<Never, NoError>
            if threadId == nil {
                local = engine.messages.applyMaxReadIndexInteractively(index: index) |> ignoreValues
            } else {
                local = .complete()
            }
            return GGGhostExplicitReads.readHistory(account: account, peerId: peerId, threadId: threadId, maxId: index.id.id, maxTimestamp: index.timestamp)
            |> ignoreValues
            |> then(local)
        }).start()
    }
}
