import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import GGCore
import GGFeaturesShared

/// Reads that the user asks for explicitly («Прочитать», «Прочитать на сервере», a read on action, a
/// kept read sent once ghost mode no longer holds it). They go straight to the server: the chat is
/// usually read on the device already, so the normal push would have nothing to send.
///
/// The requests themselves are `GGExplicitReadRequests` (TelegramCore owns the API layer); it applies
/// the `pts` that `messages.readHistory` / `messages.readMessageContents` return: no gap, no extra
/// difference fetch.
enum GGGhostExplicitReads {
    /// Reads the chat (or the forum topic / monoforum thread) on the server up to `maxId`, and records it.
    /// `maxTimestamp` reads a secret chat up to that date (0 = up to its newest message).
    static func readHistory(account: Account, peerId: PeerId, threadId: Int64?, maxId: Int32, maxTimestamp: Int32 = 0) -> Signal<Bool, NoError> {
        let accountId = account.id.gg
        let key = peerId.ggGhostReadKey(threadId: threadId)
        return account.postbox.transaction { transaction -> (Peer?, Peer?, Int32) in
            let peer = transaction.getPeer(peerId)
            var subPeer: Peer?
            if let threadId = threadId, let peer = peer, peer.isMonoForum {
                subPeer = transaction.getPeer(PeerId(threadId))
            }
            var timestamp: Int32 = maxTimestamp
            if peerId.namespace == Namespaces.Peer.SecretChat && timestamp == 0 {
                timestamp = transaction.getTopPeerMessageIndex(peerId: peerId)?.timestamp ?? 0
            }
            return (peer, subPeer, timestamp)
        }
        |> mapToSignal { peer, subPeer, timestamp -> Signal<Bool, NoError> in
            guard let peer = peer else {
                return .single(false)
            }
            if peer is TelegramSecretChat && timestamp <= 0 {
                return .single(false)
            }
            return GGExplicitReadRequests.readHistory(account: account, peer: peer, subPeer: subPeer, threadId: threadId, maxId: maxId, secretMaxDate: timestamp)
            |> map { success -> Bool in
                if success {
                    if peerId.namespace == Namespaces.Peer.SecretChat {
                        GGGhostReadLedger.shared.noteServerReadSecret(account: accountId, key: key)
                    } else {
                        GGGhostReadLedger.shared.noteServerRead(account: accountId, key: key, maxId: maxId)
                    }
                }
                return success
            }
        }
    }

    /// "Listened / opened" for these messages of one chat (voice, round video, view-once media).
    static func readContents(account: Account, peerId: PeerId, messageIds: [MessageId.Id]) -> Signal<Bool, NoError> {
        if messageIds.isEmpty || peerId.namespace == Namespaces.Peer.SecretChat {
            return .single(false)
        }
        return account.postbox.transaction { transaction -> Peer? in
            return transaction.getPeer(peerId)
        }
        |> mapToSignal { peer -> Signal<Bool, NoError> in
            guard let peer = peer else {
                return .single(false)
            }
            return GGExplicitReadRequests.readMessageContents(account: account, peer: peer, ids: messageIds)
        }
    }

    /// Marks a story as viewed for its author. An active story is read with `stories.readStories`
    /// (up to it); an expired one can be open only from the profile, where views are counted with
    /// `stories.incrementStoryViews` — the old code always used the first and missed pinned stories.
    static func readStory(account: Account, peerId: PeerId, storyId: Int32, isExpired: Bool) -> Signal<Bool, NoError> {
        return account.postbox.transaction { transaction -> Peer? in
            return transaction.getPeer(peerId)
        }
        |> mapToSignal { peer -> Signal<Bool, NoError> in
            guard let peer = peer else {
                return .single(false)
            }
            return GGExplicitReadRequests.readStory(account: account, peer: peer, storyId: storyId, isExpired: isExpired)
        }
    }

    /// One "offline" after a send that the server counted as activity (see GhostChatTracking).
    static func sendOffline(account: Account) -> Signal<Never, NoError> {
        return GGExplicitReadRequests.sendOffline(account: account)
    }

    /// Sends every read of the chat the server has not heard of (kept reads of the chat and its
    /// topics). Used when ghost mode no longer holds them for the chat.
    static func flushKeptReads(account: Account, peerId: PeerId) -> Signal<Never, NoError> {
        let accountId = account.id.gg
        let kept = GGGhostReadLedger.shared.keptReads(account: accountId, peerId: peerId)
        if kept.isEmpty {
            return .complete()
        }
        let prefix = peerId.ggGhostKey
        var signals: [Signal<Bool, NoError>] = []
        for (key, entry) in kept {
            var threadId: Int64?
            if key.count > prefix.count, let separator = key.lastIndex(of: "#") {
                threadId = Int64(key[key.index(after: separator)...])
            }
            signals.append(GGGhostExplicitReads.readHistory(account: account, peerId: peerId, threadId: threadId, maxId: entry.maxId))
        }
        return combineLatest(signals) |> ignoreValues
    }
}
