import Foundation
import Postbox
import TelegramCore
import GGCore

// Handlers of the TelegramCore update points. All of them run INSIDE a Postbox transaction
// (replay of updates, history validation, timers, the notification service): they read the
// settings snapshot once, read the messages they decide about and mark them with Ghostgram
// attributes. The index is written later, outside the transaction (GGAntiDeleteIndexQueue).

enum GGAntiDeleteCapture {
    private static func now() -> Int32 {
        return Int32(Date().timeIntervalSince1970)
    }

    private static func source(_ source: GGDeletionSource) -> GGAntiDeleteSource {
        switch source {
        case .remoteUpdate:
            return .remote
        case .historyValidation:
            return .validation
        case .secretChat:
            return .secretChat
        case .autoremoveTimer:
            return .selfDestruct
        case .localForEveryone:
            return .ownForEveryone
        }
    }

    // MARK: Deletions

    /// `GGUpdateHooks.messagesWillBeDeleted`. Returns the ids that stay (marked as deleted).
    /// Messages already kept stay as they are (no rewrite) — except when the user deletes their
    /// own kept message «for everyone» again: that is a conscious second deletion.
    static func messagesWillBeDeleted(_ request: GGDeletionRequest) -> Set<MessageId> {
        if request.ids.isEmpty {
            return []
        }
        let accountId = request.accountId
        let capturing = GGAntiDeletePolicy.capturesDeletions
        if !capturing {
            // Nothing new is kept; only already kept messages need protection, and only in chats
            // that have some. The usual case is «feature off, nothing kept»: no Postbox read at all.
            var mayProtect = false
            for id in request.ids where GGAntiDeleteAccounts.shared.mayHaveKeptMessages(account: accountId, peerId: id.peerId) {
                mayProtect = true
                break
            }
            if !mayProtect {
                return []
            }
        }
        let policy = capturing ? GGAntiDeletePolicy.current(account: accountId) : nil
        let transaction = request.transaction
        let now = GGAntiDeleteCapture.now()
        let storedSource = GGAntiDeleteCapture.source(request.source)
        var kept = Set<MessageId>()
        var newEntries: [PeerId: [GGAntiDeleteLogEntry]] = [:]
        var chatPeers: [PeerId: Peer] = [:]

        for id in request.ids {
            if policy == nil && !GGAntiDeleteAccounts.shared.mayHaveKeptMessages(account: accountId, peerId: id.peerId) {
                continue
            }
            guard let message = transaction.getMessage(id) else {
                continue
            }
            if message.ggIsDeleted {
                if request.source != .localForEveryone {
                    kept.insert(id)
                }
                continue
            }
            guard let policy else {
                continue
            }
            var chatPeer = chatPeers[id.peerId]
            if chatPeer == nil, let peer = transaction.getPeer(id.peerId) {
                chatPeers[id.peerId] = peer
                chatPeer = peer
            }
            if !policy.keepsDeleted(message, source: request.source, chatPeer: chatPeer) {
                continue
            }
            transaction.updateMessage(id, update: { current in
                let attributes = ggReplacingAttribute(current.attributes, with: GGDeletedMessageAttribute(deletedAt: now, source: storedSource))
                return .update(ggStoreMessage(current, attributes: attributes))
            })
            kept.insert(id)
            newEntries[id.peerId, default: []].append(GGAntiDeleteLogEntry(namespace: id.namespace, id: id.id, threadId: message.threadId, time: now, source: storedSource.rawValue, isOutgoing: !message.flags.contains(.Incoming)))
        }
        for (peerId, entries) in newEntries {
            GGAntiDeleteIndexQueue.shared.enqueue(account: accountId, kind: .deleted, peerId: peerId, entries: entries)
        }
        return kept
    }

    // MARK: Cleared history

