import Foundation
import Postbox
import TelegramCore
import GGCore

/// «Безлимитные закрепы» — always on (owner's decision 2026-10-22), the same with and without
/// Premium, in «Чаты», the archive and «Избранное».
///
/// One pinned list per place — Telegram's own, stored in Postbox and shown by the chat list as is.
/// Its first N pins (N = what the server allows this account) are the server's part; the rest is a
/// local tail that only this device knows and never goes to the server. Which pins are the tail is
/// remembered per account and list in a Postbox record written in the same transaction as the list
/// (`GGPinnedTailStore`), so a server list that does not mention them cannot be mistaken for
/// "unpinned on another device".
///
/// Folders keep Telegram's behaviour: a folder's pins are not limited on their own (any chat of the
/// folder can be pinned), only the folder's size is, and the whole folder is synchronized with the
/// server (`messages.updateDialogFilter`), so a local "tail" of folder members would be rolled back
/// by the next `updatedChatListFilters`.
enum GGPinnedChats {
    /// The local ceiling of every list. Far beyond any real list (the server allows 5…100); it only
    /// keeps Postbox's 16-bit pinning index safe.
    static let localLimit = 1000

    static func register() {
        GGPinnedChatsHooks.pinLimit.register({ _ in
            return GGPinnedChats.localLimit
        })
        GGPinnedChatsHooks.listFromServer.register({ request in
            return GGPinnedChats.listFromServer(request)
        })
        GGPinnedChatsHooks.sync.register({ request in
            return GGPinnedChats.sync(request)
        })
        GGPinnedChatsHooks.listToServer.register({ request in
            return GGPinnedChats.listToServer(request)
        })
    }

    /// Items the server limit counts. Secret chats are pinned only locally and limited separately,
    /// as upstream does.
    static func isCounted(_ list: GGPinnedList) -> (PinnedItemId) -> Bool {
        switch list {
        case .chats:
            return { item in
                switch item {
                case let .peer(peerId):
                    return peerId.namespace != Namespaces.Peer.SecretChat
                }
            }
        case .savedMessages:
            return { _ in
                return true
            }
        }
    }

    /// The server's list arrived (chat list holes, account state reset, Saved Messages).
    static func listFromServer(_ request: GGPinnedListRequest) -> [PinnedItemId] {
        let isCounted = GGPinnedChats.isCounted(request.list)
        let record = GGPinnedTailStore.read(request.list, transaction: request.transaction)
        let tail = record ?? GGPinnedTailModel.positionalTail(request.local, limit: request.serverLimit, isCounted: isCounted)
        if tail.isEmpty {
            return request.proposed
        }
        let result = GGPinnedTailModel.fromServer(server: request.proposed, local: request.local, tail: tail, isCounted: isCounted)
        GGPinnedTailStore.write(result.tail, list: request.list, current: record, transaction: request.transaction)
        return result.stored
    }

    /// A «Чаты» / archive synchronization.
    static func sync(_ request: GGPinnedSyncRequest) -> GGPinnedSyncResult? {
        let list = GGPinnedList.chats(request.groupId)
        let isCounted = GGPinnedChats.isCounted(list)
        let record = GGPinnedTailStore.read(list, transaction: request.transaction)
        // Without a record the tail is guessed by position; pins the server reports are never in it
        // (it may hold more than the limit: Premium ended, the app configuration not loaded yet).
        let remoteSet = Set(request.remote)
        let tail = record ?? GGPinnedTailModel.positionalTail(request.previous, limit: request.serverLimit, isCounted: isCounted).filter { !remoteSet.contains($0) }
        if tail.isEmpty && request.merged.filter(isCounted).count <= request.serverLimit {
            // Nothing local-only and nothing to cut: upstream's merge as is.
            return nil
        }
        let result = GGPinnedTailModel.sync(previous: request.previous, local: request.local, remote: request.remote, tail: tail, limit: request.serverLimit, isCounted: isCounted)
        GGPinnedTailStore.write(result.tail, list: list, current: record, transaction: request.transaction)
        return GGPinnedSyncResult(stored: result.stored, toServer: result.toServer)
    }

    /// The Saved Messages list goes to the server.
    static func listToServer(_ request: GGPinnedListRequest) -> [PinnedItemId] {
        let record = GGPinnedTailStore.read(request.list, transaction: request.transaction)
        let tail = record ?? []
        if tail.isEmpty && request.proposed.count <= request.serverLimit {
            return request.proposed
        }
        let result = GGPinnedTailModel.push(proposed: request.proposed, tail: tail, limit: request.serverLimit, isCounted: GGPinnedChats.isCounted(request.list))
        GGPinnedTailStore.write(result.tail, list: request.list, current: record, transaction: request.transaction)
        return result.toServer
    }
}

/// The tail of one list: its local-only pins, in the order they were last stored.
struct GGPinnedTailRecord: Codable, Equatable {
    /// `PeerId.toInt64()` — the encoding Postbox itself uses for pinned Saved Messages threads.
    var peerIds: [Int64]
}

/// The tail records live in the account's own Postbox (preferences table), next to the lists they
/// describe, and are written only through the transaction a hook passes — never `UserDefaults`, never
/// a file. Logging out deletes them with the account.
enum GGPinnedTailStore {
    static func key(_ list: GGPinnedList) -> ValueBoxKey {
        switch list {
        case let .chats(groupId):
            return ValueBoxKey("ghostgram.pinnedChats.tail.\(groupId.rawValue)")
        case .savedMessages:
            return ValueBoxKey("ghostgram.pinnedChats.tail.saved")
        }
    }

    /// nil — no record yet (first run, or pins moved over from the old client).
    static func read(_ list: GGPinnedList, transaction: Transaction) -> [PinnedItemId]? {
        guard let entry = transaction.getPreferencesEntry(key: GGPinnedTailStore.key(list)), let record = entry.get(GGPinnedTailRecord.self) else {
            return nil
        }
        return record.peerIds.map { PinnedItemId.peer(PeerId($0)) }
    }

    /// Writes only a change. An empty tail is kept as an empty record once one exists, so the
    /// positional fallback of a missing record never comes back.
    static func write(_ tail: [PinnedItemId], list: GGPinnedList, current: [PinnedItemId]?, transaction: Transaction) {
        if let current {
            if current == tail {
                return
            }
        } else if tail.isEmpty {
            return
        }
        let peerIds = tail.map { item -> Int64 in
            switch item {
            case let .peer(peerId):
                return peerId.toInt64()
            }
        }
        transaction.setPreferencesEntry(key: GGPinnedTailStore.key(list), value: PreferencesEntry(GGPinnedTailRecord(peerIds: peerIds)))
    }
}
