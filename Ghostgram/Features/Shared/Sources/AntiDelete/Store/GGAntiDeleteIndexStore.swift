import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore

/// The anti-delete index inside the account's own Postbox (ItemCache): encrypted like the rest of
/// the account, removed together with it, readable reactively through `combinedView`.
/// Collection ids 120–124 belong to Ghostgram (upstream uses 0…59, `Namespaces.CachedItemCollection`).
public enum GGAntiDeleteIndexStore {
    static let deletedLogsCollection: Int8 = 120
    static let editedLogsCollection: Int8 = 121
    static let bookmarksCollection: Int8 = 122
    static let archivedCollection: Int8 = 123
    static let summariesCollection: Int8 = 124

    private static func logsCollection(_ kind: GGAntiDeleteLogKind) -> Int8 {
        switch kind {
        case .deleted:
            return GGAntiDeleteIndexStore.deletedLogsCollection
        case .edited:
            return GGAntiDeleteIndexStore.editedLogsCollection
        }
    }

    private static func peerKey(_ peerId: PeerId) -> ValueBoxKey {
        let key = peerId.ggKey
        let result = ValueBoxKey(length: 4 + 8)
        result.setInt32(0, value: key.namespace)
        result.setInt64(4, value: key.id)
        return result
    }

    private static func messageKey(_ id: MessageId) -> ValueBoxKey {
        let key = id.peerId.ggKey
        let result = ValueBoxKey(length: 4 + 8 + 4 + 4)
        result.setInt32(0, value: key.namespace)
        result.setInt64(4, value: key.id)
        result.setInt32(12, value: id.namespace)
        result.setInt32(16, value: id.id)
        return result
    }

    private static func singleKey(_ value: UInt8) -> ValueBoxKey {
        let result = ValueBoxKey(length: 1)
        result.setUInt8(0, value: value)
        return result
    }

    // MARK: Entry ids (also the keys of reactive views)

    public static func logEntryId(kind: GGAntiDeleteLogKind, peerId: PeerId) -> ItemCacheEntryId {
        return ItemCacheEntryId(collectionId: GGAntiDeleteIndexStore.logsCollection(kind), key: GGAntiDeleteIndexStore.peerKey(peerId))
    }

    public static func summaryEntryId(kind: GGAntiDeleteLogKind) -> ItemCacheEntryId {
        return ItemCacheEntryId(collectionId: GGAntiDeleteIndexStore.summariesCollection, key: GGAntiDeleteIndexStore.singleKey(kind.rawValue))
    }

    public static var bookmarksEntryId: ItemCacheEntryId {
        return ItemCacheEntryId(collectionId: GGAntiDeleteIndexStore.bookmarksCollection, key: GGAntiDeleteIndexStore.singleKey(0))
    }

    public static func archivedEntryId(_ id: MessageId) -> ItemCacheEntryId {
        return ItemCacheEntryId(collectionId: GGAntiDeleteIndexStore.archivedCollection, key: GGAntiDeleteIndexStore.messageKey(id))
    }

    // MARK: Read / write (inside a transaction)

    public static func readLog(_ transaction: Transaction, kind: GGAntiDeleteLogKind, peerId: PeerId) -> GGAntiDeletePeerLog {
        guard let entry = transaction.retrieveItemCacheEntry(id: GGAntiDeleteIndexStore.logEntryId(kind: kind, peerId: peerId)) else {
            return GGAntiDeletePeerLog()
        }
        return GGAntiDeletePeerLog(data: entry.data) ?? GGAntiDeletePeerLog()
    }