    /// `GGUpdateHooks.historyWillBeCleared`: «clear up to N» from the server, or a secret chat
    /// cleared by the other side (`namespace == nil`).
    static func historyWillBeCleared(_ request: GGHistoryClearRequest) -> Set<MessageId> {
        let accountId = request.accountPeerId.flatMap(GGAccountHooks.accountId(forAccountPeerId:))
        let transaction = request.transaction
        let peerId = request.peerId
        var keepsAll = false
        if GGAntiDeleteSettings.enabled.value {
            let policy = GGAntiDeletePolicy.current(account: accountId)
            keepsAll = policy.keepsClearedHistory(chatPeerId: peerId, chatPeer: transaction.getPeer(peerId))
        }

        guard let namespace = request.namespace else {
            if !keepsAll {
                return []
            }
            let entries = ggMarkWholeChatDeleted(transaction, peerId: peerId)
            GGAntiDeleteIndexQueue.shared.enqueue(account: accountId, kind: .deleted, peerId: peerId, entries: entries)
            // Any id keeps the whole history (GGUpdateHooks contract).
            return [MessageId(peerId: peerId, namespace: 0, id: 0)]
        }

        let maxId = request.maxId ?? Int32.max
        if keepsAll {
            let now = GGAntiDeleteCapture.now()
            var kept = Set<MessageId>()
            var toMark: [(id: MessageId, threadId: Int64?, isOutgoing: Bool)] = []
            transaction.withAllMessages(peerId: peerId, namespace: namespace, { message in
                if message.id.id <= maxId {
                    kept.insert(message.id)
                    if !message.ggIsDeleted {
                        toMark.append((message.id, message.threadId, !message.flags.contains(.Incoming)))
                    }
                }
                return true
            })
            var entries: [GGAntiDeleteLogEntry] = []
            for item in toMark {
                transaction.updateMessage(item.id, update: { current in
                    let attributes = ggReplacingAttribute(current.attributes, with: GGDeletedMessageAttribute(deletedAt: now, source: .historyCleared))
                    return .update(ggStoreMessage(current, attributes: attributes))
                })
                entries.append(GGAntiDeleteLogEntry(namespace: item.id.namespace, id: item.id.id, threadId: item.threadId, time: now, source: GGAntiDeleteSource.historyCleared.rawValue, isOutgoing: item.isOutgoing))
            }
            GGAntiDeleteIndexQueue.shared.enqueue(account: accountId, kind: .deleted, peerId: peerId, entries: entries)
            return kept
        }

        // Not capturing: only messages kept earlier survive, found through this chat's index
        // (one read instead of a scan of the history).
        if !GGAntiDeleteAccounts.shared.mayHaveKeptMessages(account: accountId, peerId: peerId) {
            return []
        }
        let log = GGAntiDeleteIndexStore.readLog(transaction, kind: .deleted, peerId: peerId)
        var candidates = Set<MessageId>()
        for entry in log.entries where entry.namespace == namespace && entry.id <= maxId && !entry.isArchiveOnly {
            candidates.insert(MessageId(peerId: peerId, namespace: entry.namespace, id: entry.id))
        }
        if candidates.isEmpty {
            return []
        }
        var kept = Set<MessageId>()
        for id in transaction.filterStoredMessageIds(candidates) {
            if let message = transaction.getMessage(id), message.ggIsDeleted {
                kept.insert(id)
            }
        }
        return kept
    }

    // MARK: Edits

    /// The Ghostgram attributes of `previous` that `updated` lacks (the server never sends them).
    static func carryOverLocalAttributes(from previous: [MessageAttribute], into updated: inout [MessageAttribute]) {
        for attribute in previous where attribute is GGAntiDeleteLocalAttribute {
            let attributeType = type(of: attribute)
            if !updated.contains(where: { type(of: $0) == attributeType }) {
                updated.append(attribute)
            }
        }
    }

