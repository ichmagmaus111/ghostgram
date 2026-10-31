// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// "Pinned chats beyond the server limit": the server keeps a prefix of a pinned list, a feature
// keeps the rest as a local tail. The points cover every place where a pinned list is limited, where
// the server's list replaces the stored one and where the stored list goes to the server — for
// «Чаты», the archive and «Избранное». Folders are not covered: a folder's pins are not limited on
// their own (only the folder's size is, and the whole folder is synchronized with the server).
// Handlers run inside Postbox transactions: snapshot reads, and the feature's own Postbox records
// through the passed `Transaction` only.

import Foundation
import Postbox
import GGCore

/// A pinned list with its own server limit.
public enum GGPinnedList: Equatable {
    /// «Чаты» (`.root`) or the archive (`.group(1)`): `transaction.getPinnedItemIds(groupId:)`.
    case chats(PeerGroupId)
    /// «Избранное»: pinned dialogs of Saved Messages, `transaction.getPeerPinnedThreads(peerId:)` of
    /// the account's own peer (a thread id is `PeerId.toInt64()` of the chat).
    case savedMessages
}

public struct GGPinLimitRequest {
    public let list: GGPinnedList
    /// The limit the server configuration allows this account (Premium included).
    public let serverLimit: Int
    public let isPremium: Bool
    public let accountPeerId: PeerId
}

public struct GGPinnedListRequest {
    public let list: GGPinnedList
    public let accountPeerId: PeerId
    /// The list stored on this device now (`listToServer`: the list just stored).
    public let local: [PinnedItemId]
    /// `listFromServer`: the server's list, about to replace `local`. `listToServer`: the list about
    /// to go to the server.
    public let proposed: [PinnedItemId]
    /// The limit the server allows this account for this list (Premium included) — the same value
    /// upstream checks when a chat is pinned.
    public let serverLimit: Int
    /// The current transaction: for the feature's own Postbox records.
    public let transaction: Transaction
}

/// One synchronization of «Чаты» or the archive (`messages.getPinnedDialogs`).
public struct GGPinnedSyncRequest {
    public let groupId: PeerGroupId
    public let accountPeerId: PeerId
    /// The stored list when the first change that is not synchronized yet was made; upstream treats
    /// it as what the server had.
    public let previous: [PinnedItemId]
    /// The stored list when the synchronization started.
    public let local: [PinnedItemId]
    /// The server's list.
    public let remote: [PinnedItemId]
    /// Upstream's merge of the three: what upstream stores and sends.
    public let merged: [PinnedItemId]
    public let serverLimit: Int
    /// The current transaction: for the feature's own Postbox records.
    public let transaction: Transaction
}

public struct GGPinnedSyncResult {
    /// Stored on this device.
    public let stored: [PinnedItemId]
    /// Sent to the server (`messages.reorderPinnedDialogs`); secret chats are dropped on the wire as
    /// upstream does.
    public let toServer: [PinnedItemId]

    public init(stored: [PinnedItemId], toServer: [PinnedItemId]) {
        self.stored = stored
        self.toServer = toServer
    }
}

public enum GGPinnedChatsHooks {
    /// Policy: how many chats may be pinned locally in a list (nil = the server limit). Asked when a
    /// chat is pinned in «Чаты», the archive or «Избранное»; never for folders.
    public static let pinLimit = GGHookPoint<(GGPinLimitRequest) -> Int?>("pinnedChats.pinLimit")

    /// Transformer: the list stored when the server's list arrives (chat list holes, account state
    /// reset, the first page of Saved Messages, a reorder of Saved Messages pins from the server).
    public static let listFromServer = GGHookPoint<(GGPinnedListRequest) -> [PinnedItemId]>("pinnedChats.listFromServer")

    /// Policy: the merge of a «Чаты» / archive synchronization — what is stored and what goes to the
    /// server. The first non-nil answer wins; nil everywhere = upstream's merge.
    public static let sync = GGHookPoint<(GGPinnedSyncRequest) -> GGPinnedSyncResult?>("pinnedChats.sync")

