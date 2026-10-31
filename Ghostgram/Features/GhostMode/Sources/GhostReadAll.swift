import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGFeaturesShared

/// «Прочитать локально» and «Прочитать на сервере».
enum GGGhostReadAll {
    /// Every unread chat (root and archive) with its newest message.
    private static func unreadChats(_ transaction: Transaction) -> [(PeerId, MessageIndex)] {
        var result: [(PeerId, MessageIndex)] = []
        var seen = Set<PeerId>()
        for groupId in [PeerGroupId.root, Namespaces.PeerGroup.archive] {
            for peerId in transaction.getUnreadChatListPeerIds(groupId: groupId, filterPredicate: nil, additionalFilter: nil, stopOnFirstMatch: false) {
                if seen.contains(peerId) {
                    continue
                }
                seen.insert(peerId)
                if let index = transaction.getTopPeerMessageIndex(peerId: peerId) {
                    result.append((peerId, index))
                }
            }
        }
        return result
    }

    /// Reads every unread chat on the device only. The receipts stay on the device even with ghost
    /// mode off, but only up to the messages read now: reading newer ones later sends a receipt as
    /// usual. Forum topics are read too, all of them (the old version stopped at 100). Secret chats
    /// are left alone: reading there starts the self-destruct timers. Unread mentions stay: they can
    /// only be cleared on the server. Emits the number of chats read.
    static func readLocally(context: AccountContext) -> Signal<Int, NoError> {
        let account = context.account
        let accountId = account.id.gg
        return account.postbox.transaction { transaction -> ([(PeerId, MessageIndex)], [String: Int32]) in
            let chats = GGGhostReadAll.unreadChats(transaction).filter { $0.0.namespace != Namespaces.Peer.SecretChat }
            var marks: [String: Int32] = [:]
            for (peerId, index) in chats {
                marks[peerId.ggGhostKey] = index.id.id
                guard let peer = transaction.getPeer(peerId), peer.isForumOrMonoForum else {
                    continue
                }
                for item in transaction.getMessageHistoryThreadIndex(peerId: peerId, limit: 10000) {
                    guard var data = item.info.data.get(MessageHistoryThreadData.self) else {
                        continue
                    }
                    if data.incomingUnreadCount == 0 && !data.isMarkedUnread {
                        continue
                    }
                    guard let top = transaction.getMessageHistoryThreadTopMessage(peerId: peerId, threadId: item.threadId, namespaces: Set([Namespaces.Message.Cloud])) else {
                        continue
                    }
                    data.incomingUnreadCount = 0
                    data.isMarkedUnread = false
                    data.maxIncomingReadId = max(top.id.id, data.maxIncomingReadId)
                    data.maxKnownMessageId = max(top.id.id, data.maxKnownMessageId)
                    guard let entry = CodableEntry(data) else {
                        continue
                    }
                    var summary = item.info.summary
                    summary.totalUnreadCount = 0
                    summary.isMarkedUnread = false
                    // A local thread state only: nothing is sent from here.
                    transaction.setMessageHistoryThreadInfo(peerId: peerId, threadId: item.threadId, info: StoredMessageHistoryThreadInfo(data: entry, summary: summary))
                    marks[peerId.ggGhostReadKey(threadId: item.threadId)] = top.id.id
                }
            }
            return (chats, marks)
        }
        |> mapToSignal { chats, marks -> Signal<Int, NoError> in
            if chats.isEmpty {
                return .single(0)
            }
            // The marks go in first: the pushes the reads below schedule must find them.
            GGGhostReadLedger.shared.addLocalReads(account: accountId, marks)
            var signal: Signal<Never, NoError> = .complete()
            // Unread mentions and replies are left as they are: clearing them is a server operation
            // (`messages.readMessageContents`, a voice reply turns «listened»), not a local one.
            for (_, index) in chats {
                signal = signal
                |> then(context.engine.messages.applyMaxReadIndexInteractively(index: index) |> ignoreValues)
            }
            return signal
            |> mapToSignal { _ -> Signal<Int, NoError> in
            }
            |> then(Signal<Int, NoError>.single(chats.count))
        }
    }

