import Foundation
import SwiftSignalKit
import Postbox
import TelegramApi
import TelegramCore
import GGCore
import GGFeaturesShared

/// Reads that the user asks for explicitly («Прочитать», «Прочитать на сервере», a read on action, a
/// kept read sent once ghost mode no longer holds it). They go straight to the server: the chat is
/// usually read on the device already, so the normal push would have nothing to send.
///
/// `messages.readHistory` / `messages.readMessageContents` go through `GGExplicitReadRequests`
/// (TelegramCore), which applies the returned `pts`: no gap, no extra difference fetch.
enum GGGhostExplicitReads {
    private static func inputPeer(_ peer: Peer) -> Api.InputPeer? {
        if let user = peer as? TelegramUser, let accessHash = user.accessHash {
            return Api.InputPeer.inputPeerUser(.init(userId: user.id.id._internalGetInt64Value(), accessHash: accessHash.value))
        } else if peer is TelegramGroup {
            return Api.InputPeer.inputPeerChat(.init(chatId: peer.id.id._internalGetInt64Value()))
        } else if let channel = peer as? TelegramChannel, let accessHash = channel.accessHash {
            return Api.InputPeer.inputPeerChannel(.init(channelId: channel.id.id._internalGetInt64Value(), accessHash: accessHash.value))
        }
        return nil
    }

    private static func inputChannel(_ inputPeer: Api.InputPeer) -> Api.InputChannel? {
        if case let .inputPeerChannel(data) = inputPeer {
            return Api.InputChannel.inputChannel(.init(channelId: data.channelId, accessHash: data.accessHash))
        }
        return nil
    }

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
            let request: Signal<Bool, NoError>
            if let secretChat = peer as? TelegramSecretChat {
                guard timestamp > 0 else {
                    return .single(false)
                }
                let inputChat = Api.InputEncryptedChat.inputEncryptedChat(.init(chatId: Int32(truncatingIfNeeded: peer.id.id._internalGetInt64Value()), accessHash: secretChat.accessHash))
                request = account.network.request(Api.functions.messages.readEncryptedHistory(peer: inputChat, maxDate: timestamp))
                |> map { _ -> Bool in true }
                |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
            } else {
                guard let inputPeer = GGGhostExplicitReads.inputPeer(peer) else {
                    return .single(false)
                }
                if let threadId = threadId {
                    if let subPeer = subPeer, let subInputPeer = GGGhostExplicitReads.inputPeer(subPeer) {
                        request = account.network.request(Api.functions.messages.readSavedHistory(parentPeer: inputPeer, peer: subInputPeer, maxId: maxId))
                        |> map { _ -> Bool in true }
                        |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
                    } else {
                        request = account.network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: threadId), readMaxId: maxId))
                        |> map { _ -> Bool in true }
                        |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
                    }
                } else if let inputChannel = GGGhostExplicitReads.inputChannel(inputPeer) {
                    request = account.network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: maxId))
                    |> map { _ -> Bool in true }
                    |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
                } else {
                    request = GGExplicitReadRequests.readHistory(account: account, peer: inputPeer, maxId: maxId)
                }
            }
            return request
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
            guard let peer = peer, let inputPeer = GGGhostExplicitReads.inputPeer(peer) else {
                return .single(false)
            }
            if let inputChannel = GGGhostExplicitReads.inputChannel(inputPeer) {
                return account.network.request(Api.functions.channels.readMessageContents(channel: inputChannel, id: messageIds))
                |> map { _ -> Bool in true }
                |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
            } else {
                return GGExplicitReadRequests.readMessageContents(account: account, ids: messageIds)
            }
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
            guard let peer = peer, let inputPeer = GGGhostExplicitReads.inputPeer(peer) else {
                return .single(false)
            }
            if isExpired {
                return account.network.request(Api.functions.stories.incrementStoryViews(peer: inputPeer, id: [storyId]))
                |> map { _ -> Bool in true }
                |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
            } else {
                return account.network.request(Api.functions.stories.readStories(peer: inputPeer, maxId: storyId))
                |> map { _ -> Bool in true }
                |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
            }
        }
    }

    /// One "offline" after a send that the server counted as activity (see GhostChatTracking).
    static func sendOffline(account: Account) -> Signal<Never, NoError> {
        return account.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in .single(.boolFalse) }
        |> ignoreValues
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
