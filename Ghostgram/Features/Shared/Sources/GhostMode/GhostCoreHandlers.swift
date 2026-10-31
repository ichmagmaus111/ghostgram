import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import GGCore

/// Handlers of the TelegramCore points: what leaves the device about the user's activity. They run
/// in every process that starts Ghostgram (app, notification service, share), on network and
/// Postbox queues, some inside transactions: they read the settings snapshot and memory only.
enum GGGhostCoreHandlers {
    static func register() {
        GGAccountHooks.accountWillStart.register({ context in
            let account = context.id.gg
            GGGhostPeerTraits.shared.accountDidStart(account, postbox: context.postbox)
        })
        GGAccountHooks.accountWillBeRemoved.register({ id in
            let account = id.gg
            GGGhostPeerTraits.shared.accountWillBeRemoved(account)
            GGGhostPresence.shared.accountWillBeRemoved(account)
            GGGhostReadLedger.shared.accountWillBeRemoved(account)
        })

        GGPresenceHooks.onlinePresence.register({ upstream, context in
            return GGGhostPresence.shared.transformOnline(upstream, account: context.accountId.gg)
        })
        GGPresenceHooks.sendTyping.register({ request in
            return GGGhostCoreHandlers.shouldSendTyping(request)
        })
        GGPresenceHooks.sendReadReceipt.register({ request in
            return GGGhostCoreHandlers.shouldSendReadReceipt(request)
        })
        GGPresenceHooks.consumeContent.register({ request in
            return GGGhostCoreHandlers.shouldConsume(request)
        })
        // Inside the transaction that stores (or, for the share extension, Siri and the quick
        // forward, sends) the batch: the chat's peer is known, so a bot is never scheduled.
        GGOutgoingHooks.sendDelay.register({ request in
            return GGGhostCoreHandlers.sendDelay(request)
        }, order: 100)
    }

    private static func account(forAccountPeerId accountPeerId: PeerId?) -> GGAccountID? {
        guard let accountPeerId = accountPeerId, let id = GGAccountHooks.accountId(forAccountPeerId: accountPeerId) else {
            return nil
        }
        return id.gg
    }

    // MARK: «печатает»

    static func shouldSendTyping(_ request: GGTypingRequest) -> Bool? {
        guard let account = GGGhostCoreHandlers.account(forAccountPeerId: request.accountPeerId) else {
            return nil
        }
        GGGhostPeerTraits.shared.learn(request.peer, account: account)
        if !GGGhostPolicy.isEnabled(account) {
            return nil
        }
        let peerId = request.peer.id
        guard let activity = request.activity else {
            // "Stopped typing" only where a start actually went out.
            return GGGhostPresence.shared.takeActivityEnd(for: peerId, account: account) ? nil : false
        }
        if GGGhostPolicy.hides(.typing, peerId: peerId, account: account) {
            let kind = GGGhostActivityKind(activity)
            if !GGGhostPolicy.shownActivities(for: peerId, account: account).contains(kind) {
                return false
            }
        }
        if GGGhostPolicy.hides(.online, peerId: peerId, account: account) {
            // The server relays statuses only from an online account. The first status opens a short
            // online window and is not sent; the next repetition (the activity is re-sent while it
            // lasts) goes out once the account is online. No delayed send racing the presence request.
            let wasOpen = GGGhostPresence.shared.isWindowOpen(account: account)
            GGGhostPresence.shared.openWindow(account: account)
            if !wasOpen {
                return false
            }
        }
        GGGhostPresence.shared.noteActivitySent(to: peerId, account: account)
        return nil
    }

    // MARK: Read receipts