    /// Transformer: the Saved Messages list sent to the server (`messages.reorderPinnedSavedDialogs`)
    /// when a chat is pinned or the pins are reordered there.
    public static let listToServer = GGHookPoint<(GGPinnedListRequest) -> [PinnedItemId]>("pinnedChats.listToServer")
}

public enum GGLimitHooks {
    /// Policy: how many recently searched chats are kept (upstream: 20).
    public static let recentSearchLimit = GGHookPoint<(Int) -> Int?>("limits.recentSearch")
}

/// The server's limit for a list, computed the way `_internal_toggleItemPinned` computes it (the
/// account's own Premium flag as the server reported it, the app configuration).
private func ggPinnedServerLimit(_ list: GGPinnedList, accountPeerId: PeerId, transaction: Transaction) -> Int {
    let isPremium = transaction.getPeer(accountPeerId)?.isPremium ?? false
    let appConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? .defaultValue
    let limits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: isPremium)
    switch list {
    case let .chats(groupId):
        if case .root = groupId {
            return Int(limits.maxPinnedChatCount)
        }
        return Int(limits.maxArchivedPinnedChatCount)
    case .savedMessages:
        return Int(limits.maxPinnedSavedChatCount)
    }
}

private func ggPinnedThreadId(_ itemId: PinnedItemId) -> Int64 {
    switch itemId {
    case let .peer(peerId):
        return peerId.toInt64()
    }
}

private func ggPinnedPeerId(_ itemId: PinnedItemId) -> PeerId {
    switch itemId {
    case let .peer(peerId):
        return peerId
    }
}

private func ggPinLimit(_ request: GGPinLimitRequest) -> Int {
    for handler in GGPinnedChatsHooks.pinLimit.handlers {
        if let value = handler(request) {
            return max(request.serverLimit, value)
        }
    }
    return request.serverLimit
}

/// GHOST hook target: `_internal_toggleItemPinned` («Чаты», archive).
func ggPinnedChatsLimit(_ serverLimit: Int, groupId: PeerGroupId, isPremium: Bool, accountPeerId: PeerId) -> Int {
    if GGPinnedChatsHooks.pinLimit.isEmpty {
        return serverLimit
    }
    return ggPinLimit(GGPinLimitRequest(list: .chats(groupId), serverLimit: serverLimit, isPremium: isPremium, accountPeerId: accountPeerId))
}

/// GHOST hook target: `TelegramEngine.Peers.toggleForumChannelTopicPinned` for the account's own
/// peer («Избранное»).
func ggPinnedSavedChatsLimit(_ serverLimit: Int, isPremium: Bool, accountPeerId: PeerId) -> Int {
    if GGPinnedChatsHooks.pinLimit.isEmpty {
        return serverLimit
    }
    return ggPinLimit(GGPinLimitRequest(list: .savedMessages, serverLimit: serverLimit, isPremium: isPremium, accountPeerId: accountPeerId))
}

private func ggPinnedListFromServer(_ list: GGPinnedList, proposed: [PinnedItemId], local: [PinnedItemId], accountPeerId: PeerId, transaction: Transaction) -> [PinnedItemId] {
    let serverLimit = ggPinnedServerLimit(list, accountPeerId: accountPeerId, transaction: transaction)
    var result = proposed
    for handler in GGPinnedChatsHooks.listFromServer.handlers {
        result = handler(GGPinnedListRequest(list: list, accountPeerId: accountPeerId, local: local, proposed: result, serverLimit: serverLimit, transaction: transaction))
    }
    return result
}

/// GHOST hook target: the server's «Чаты» / archive list replaces the stored one (`Holes`,
/// `ResetState`).
func ggPinnedItemIdsFromServer(_ proposed: [PinnedItemId], groupId: PeerGroupId, transaction: Transaction) -> [PinnedItemId] {
    if GGPinnedChatsHooks.listFromServer.isEmpty {
        return proposed
    }
    guard let accountPeerId = ggAccountPeerId(transaction: transaction) else {
        return proposed
    }
    return ggPinnedListFromServer(.chats(groupId), proposed: proposed, local: transaction.getPinnedItemIds(groupId: groupId), accountPeerId: accountPeerId, transaction: transaction)
}