    private struct ServerTarget {
        let peerId: PeerId
        let threadId: Int64?
        let maxId: Int32
        /// For chats unread on the device: also read them there.
        let localIndex: MessageIndex?
    }

    private static func parseKey(_ key: String) -> (PeerId, Int64?)? {
        var peerPart = Substring(key)
        var threadId: Int64?
        if let separator = key.firstIndex(of: "#") {
            peerPart = key[key.startIndex ..< separator]
            guard let value = Int64(key[key.index(after: separator)...]) else {
                return nil
            }
            threadId = value
        }
        guard let peerKey = GGPeerKey(string: String(peerPart)) else {
            return nil
        }
        return (PeerId(ggKey: peerKey), threadId)
    }

    /// Reads on the server everything the account has read: the chats unread now (all forum topics
    /// included, not only the first hundred), the reads ghost mode kept on the device and the
    /// local-only marks — the old version sent only the first group and lost the rest.
    /// Emits the number of chats read.
    static func readOnServer(context: AccountContext) -> Signal<Int, NoError> {
        let account = context.account
        let accountId = account.id.gg
        let pending = GGGhostReadLedger.shared.pendingKeys(account: accountId)
        return account.postbox.transaction { transaction -> [ServerTarget] in
            var targets: [ServerTarget] = []
            var covered = Set<String>()
            for (peerId, index) in GGGhostReadAll.unreadChats(transaction) {
                if let peer = transaction.getPeer(peerId), peer.isForumOrMonoForum {
                    for item in transaction.getMessageHistoryThreadIndex(peerId: peerId, limit: 10000) {
                        guard let data = item.info.data.get(MessageHistoryThreadData.self) else {
                            continue
                        }
                        if data.incomingUnreadCount == 0 && !data.isMarkedUnread {
                            continue
                        }
                        guard let top = transaction.getMessageHistoryThreadTopMessage(peerId: peerId, threadId: item.threadId, namespaces: Set([Namespaces.Message.Cloud])) else {
                            continue
                        }
                        let key = peerId.ggGhostReadKey(threadId: item.threadId)
                        covered.insert(key)
                        targets.append(ServerTarget(peerId: peerId, threadId: item.threadId, maxId: top.id.id, localIndex: nil))
                    }
                }
                covered.insert(peerId.ggGhostKey)
                targets.append(ServerTarget(peerId: peerId, threadId: nil, maxId: index.id.id, localIndex: index))
            }
            for (key, entry) in pending.kept where !covered.contains(key) {
                guard let (peerId, threadId) = GGGhostReadAll.parseKey(key) else {
                    continue
                }
                covered.insert(key)
                targets.append(ServerTarget(peerId: peerId, threadId: threadId, maxId: entry.maxId, localIndex: nil))
            }
            for (key, maxId) in pending.local where !covered.contains(key) {
                guard let (peerId, threadId) = GGGhostReadAll.parseKey(key) else {
                    continue
                }
                covered.insert(key)
                targets.append(ServerTarget(peerId: peerId, threadId: threadId, maxId: maxId, localIndex: nil))
            }
            return targets
        }
        |> mapToSignal { targets -> Signal<Int, NoError> in
            GGGhostReadLedger.shared.clear(account: accountId, keptKeys: [], localKeys: Array(pending.local.keys))
            if targets.isEmpty {
                return .single(0)
            }
            // One request at a time: hundreds of chats must not hit the flood limit at once.
            var signal: Signal<Never, NoError> = .complete()
            for target in targets {
                signal = signal |> then(GGGhostExplicitReads.readHistory(account: account, peerId: target.peerId, threadId: target.threadId, maxId: target.maxId) |> ignoreValues)
                if let index = target.localIndex {
                    // The push this schedules finds the server already ahead and sends nothing.
                    signal = signal |> then(context.engine.messages.applyMaxReadIndexInteractively(index: index) |> ignoreValues)
                }
            }
            let chats = Set(targets.map { $0.peerId }).count
            return signal
            |> mapToSignal { _ -> Signal<Int, NoError> in
            }
            |> then(Signal<Int, NoError>.single(chats))
        }
    }
}