    static func writeLog(_ transaction: Transaction, kind: GGAntiDeleteLogKind, peerId: PeerId, log: GGAntiDeletePeerLog) {
        let id = GGAntiDeleteIndexStore.logEntryId(kind: kind, peerId: peerId)
        if log.isEmpty {
            transaction.removeItemCacheEntry(id: id)
        } else {
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: log.encode()))
        }
    }

    public static func readSummary(_ transaction: Transaction, kind: GGAntiDeleteLogKind) -> GGAntiDeleteSummary {
        guard let entry = transaction.retrieveItemCacheEntry(id: GGAntiDeleteIndexStore.summaryEntryId(kind: kind)) else {
            return GGAntiDeleteSummary()
        }
        return GGAntiDeleteSummary(data: entry.data) ?? GGAntiDeleteSummary()
    }

    static func writeSummary(_ transaction: Transaction, kind: GGAntiDeleteLogKind, summary: GGAntiDeleteSummary) {
        let id = GGAntiDeleteIndexStore.summaryEntryId(kind: kind)
        if summary.peers.isEmpty {
            transaction.removeItemCacheEntry(id: id)
        } else {
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: summary.encode()))
        }
    }

    public static func readBookmarks(_ transaction: Transaction) -> GGBookmarkList {
        guard let entry = transaction.retrieveItemCacheEntry(id: GGAntiDeleteIndexStore.bookmarksEntryId) else {
            return GGBookmarkList()
        }
        return GGBookmarkList(data: entry.data) ?? GGBookmarkList()
    }

    static func writeBookmarks(_ transaction: Transaction, list: GGBookmarkList) {
        if list.isEmpty {
            transaction.removeItemCacheEntry(id: GGAntiDeleteIndexStore.bookmarksEntryId)
        } else {
            transaction.putItemCacheEntry(id: GGAntiDeleteIndexStore.bookmarksEntryId, entry: CodableEntry(data: list.encode()))
        }
    }

    /// Bookmarks the list's cap pushed out lose their mark on the message too: a «🔖» that no list
    /// shows would be a bookmark the user can not find.
    static func deactivateBookmarks(_ transaction: Transaction, _ entries: [GGBookmarkEntry], now: Int32) {
        for entry in entries {
            transaction.updateMessage(MessageId(ggKey: entry.message), update: { current in
                let isActive = current.attributes.contains(where: { attribute in
                    return (attribute as? GGBookmarkMessageAttribute)?.isActive == true
                })
                if !isActive {
                    return .skip
                }
                return .update(ggStoreMessage(current, attributes: ggReplacingAttribute(current.attributes, with: GGBookmarkMessageAttribute(title: "", createdAt: now, isActive: false))))
            })
        }
    }

    public static func readArchived(_ transaction: Transaction, id: MessageId) -> GGAntiDeleteArchivedContent? {
        guard let entry = transaction.retrieveItemCacheEntry(id: GGAntiDeleteIndexStore.archivedEntryId(id)) else {
            return nil
        }
        return GGAntiDeleteArchivedContent(data: entry.data)
    }

    static func writeArchived(_ transaction: Transaction, id: MessageId, content: GGAntiDeleteArchivedContent?) {
        let entryId = GGAntiDeleteIndexStore.archivedEntryId(id)
        if let content {
            transaction.putItemCacheEntry(id: entryId, entry: CodableEntry(data: content.encode()))
        } else {
            transaction.removeItemCacheEntry(id: entryId)
        }
    }

    /// Adds entries of one chat and updates the summary. Returns the new summary and what the cap
    /// pushed out (their messages are deleted for real by the caller: nothing lists them anymore).
    @discardableResult
    static func apply(_ transaction: Transaction, kind: GGAntiDeleteLogKind, peerId: PeerId, entries: [GGAntiDeleteLogEntry], summary: inout GGAntiDeleteSummary) -> [GGAntiDeleteLogEntry] {
        var log = GGAntiDeleteIndexStore.readLog(transaction, kind: kind, peerId: peerId)
        let dropped = log.upsert(entries)
        GGAntiDeleteIndexStore.writeLog(transaction, kind: kind, peerId: peerId, log: log)
        summary.update(peer: peerId.ggKey, log: log)
        return dropped
    }

    /// Removes entries of one chat and updates the summary.
    static func remove(_ transaction: Transaction, kind: GGAntiDeleteLogKind, peerId: PeerId, refs: Set<GGAntiDeleteMessageRef>, summary: inout GGAntiDeleteSummary) {
        if refs.isEmpty {
            return
        }
        var log = GGAntiDeleteIndexStore.readLog(transaction, kind: kind, peerId: peerId)
        if log.remove(refs) == 0 {
            return
        }
        GGAntiDeleteIndexStore.writeLog(transaction, kind: kind, peerId: peerId, log: log)
        summary.update(peer: peerId.ggKey, log: log)
    }

    // MARK: Reactive reads (UI)

    public static func summarySignal(postbox: Postbox, kind: GGAntiDeleteLogKind) -> Signal<GGAntiDeleteSummary, NoError> {
        let key = PostboxViewKey.cachedItem(GGAntiDeleteIndexStore.summaryEntryId(kind: kind))
        return postbox.combinedView(keys: [key])
        |> map { views -> GGAntiDeleteSummary in
            guard let view = views.views[key] as? CachedItemView, let value = view.value else {
                return GGAntiDeleteSummary()
            }
            return GGAntiDeleteSummary(data: value.data) ?? GGAntiDeleteSummary()
        }
        |> distinctUntilChanged
    }

    public static func logSignal(postbox: Postbox, kind: GGAntiDeleteLogKind, peerId: PeerId) -> Signal<GGAntiDeletePeerLog, NoError> {
        let key = PostboxViewKey.cachedItem(GGAntiDeleteIndexStore.logEntryId(kind: kind, peerId: peerId))
        return postbox.combinedView(keys: [key])
        |> map { views -> GGAntiDeletePeerLog in
            guard let view = views.views[key] as? CachedItemView, let value = view.value else {
                return GGAntiDeletePeerLog()
            }
            return GGAntiDeletePeerLog(data: value.data) ?? GGAntiDeletePeerLog()
        }
        |> distinctUntilChanged
    }

    public static func bookmarksSignal(postbox: Postbox) -> Signal<GGBookmarkList, NoError> {
        let key = PostboxViewKey.cachedItem(GGAntiDeleteIndexStore.bookmarksEntryId)
        return postbox.combinedView(keys: [key])
        |> map { views -> GGBookmarkList in
            guard let view = views.views[key] as? CachedItemView, let value = view.value else {
                return GGBookmarkList()
            }
            return GGBookmarkList(data: value.data) ?? GGBookmarkList()
        }
        |> distinctUntilChanged
    }
}