    static func shouldSendReadReceipt(_ request: GGReadReceiptRequest) -> Bool? {
        guard let account = GGGhostCoreHandlers.account(forAccountPeerId: request.accountPeerId) else {
            return nil
        }
        let ledger = GGGhostReadLedger.shared
        let peerId = request.peerId
        switch request.kind {
        case let .history(maxId):
            let key = peerId.ggGhostKey
            if let maxId = maxId, let localMax = ledger.localReadMaxId(account: account, key: key) {
                if maxId <= localMax {
                    // «Прочитать локально»: stays on the device even without ghost mode.
                    ledger.noteKept(account: account, key: key, maxId: maxId, maxTimestamp: 0)
                    return false
                }
                ledger.dropLocalRead(account: account, key: key)
            }
            if !GGGhostPolicy.hides(.readReceipts, peerId: peerId, account: account) {
                // Only worth remembering while ghost mode is on or a kept read is now superseded.
                if GGGhostPolicy.isEnabled(account) || ledger.keptRead(account: account, key: key) != nil {
                    if let maxId = maxId {
                        ledger.noteServerRead(account: account, key: key, maxId: maxId)
                    } else {
                        ledger.noteServerReadSecret(account: account, key: key)
                    }
                }
                return nil
            }
            if let maxId = maxId {
                if let serverMax = ledger.serverReadMaxId(account: account, key: key), maxId <= serverMax {
                    // Already read on the server (an explicit «Прочитать»): nothing new to tell.
                    return false
                }
                ledger.noteKept(account: account, key: key, maxId: maxId, maxTimestamp: 0)
            } else {
                // Secret chats are read by date; the date of the newest read message is not known
                // here, the explicit read takes it from the chat when needed.
                ledger.noteKept(account: account, key: key, maxId: 0, maxTimestamp: Int32(Date().timeIntervalSince1970))
            }
            return false
        case .historyValidation:
            // A validation would replace a local-only read with the server's unread state (and with
            // the server behind, it looped forever). Keep the local state of such chats — only of
            // those: every other chat is checked against the server as usual, ghost mode or not
            // (the check is how unread counters get right after a gap in the history). Reads ghost
            // mode keeps are in the ledger (persisted), so they are covered by the first test.
            if ledger.hasKeptRead(account: account, peerId: peerId) {
                return false
            }
            if ledger.localReadMaxId(account: account, key: peerId.ggGhostKey) != nil {
                return false
            }
            return nil
        case let .thread(threadId, maxId):
            let key = peerId.ggGhostReadKey(threadId: threadId)
            if let localMax = ledger.localReadMaxId(account: account, key: key) {
                if maxId <= localMax {
                    ledger.noteKept(account: account, key: key, maxId: maxId, maxTimestamp: 0)
                    return false
                }
                ledger.dropLocalRead(account: account, key: key)
            }
            if !GGGhostPolicy.hides(.readReceipts, peerId: peerId, account: account) {
                if GGGhostPolicy.isEnabled(account) || ledger.keptRead(account: account, key: key) != nil {
                    ledger.noteServerRead(account: account, key: key, maxId: maxId)
                }
                return nil
            }
            if let serverMax = ledger.serverReadMaxId(account: account, key: key), maxId <= serverMax {
                return false
            }
            ledger.noteKept(account: account, key: key, maxId: maxId, maxTimestamp: 0)
            return false
        case .stories, .storyView:
            return GGGhostPolicy.hides(.storyViews, peerId: peerId, account: account) ? false : nil
        case .messageContents:
            return GGGhostPolicy.hides(.readReceipts, peerId: peerId, account: account) ? false : nil
        }
    }

    // MARK: Listened / opened

    /// Content is consumed on the device as usual in every chat; only the network part is kept:
    /// cloud chats through `synchronizeConsumeMessageContents`, secret chats through their own
    /// `readMessagesContent` operation — both ask `sendReadReceipt` with `.messageContents`.
    /// Here the secret chat's peer is only learned for the exception lists.
    static func shouldConsume(_ request: GGContentConsumptionRequest) -> Bool? {
        let peerId = request.message.id.peerId
        guard peerId.namespace == Namespaces.Peer.SecretChat else {
            return nil
        }
        guard let account = GGGhostCoreHandlers.account(forAccountPeerId: request.accountPeerId) else {
            return nil
        }
        if let peer = request.message.peers[peerId] {
            GGGhostPeerTraits.shared.learn(peer, account: account)
        }
        return nil
    }

    // MARK: Send delay

    static func sendDelay(_ request: GGOutgoingDelayRequest) -> Int32? {
        guard let account = GGGhostCoreHandlers.account(forAccountPeerId: request.accountPeerId) else {
            return nil
        }
        if !GGGhostSettings.sendDelayEnabled.value(for: account) {
            return nil
        }
        if let peer = request.peer {
            GGGhostPeerTraits.shared.learn(peer, account: account)
        }
        if GGSendDelayPolicy.mustSendImmediately(request.attributes) {
            return nil
        }
        // One delay for text and media since 2026-10-27.
        return GGSendDelayPolicy.scheduleTime(account: account, accountPeerId: request.accountPeerId, peerId: request.peerId, peer: request.peer, serverTime: request.serverTime)
    }
}