    /// `GGUpdateHooks.messageWillBeEdited`.
    static func messageWillBeEdited(_ request: GGMessageEditRequest, _ attributes: [MessageAttribute]) -> [MessageAttribute] {
        var result = attributes
        let previous = request.previous
        GGAntiDeleteCapture.carryOverLocalAttributes(from: previous.attributes, into: &result)
        if !GGAntiDeleteSettings.editHistory.value {
            return result
        }
        let accountId = GGAccountHooks.accountId(forAccountPeerId: request.accountPeerId)
        let policy = GGAntiDeletePolicy.current(account: accountId)
        let chatPeer = request.transaction.getPeer(previous.id.peerId)
        if !policy.keepsEdits(chatPeerId: previous.id.peerId, chatPeer: chatPeer) {
            return result
        }

        let previousEntities = previous.textEntitiesAttribute?.entities ?? []
        var updatedEntities: [MessageTextEntity] = []
        for attribute in result {
            if let attribute = attribute as? TextEntitiesMessageAttribute {
                updatedEntities = attribute.entities
                break
            }
        }
        let textChanged = previous.text != request.updatedText || previousEntities != updatedEntities
        let mediaChanged = ggAntiDeleteMediaChanged(previous: previous.media, updated: request.updatedMedia)
        if !textChanged && !mediaChanged {
            return result
        }

        var previousDate = previous.timestamp
        var updatedDate = GGAntiDeleteCapture.now()
        for attribute in previous.attributes {
            if let attribute = attribute as? EditedMessageAttribute {
                previousDate = attribute.date
            }
        }
        for attribute in result {
            if let attribute = attribute as? EditedMessageAttribute {
                updatedDate = attribute.date
            }
        }
        var versions: [GGEditVersion] = []
        for attribute in previous.attributes {
            if let attribute = attribute as? GGEditHistoryMessageAttribute {
                versions = attribute.versions
            }
        }
        versions.append(GGEditVersion(text: previous.text, entities: previousEntities, date: previousDate, mediaDescription: mediaChanged ? ggAntiDeleteMediaToken(previous.media) : nil))
        let history = GGEditHistoryMessageAttribute(versions: versions)
        result = ggReplacingAttribute(result, with: history)

        let entry = GGAntiDeleteLogEntry(namespace: previous.id.namespace, id: previous.id.id, threadId: previous.threadId, time: updatedDate, count: Int32(history.versions.count), isOutgoing: !previous.flags.contains(.Incoming))
        GGAntiDeleteIndexQueue.shared.enqueue(account: accountId, kind: .edited, peerId: previous.id.peerId, entries: [entry])
        return result
    }
}

// MARK: - Media of edited versions

/// A language-neutral token for the media of a version («photo», «file:name.pdf»); the UI
/// localizes it. Stored instead of text so a language switch applies to old versions too.
public func ggAntiDeleteMediaToken(_ media: [Media]) -> String? {
    for item in media {
        if item is TelegramMediaImage {
            return "photo"
        }
        if let file = item as? TelegramMediaFile {
            if file.isInstantVideo {
                return "round"
            }
            if file.isVoice {
                return "voice"
            }
            if file.isSticker || file.isAnimatedSticker {
                return "sticker"
            }
            if file.isVideo {
                return "video"
            }
            if file.isMusic {
                return "audio"
            }
            if let fileName = file.fileName, !fileName.isEmpty {
                return "file:" + fileName
            }
            return "file"
        }
        if item is TelegramMediaMap {
            return "location"
        }
        if item is TelegramMediaContact {
            return "contact"
        }
        if item is TelegramMediaPoll {
            return "poll"
        }
    }
    return nil
}

/// The media of an edited message changed (another photo, file…); web page previews do not count.
func ggAntiDeleteMediaChanged(previous: [Media], updated: [Media]) -> Bool {
    let relevantPrevious = previous.filter { !($0 is TelegramMediaWebpage) }
    let relevantUpdated = updated.filter { !($0 is TelegramMediaWebpage) }
    if relevantPrevious.count != relevantUpdated.count {
        return true
    }
    for (lhs, rhs) in zip(relevantPrevious, relevantUpdated) {
        if let lhsId = lhs.id, let rhsId = rhs.id {
            if lhsId != rhsId {
                return true
            }
        } else if !lhs.isEqual(to: rhs) {
            return true
        }
    }
    return false
}