/// GHOST hook target: `applyLoadMessageHistoryThreadsResults` — the first page of a thread list
/// carries its pins. Only the account's own peer (Saved Messages) is a pinned chat list; forums and
/// monoforums pass through untouched.
func ggPinnedSavedThreadIdsFromServer(_ threadIds: [Int64], peerId: PeerId, accountPeerId: PeerId, transaction: Transaction) -> [Int64] {
    if GGPinnedChatsHooks.listFromServer.isEmpty || peerId != accountPeerId {
        return threadIds
    }
    let local = transaction.getPeerPinnedThreads(peerId: accountPeerId).map { PinnedItemId.peer(PeerId($0)) }
    let proposed = threadIds.map { PinnedItemId.peer(PeerId($0)) }
    return ggPinnedListFromServer(.savedMessages, proposed: proposed, local: local, accountPeerId: accountPeerId, transaction: transaction).map(ggPinnedThreadId)
}

/// GHOST hook target: replay of `updatePinnedSavedDialogs` with an order.
func ggPinnedSavedPeerIdsFromServer(_ peerIds: [PeerId], accountPeerId: PeerId, transaction: Transaction) -> [PeerId] {
    if GGPinnedChatsHooks.listFromServer.isEmpty {
        return peerIds
    }
    let local = transaction.getPeerPinnedThreads(peerId: accountPeerId).map { PinnedItemId.peer(PeerId($0)) }
    return ggPinnedListFromServer(.savedMessages, proposed: peerIds.map(PinnedItemId.peer), local: local, accountPeerId: accountPeerId, transaction: transaction).map(ggPinnedPeerId)
}

/// GHOST hook target: `_internal_setForumChannelPinnedTopics` for the account's own peer — the
/// stored Saved Messages list (`threadIds`) is about to go to the server.
func ggPinnedSavedThreadIdsToServer(_ threadIds: [Int64], accountPeerId: PeerId, transaction: Transaction) -> [Int64] {
    if GGPinnedChatsHooks.listToServer.isEmpty {
        return threadIds
    }
    let serverLimit = ggPinnedServerLimit(.savedMessages, accountPeerId: accountPeerId, transaction: transaction)
    let stored = threadIds.map { PinnedItemId.peer(PeerId($0)) }
    var result = stored
    for handler in GGPinnedChatsHooks.listToServer.handlers {
        result = handler(GGPinnedListRequest(list: .savedMessages, accountPeerId: accountPeerId, local: stored, proposed: result, serverLimit: serverLimit, transaction: transaction))
    }
    return result.map(ggPinnedThreadId)
}

/// GHOST hook target: `synchronizePinnedChats`, in the transaction that stores the merge. Returns
/// what to store and what to send; upstream's merge for both while the point is empty.
func ggPinnedChatsSync(previous: [PinnedItemId], local: [PinnedItemId], remote: [PinnedItemId], merged: [PinnedItemId], groupId: PeerGroupId, accountPeerId: PeerId, transaction: Transaction) -> (stored: [PinnedItemId], toServer: [PinnedItemId]) {
    if GGPinnedChatsHooks.sync.isEmpty {
        return (merged, merged)
    }
    let request = GGPinnedSyncRequest(groupId: groupId, accountPeerId: accountPeerId, previous: previous, local: local, remote: remote, merged: merged, serverLimit: ggPinnedServerLimit(.chats(groupId), accountPeerId: accountPeerId, transaction: transaction), transaction: transaction)
    for handler in GGPinnedChatsHooks.sync.handlers {
        if let result = handler(request) {
            return (result.stored, result.toServer)
        }
    }
    return (merged, merged)
}

func ggRecentSearchLimit(_ limit: Int) -> Int {
    if GGLimitHooks.recentSearchLimit.isEmpty {
        return limit
    }
    for handler in GGLimitHooks.recentSearchLimit.handlers {
        if let value = handler(limit) {
            return value
        }
    }
    return limit
}
