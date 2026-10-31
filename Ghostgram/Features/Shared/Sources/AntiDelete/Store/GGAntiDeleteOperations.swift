import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore

/// User actions and maintenance over the kept data of one account. Every function returns a
/// signal that does its Postbox work in transactions sized by chat (never one transaction for
/// everything) and touches files only on the anti-delete queue.
public enum GGAntiDeleteOperations {
    private static func now() -> Int32 {
        return Int32(Date().timeIntervalSince1970)
    }

    /// Runs the signals one after another; completes after the last one.
    private static func sequence(_ signals: [Signal<Void, NoError>]) -> Signal<Never, NoError> {
        var result: Signal<Never, NoError> = .complete()
        for signal in signals {
            result = result |> then(signal |> ignoreValues)
        }
        return result
    }

    /// One value, computed when `work` completes.
    private static func value<T>(after work: Signal<Never, NoError>, _ make: @escaping () -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            return work.start(completed: {
                subscriber.putNext(make())
                subscriber.putCompletion()
            })
        }
    }

    // MARK: Bookmarks

    /// Sets (`title != nil`) or removes the bookmark of a message.
    public static func setBookmark(postbox: Postbox, accountId: AccountRecordId, messageId: MessageId, title: String?) -> Signal<Never, NoError> {
        let now = GGAntiDeleteOperations.now()
        return postbox.transaction { transaction -> Set<PeerId> in
            guard let message = transaction.getMessage(messageId) else {
                return Set(GGAntiDeleteIndexStore.readBookmarks(transaction).entries.map { PeerId(ggKey: $0.message.peer) })
            }
            let attribute = GGBookmarkMessageAttribute(title: title ?? "", createdAt: now, isActive: title != nil)
            transaction.updateMessage(messageId, update: { current in
                return .update(ggStoreMessage(current, attributes: ggReplacingAttribute(current.attributes, with: attribute)))
            })
            var list = GGAntiDeleteIndexStore.readBookmarks(transaction)
            if let title {
                let evicted = list.set(GGBookmarkEntry(message: messageId.ggKey, threadId: message.threadId, title: title, createdAt: now, messageDate: message.timestamp))
                GGAntiDeleteIndexStore.deactivateBookmarks(transaction, evicted, now: now)
            } else {
                list.remove([messageId.ggKey])
            }
            GGAntiDeleteIndexStore.writeBookmarks(transaction, list: list)
            return Set(list.entries.map { PeerId(ggKey: $0.message.peer) })
        }
        |> map { peers -> Void in
            GGAntiDeleteAccounts.shared.updateBookmarkPeers(account: accountId, peers: peers)
            return Void()
        }
        |> ignoreValues
    }

    /// Removes bookmark entries whose messages are gone (the list screen does it on open).
    public static func reconcileBookmarks(postbox: Postbox, accountId: AccountRecordId) -> Signal<Never, NoError> {
        return postbox.transaction { transaction -> Set<PeerId> in
            var list = GGAntiDeleteIndexStore.readBookmarks(transaction)
            let ids = Set(list.entries.map { MessageId(ggKey: $0.message) })
            let stored = transaction.filterStoredMessageIds(ids)
            let missing = ids.subtracting(stored)
            if !missing.isEmpty {
                list.remove(Set(missing.map(\.ggKey)))
                GGAntiDeleteIndexStore.writeBookmarks(transaction, list: list)
            }
            return Set(list.entries.map { PeerId(ggKey: $0.message.peer) })
        }
        |> map { peers -> Void in
            GGAntiDeleteAccounts.shared.updateBookmarkPeers(account: accountId, peers: peers)
            return Void()
        }
        |> ignoreValues
    }

    // MARK: Local edit

    /// Sets (`text != nil`) or resets the local edit of a message.
    public static func setLocalEdit(postbox: Postbox, messageId: MessageId, text: String?, entities: [MessageTextEntity]) -> Signal<Never, NoError> {
        let now = GGAntiDeleteOperations.now()
        return postbox.transaction { transaction -> Void in
            transaction.updateMessage(messageId, update: { current in
                let attribute = GGLocalEditMessageAttribute(text: text ?? "", entities: text == nil ? [] : entities, date: now, isActive: text != nil)
                return .update(ggStoreMessage(current, attributes: ggReplacingAttribute(current.attributes, with: attribute)))
            })
        }
        |> ignoreValues
    }

    // MARK: Deleted messages

    /// «Удалить у себя»: kept messages go for real (local only) and leave the index.
    public static func deleteKept(postbox: Postbox, accountId: AccountRecordId, messageIds: [MessageId]) -> Signal<Never, NoError> {
        let byPeer = Dictionary(grouping: messageIds, by: { $0.peerId })
        var signals: [Signal<Void, NoError>] = []
        for (peerId, ids) in byPeer {
            signals.append(postbox.transaction { transaction -> [GGAntiDeleteLogKind: GGAntiDeleteSummary] in
                ggDeleteKeptMessages(transaction, postbox: postbox, ids: ids)
                var summaries: [GGAntiDeleteLogKind: GGAntiDeleteSummary] = [:]
                let refs = Set(ids.map { GGAntiDeleteMessageRef(namespace: $0.namespace, id: $0.id) })
                for kind in GGAntiDeleteLogKind.allCases {
                    var summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: kind)
                    GGAntiDeleteIndexStore.remove(transaction, kind: kind, peerId: peerId, refs: refs, summary: &summary)
                    GGAntiDeleteIndexStore.writeSummary(transaction, kind: kind, summary: summary)
                    summaries[kind] = summary
                }
                for id in ids {
                    GGAntiDeleteIndexStore.writeArchived(transaction, id: id, content: nil)
                }
                return summaries
            }
            |> map { summaries -> Void in
                GGAntiDeleteAccounts.shared.updateSummaries(account: accountId, summaries, flushedPeers: [])
                return Void()
            })
        }
        return GGAntiDeleteOperations.sequence(signals)
    }

    /// Drops the saved versions of some messages (their entries leave the edited history).
    public static func removeEditHistory(postbox: Postbox, accountId: AccountRecordId, messageIds: [MessageId]) -> Signal<Never, NoError> {
        let byPeer = Dictionary(grouping: messageIds, by: { $0.peerId })
        var signals: [Signal<Void, NoError>] = []
        for (peerId, ids) in byPeer {
            signals.append(postbox.transaction { transaction -> GGAntiDeleteSummary in
                for id in ids {
                    ggClearEditHistory(transaction, id: id)
                }
                var summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: .edited)
                GGAntiDeleteIndexStore.remove(transaction, kind: .edited, peerId: peerId, refs: Set(ids.map { GGAntiDeleteMessageRef(namespace: $0.namespace, id: $0.id) }), summary: &summary)
                GGAntiDeleteIndexStore.writeSummary(transaction, kind: .edited, summary: summary)
                return summary
            }
            |> map { summary -> Void in
                GGAntiDeleteAccounts.shared.updateSummaries(account: accountId, [.edited: summary], flushedPeers: [])
                return Void()
            })
        }
        return GGAntiDeleteOperations.sequence(signals)
    }

    /// Clears a history: the deleted one deletes the kept messages for real; the edited one
    /// drops the saved versions (not the local edits, not the reactions). One transaction per chat.
    public static func clear(postbox: Postbox, accountId: AccountRecordId, kind: GGAntiDeleteLogKind, peerIds: [PeerId]? = nil) -> Signal<Never, NoError> {
        return postbox.transaction { transaction -> [PeerId] in
            if let peerIds {
                return peerIds
            }
            return GGAntiDeleteIndexStore.readSummary(transaction, kind: kind).peers.keys.map { PeerId(ggKey: $0) }
        }
        |> mapToSignal { peerIds -> Signal<Never, NoError> in
            var signals: [Signal<Void, NoError>] = []
            for peerId in peerIds {
                signals.append(postbox.transaction { transaction -> GGAntiDeleteSummary in
                    let log = GGAntiDeleteIndexStore.readLog(transaction, kind: kind, peerId: peerId)
                    GGAntiDeleteOperations.dropEntries(transaction, postbox: postbox, kind: kind, peerId: peerId, entries: log.entries)
                    GGAntiDeleteIndexStore.writeLog(transaction, kind: kind, peerId: peerId, log: GGAntiDeletePeerLog())
                    var summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: kind)
                    summary.remove(peer: peerId.ggKey)
                    GGAntiDeleteIndexStore.writeSummary(transaction, kind: kind, summary: summary)
                    return summary
                }
                |> map { summary -> Void in
                    GGAntiDeleteAccounts.shared.updateSummaries(account: accountId, [kind: summary], flushedPeers: [peerId])
                    return Void()
                })
            }
            return GGAntiDeleteOperations.sequence(signals)
        }
    }

    /// What dropping index entries means for their messages.
    private static func dropEntries(_ transaction: Transaction, postbox: Postbox, kind: GGAntiDeleteLogKind, peerId: PeerId, entries: [GGAntiDeleteLogEntry]) {
        switch kind {
        case .deleted:
            var ids: [MessageId] = []
            for entry in entries {
                let id = MessageId(peerId: peerId, namespace: entry.namespace, id: entry.id)
                if entry.isArchiveOnly {
                    GGAntiDeleteIndexStore.writeArchived(transaction, id: id, content: nil)
                } else {
                    ids.append(id)
                }
            }
            ggDeleteKeptMessages(transaction, postbox: postbox, ids: ids)
        case .edited:
            for entry in entries {
                ggClearEditHistory(transaction, id: MessageId(peerId: peerId, namespace: entry.namespace, id: entry.id))
            }
        }
    }

    /// Drops index entries whose messages no longer exist (deleted by the user, chat removed).
    public static func reconcile(postbox: Postbox, accountId: AccountRecordId, kind: GGAntiDeleteLogKind, peerId: PeerId) -> Signal<Never, NoError> {
        return postbox.transaction { transaction -> GGAntiDeleteSummary? in
            var log = GGAntiDeleteIndexStore.readLog(transaction, kind: kind, peerId: peerId)
            var ids = Set<MessageId>()
            for entry in log.entries where !entry.isArchiveOnly {
                ids.insert(MessageId(peerId: peerId, namespace: entry.namespace, id: entry.id))
            }
            let missing = ids.subtracting(transaction.filterStoredMessageIds(ids))
            if missing.isEmpty {
                return nil
            }
            log.remove(Set(missing.map { GGAntiDeleteMessageRef(namespace: $0.namespace, id: $0.id) }))
            GGAntiDeleteIndexStore.writeLog(transaction, kind: kind, peerId: peerId, log: log)
            var summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: kind)
            summary.update(peer: peerId.ggKey, log: log)
            GGAntiDeleteIndexStore.writeSummary(transaction, kind: kind, summary: summary)
            return summary
        }
        |> map { summary -> Void in
            if let summary {
                GGAntiDeleteAccounts.shared.updateSummaries(account: accountId, [kind: summary], flushedPeers: [])
            }
            return Void()
        }
        |> ignoreValues
    }

    /// Age limit («Автоочистка») for one account: entries older than `cutoff` go, chat by chat.
    public static func prune(postbox: Postbox, accountId: AccountRecordId, cutoff: Int32) -> Signal<Never, NoError> {
        var signals: [Signal<Void, NoError>] = []
        for kind in GGAntiDeleteLogKind.allCases {
            signals.append(postbox.transaction { transaction -> [PeerId] in
                let summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: kind)
                return summary.peers.keys.map { PeerId(ggKey: $0) }
            }
            |> mapToSignal { peerIds -> Signal<Void, NoError> in
                var perPeer: [Signal<Void, NoError>] = []
                for peerId in peerIds {
                    perPeer.append(postbox.transaction { transaction -> GGAntiDeleteSummary? in
                        var log = GGAntiDeleteIndexStore.readLog(transaction, kind: kind, peerId: peerId)
                        let removed = log.prune(olderThan: cutoff)
                        if removed.isEmpty {
                            return nil
                        }
                        GGAntiDeleteOperations.dropEntries(transaction, postbox: postbox, kind: kind, peerId: peerId, entries: removed)
                        GGAntiDeleteIndexStore.writeLog(transaction, kind: kind, peerId: peerId, log: log)
                        var summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: kind)
                        summary.update(peer: peerId.ggKey, log: log)
                        GGAntiDeleteIndexStore.writeSummary(transaction, kind: kind, summary: summary)
                        return summary
                    }
                    |> map { summary -> Void in
                        if let summary {
                            GGAntiDeleteAccounts.shared.updateSummaries(account: accountId, [kind: summary], flushedPeers: [])
                        }
                        return Void()
                    })
                }
                return GGAntiDeleteOperations.sequence(perPeer)
                |> map { _ -> Void in }
            })
        }
        return GGAntiDeleteOperations.sequence(signals)
    }

    /// The age limit for every running account (foreground task).
    public static func pruneAllAccounts() -> Signal<Never, NoError> {
        let retention = GGAntiDeleteRetention(settingValue: GGAntiDeleteSettings.autoClear.value)
        guard let cutoff = retention.cutoff(now: GGAntiDeleteOperations.now()) else {
            return .complete()
        }
        var result: Signal<Never, NoError> = .complete()
        for state in GGAntiDeleteAccounts.shared.allStates() {
            if let postbox = state.postbox {
                result = result |> then(GGAntiDeleteOperations.prune(postbox: postbox, accountId: state.id, cutoff: cutoff))
            }
        }
        return result
    }

    // MARK: Export / import

    /// What the export collects, chat by chat. One transaction per chat appends its whole batch; the
    /// transactions run one after another, so the arrays grow in place (no copy of everything
    /// collected so far on every record, which kept the Postbox queue busy on a big archive).
    private final class GGAntiDeleteExportAccumulator {
        var deleted: [GGAntiDeleteExportFile.Deleted] = []
        var edited: [GGAntiDeleteExportFile.Edited] = []
    }

    /// The histories of an account (secret chats excluded), built chat by chat.
    public static func export(postbox: Postbox, accountId: AccountRecordId) -> Signal<Data?, NoError> {
        let collected = Atomic<GGAntiDeleteExportAccumulator>(value: GGAntiDeleteExportAccumulator())
        let peersSignal = postbox.transaction { transaction -> [(GGAntiDeleteLogKind, PeerId)] in
            var result: [(GGAntiDeleteLogKind, PeerId)] = []
            for kind in GGAntiDeleteLogKind.allCases {
                for peer in GGAntiDeleteIndexStore.readSummary(transaction, kind: kind).peers.keys.sorted() where !GGAntiDeleteExportFile.isSecretChat(peer) {
                    result.append((kind, PeerId(ggKey: peer)))
                }
            }
            return result
        }
        return peersSignal
        |> mapToSignal { items -> Signal<Data?, NoError> in
            var signals: [Signal<Void, NoError>] = []
            for (kind, peerId) in items {
                signals.append(postbox.transaction { transaction -> Void in
                    let log = GGAntiDeleteIndexStore.readLog(transaction, kind: kind, peerId: peerId)
                    var deleted: [GGAntiDeleteExportFile.Deleted] = []
                    var edited: [GGAntiDeleteExportFile.Edited] = []
                    for entry in log.entries {
                        let id = MessageId(peerId: peerId, namespace: entry.namespace, id: entry.id)
                        switch kind {
                        case .deleted:
                            if let item = GGAntiDeleteOperations.exportDeleted(transaction, id: id, entry: entry) {
                                deleted.append(item)
                            }
                        case .edited:
                            if let message = transaction.getMessage(id), let history = GGAntiDeleteMessageState(attributes: message.attributes).history {
                                edited.append(GGAntiDeleteExportFile.Edited(message: id.ggKey, thread: message.threadId, author: message.author.flatMap { EnginePeer($0).debugDisplayTitle }, current: message.text, versions: history.versions.map { GGAntiDeleteExportFile.Version(text: $0.text, date: $0.date) }))
                            }
                        }
                    }
                    if !deleted.isEmpty || !edited.isEmpty {
                        collected.with { accumulator in
                            accumulator.deleted.append(contentsOf: deleted)
                            accumulator.edited.append(contentsOf: edited)
                        }
                    }
                })
            }
            return GGAntiDeleteOperations.value(after: GGAntiDeleteOperations.sequence(signals), {
                return collected.with { accumulator in
                    return (accumulator.deleted, accumulator.edited)
                }
            })
            // The file is encoded off the Postbox queue (the last transaction completes there).
            |> deliverOn(Queue.concurrentDefaultQueue())
            |> map { value -> Data? in
                let file = GGAntiDeleteExportFile(account: accountId.gg, exportedAt: GGAntiDeleteOperations.now(), deleted: value.0, edited: value.1)
                return file.encode()
            }
        }
    }

    private static func exportDeleted(_ transaction: Transaction, id: MessageId, entry: GGAntiDeleteLogEntry) -> GGAntiDeleteExportFile.Deleted? {
        if let message = transaction.getMessage(id) {
            var username: String?
            if let author = message.author {
                username = EnginePeer(author).addressName
            }
            return GGAntiDeleteExportFile.Deleted(message: id.ggKey, thread: message.threadId, date: message.timestamp, deletedAt: entry.time, author: message.author.flatMap { EnginePeer($0).debugDisplayTitle }, username: username, text: message.text, media: ggAntiDeleteMediaToken(message.media))
        }
        if let content = GGAntiDeleteIndexStore.readArchived(transaction, id: id) {
            return GGAntiDeleteExportFile.Deleted(message: id.ggKey, thread: entry.threadId, date: content.date, deletedAt: content.deletedAt, author: content.authorName, username: content.authorUsername, text: content.text, media: content.mediaDescription)
        }
        return nil
    }

    public struct ImportResult: Equatable {
        public var added: Int
        public var skipped: Int
    }

    /// Adds archive entries from an export file. A message that is still in the chat is never
    /// marked as deleted; versions are added only to the message the file describes (same text).
    public static func importFile(postbox: Postbox, accountId: AccountRecordId, file: GGAntiDeleteExportFile) -> Signal<ImportResult, NoError> {
        let result = Atomic<ImportResult>(value: ImportResult(added: 0, skipped: 0))
        var signals: [Signal<Void, NoError>] = []
        let deletedByPeer = Dictionary(grouping: file.deleted, by: { $0.message.peer })
        for (peer, items) in deletedByPeer {
            let peerId = PeerId(ggKey: peer)
            signals.append(postbox.transaction { transaction -> GGAntiDeleteSummary in
                var entries: [GGAntiDeleteLogEntry] = []
                var skipped = 0
                for item in items {
                    let id = MessageId(ggKey: item.message)
                    if transaction.getMessage(id) != nil || GGAntiDeleteIndexStore.readArchived(transaction, id: id) != nil {
                        skipped += 1
                        continue
                    }
                    GGAntiDeleteIndexStore.writeArchived(transaction, id: id, content: GGAntiDeleteArchivedContent(date: item.date, deletedAt: item.deletedAt, authorName: item.author, authorUsername: item.username, text: item.text, mediaDescription: item.media))
                    entries.append(GGAntiDeleteLogEntry(namespace: id.namespace, id: id.id, threadId: item.thread, time: item.deletedAt, source: GGAntiDeleteSource.imported.rawValue, isArchiveOnly: true))
                }
                var summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: .deleted)
                GGAntiDeleteIndexStore.apply(transaction, kind: .deleted, peerId: peerId, entries: entries, summary: &summary)
                GGAntiDeleteIndexStore.writeSummary(transaction, kind: .deleted, summary: summary)
                let added = entries.count
                let _ = result.modify { value in
                    return ImportResult(added: value.added + added, skipped: value.skipped + skipped)
                }
                return summary
            }
            |> map { summary -> Void in
                GGAntiDeleteAccounts.shared.updateSummaries(account: accountId, [.deleted: summary], flushedPeers: [])
                return Void()
            })
        }
        let editedByPeer = Dictionary(grouping: file.edited, by: { $0.message.peer })
        for (peer, items) in editedByPeer {
            let peerId = PeerId(ggKey: peer)
            signals.append(postbox.transaction { transaction -> GGAntiDeleteSummary in
                var entries: [GGAntiDeleteLogEntry] = []
                var skipped = 0
                for item in items {
                    let id = MessageId(ggKey: item.message)
                    guard let message = transaction.getMessage(id), message.text == item.current, GGAntiDeleteMessageState(attributes: message.attributes).history == nil, !item.versions.isEmpty else {
                        skipped += 1
                        continue
                    }
                    let history = GGEditHistoryMessageAttribute(versions: item.versions.map { GGEditVersion(text: $0.text, entities: [], date: $0.date, mediaDescription: nil) })
                    transaction.updateMessage(id, update: { current in
                        return .update(ggStoreMessage(current, attributes: ggReplacingAttribute(current.attributes, with: history)))
                    })
                    entries.append(GGAntiDeleteLogEntry(namespace: id.namespace, id: id.id, threadId: message.threadId, time: item.versions.last?.date ?? message.timestamp, count: Int32(history.versions.count), isOutgoing: !message.flags.contains(.Incoming)))
                }
                var summary = GGAntiDeleteIndexStore.readSummary(transaction, kind: .edited)
                GGAntiDeleteIndexStore.apply(transaction, kind: .edited, peerId: peerId, entries: entries, summary: &summary)
                GGAntiDeleteIndexStore.writeSummary(transaction, kind: .edited, summary: summary)
                let added = entries.count
                let _ = result.modify { value in
                    return ImportResult(added: value.added + added, skipped: value.skipped + skipped)
                }
                return summary
            }
            |> map { summary -> Void in
                GGAntiDeleteAccounts.shared.updateSummaries(account: accountId, [.edited: summary], flushedPeers: [])
                return Void()
            })
        }
        return GGAntiDeleteOperations.value(after: GGAntiDeleteOperations.sequence(signals), {
            return result.with { $0 }
        })
    }
}
