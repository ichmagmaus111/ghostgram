import Foundation
import GGCore

// The per-account index of what anti-delete keeps, for the history screens. The messages and
// their attributes in Postbox are the source of truth; the index only says where to look:
// one log per chat (message id, thread, time) plus a summary over all chats. Pure model, the
// Postbox side lives in Store/.

/// Which history a log belongs to.
public enum GGAntiDeleteLogKind: UInt8, CaseIterable {
    case deleted = 0
    case edited = 1
}

/// Why a message is kept as deleted. Stored in the message attribute and in the index.
public enum GGAntiDeleteSource: UInt8 {
    /// `updateDeleteMessages` / `updateDeleteChannelMessages` (incl. getDifference, NSE).
    case remote = 0
    /// History validation found it gone on the server.
    case validation = 1
    /// The other side of a secret chat deleted it or cleared the chat.
    case secretChat = 2
    /// A self-destruct timer fired.
    case selfDestruct = 3
    /// The user deleted their own message for everyone.
    case ownForEveryone = 4
    /// The server cleared the history up to a message (`UpdateMinAvailableMessage`).
    case historyCleared = 5
    /// Imported from the old Ghostgram archive or from an export file.
    case imported = 6
}

/// A message inside one chat.
public struct GGAntiDeleteMessageRef: Hashable {
    public let namespace: Int32
    public let id: Int32

    public init(namespace: Int32, id: Int32) {
        self.namespace = namespace
        self.id = id
    }
}

public struct GGAntiDeleteLogEntry: Equatable {
    public var namespace: Int32
    public var id: Int32
    /// Forum topic / reply thread, so a tap opens the message inside its topic.
    public var threadId: Int64?
    /// Deleted: when it was deleted. Edited: when the latest version was replaced.
    public var time: Int32
    /// `GGAntiDeleteSource` for deleted entries, 0 for edited ones.
    public var source: UInt8
    /// Edited: number of saved previous versions. Deleted: 0.
    public var count: Int32
    public var isOutgoing: Bool
    /// The message is not in Postbox; its content lives in the archive collection (imports).
    public var isArchiveOnly: Bool

    public init(namespace: Int32, id: Int32, threadId: Int64?, time: Int32, source: UInt8 = 0, count: Int32 = 0, isOutgoing: Bool = false, isArchiveOnly: Bool = false) {
        self.namespace = namespace
        self.id = id
        self.threadId = threadId
        self.time = time
        self.source = source
        self.count = count
        self.isOutgoing = isOutgoing
        self.isArchiveOnly = isArchiveOnly
    }

    public var ref: GGAntiDeleteMessageRef {
        return GGAntiDeleteMessageRef(namespace: self.namespace, id: self.id)
    }

    fileprivate func encode(_ writer: inout GGBinaryWriter) {
        var flags: UInt8 = 0
        if self.threadId != nil {
            flags |= 1 << 0
        }
        if self.isOutgoing {
            flags |= 1 << 1
        }
        if self.isArchiveOnly {
            flags |= 1 << 2
        }
        writer.writeUInt8(flags)
        writer.writeInt32(self.namespace)
        writer.writeInt32(self.id)
        if let threadId = self.threadId {
            writer.writeInt64(threadId)
        }
        writer.writeInt32(self.time)
        writer.writeUInt8(self.source)
        writer.writeInt32(self.count)
    }

    fileprivate static func decode(_ reader: inout GGBinaryReader) -> GGAntiDeleteLogEntry? {
        guard let flags = reader.readUInt8(), let namespace = reader.readInt32(), let id = reader.readInt32() else {
            return nil
        }
        var threadId: Int64?
        if (flags & (1 << 0)) != 0 {
            guard let value = reader.readInt64() else {
                return nil
            }
            threadId = value
        }
        guard let time = reader.readInt32(), let source = reader.readUInt8(), let count = reader.readInt32() else {
            return nil
        }
        return GGAntiDeleteLogEntry(namespace: namespace, id: id, threadId: threadId, time: time, source: source, count: count, isOutgoing: (flags & (1 << 1)) != 0, isArchiveOnly: (flags & (1 << 2)) != 0)
    }
}

/// Everything kept for one chat, oldest first. Bounded: the oldest entries go first.
public struct GGAntiDeletePeerLog: Equatable {
    public static let maximumCount = 2000
    private static let formatVersion: UInt8 = 1

    public private(set) var entries: [GGAntiDeleteLogEntry]

    public init(entries: [GGAntiDeleteLogEntry] = []) {
        self.entries = entries.sorted(by: GGAntiDeletePeerLog.isOrderedBefore)
    }

    private static func isOrderedBefore(_ lhs: GGAntiDeleteLogEntry, _ rhs: GGAntiDeleteLogEntry) -> Bool {
        if lhs.time != rhs.time {
            return lhs.time < rhs.time
        }
        if lhs.namespace != rhs.namespace {
            return lhs.namespace < rhs.namespace
        }
        return lhs.id < rhs.id
    }

    public var isEmpty: Bool {
        return self.entries.isEmpty
    }

    public var count: Int {
        return self.entries.count
    }

    public var lastTime: Int32 {
        return self.entries.last?.time ?? 0
    }

    public func contains(_ ref: GGAntiDeleteMessageRef) -> Bool {
        return self.entries.contains(where: { $0.ref == ref })
    }

    /// Adds new entries and replaces existing ones with the same message (an edited message
    /// gets a new version count and time). Returns the entries dropped by the cap.
    @discardableResult
    public mutating func upsert(_ newEntries: [GGAntiDeleteLogEntry], limit: Int = GGAntiDeletePeerLog.maximumCount) -> [GGAntiDeleteLogEntry] {
        if newEntries.isEmpty {
            return []
        }
        var latest: [GGAntiDeleteMessageRef: GGAntiDeleteLogEntry] = [:]
        for entry in newEntries {
            latest[entry.ref] = entry
        }
        var result = self.entries.filter { latest[$0.ref] == nil }
        result.append(contentsOf: latest.values)
        result.sort(by: GGAntiDeletePeerLog.isOrderedBefore)
        var dropped: [GGAntiDeleteLogEntry] = []
        let bound = max(0, limit)
        if result.count > bound {
            dropped = Array(result.prefix(result.count - bound))
            result.removeFirst(result.count - bound)
        }
        self.entries = result
        return dropped
    }

    /// Removes the given messages; returns how many were there.
    @discardableResult
    public mutating func remove(_ refs: Set<GGAntiDeleteMessageRef>) -> Int {
        if refs.isEmpty {
            return 0
        }
        let before = self.entries.count
        self.entries.removeAll(where: { refs.contains($0.ref) })
        return before - self.entries.count
    }

    /// Removes entries older than `time` (exclusive) and returns them.
    public mutating func prune(olderThan time: Int32) -> [GGAntiDeleteLogEntry] {
        guard let split = self.entries.firstIndex(where: { $0.time >= time }) else {
            let removed = self.entries
            self.entries = []
            return removed
        }
        if split == 0 {
            return []
        }
        let removed = Array(self.entries[0 ..< split])
        self.entries.removeFirst(split)
        return removed
    }

    /// Newest first, for paginated lists.
    public func newestFirst(offset: Int, limit: Int) -> [GGAntiDeleteLogEntry] {
        if offset >= self.entries.count || limit <= 0 {
            return []
        }
        let upper = self.entries.count - max(0, offset)
        let lower = max(0, upper - limit)
        return Array(self.entries[lower ..< upper].reversed())
    }

    public func encode() -> Data {
        var writer = GGBinaryWriter()
        writer.writeUInt8(GGAntiDeletePeerLog.formatVersion)
        writer.writeUInt32(UInt32(clamping: self.entries.count))
        for entry in self.entries {
            entry.encode(&writer)
        }
        return writer.data
    }

    /// nil for damaged or unknown data: the caller starts an empty log.
    public init?(data: Data) {
        var reader = GGBinaryReader(data)
        guard let version = reader.readUInt8(), version == GGAntiDeletePeerLog.formatVersion, let count = reader.readUInt32() else {
            return nil
        }
        var entries: [GGAntiDeleteLogEntry] = []
        entries.reserveCapacity(Int(min(count, UInt32(GGAntiDeletePeerLog.maximumCount * 2))))
        for _ in 0 ..< count {
            guard let entry = GGAntiDeleteLogEntry.decode(&reader) else {
                return nil
            }
            entries.append(entry)
        }
        self.init(entries: entries)
    }
}

public struct GGAntiDeletePeerSummary: Equatable {
    public var count: Int32
    public var lastTime: Int32

    public init(count: Int32, lastTime: Int32) {
        self.count = count
        self.lastTime = lastTime
    }
}

/// Per chat: how many entries and the latest time. Kept in memory per account so menus can ask
/// «does this chat have deleted messages» without touching Postbox.
public struct GGAntiDeleteSummary: Equatable {
    private static let formatVersion: UInt8 = 1

    public private(set) var peers: [GGPeerKey: GGAntiDeletePeerSummary]

    public init(peers: [GGPeerKey: GGAntiDeletePeerSummary] = [:]) {
        self.peers = peers
    }

    public var totalCount: Int {
        var result = 0
        for (_, value) in self.peers {
            result += Int(value.count)
        }
        return result
    }

    public func count(for peer: GGPeerKey) -> Int {
        return Int(self.peers[peer]?.count ?? 0)
    }

    /// Updates the line of one chat from its log; an empty log removes the chat.
    public mutating func update(peer: GGPeerKey, log: GGAntiDeletePeerLog) {
        if log.isEmpty {
            self.peers.removeValue(forKey: peer)
        } else {
            self.peers[peer] = GGAntiDeletePeerSummary(count: Int32(clamping: log.count), lastTime: log.lastTime)
        }
    }

    public mutating func remove(peer: GGPeerKey) {
        self.peers.removeValue(forKey: peer)
    }

    /// Chats, most recent first.
    public var sortedPeers: [(peer: GGPeerKey, summary: GGAntiDeletePeerSummary)] {
        return self.peers.map { (peer: $0.key, summary: $0.value) }.sorted(by: { lhs, rhs in
            if lhs.summary.lastTime != rhs.summary.lastTime {
                return lhs.summary.lastTime > rhs.summary.lastTime
            }
            return lhs.peer < rhs.peer
        })
    }

    public func encode() -> Data {
        var writer = GGBinaryWriter()
        writer.writeUInt8(GGAntiDeleteSummary.formatVersion)
        let sorted = self.peers.keys.sorted()
        writer.writeUInt32(UInt32(clamping: sorted.count))
        for peer in sorted {
            guard let value = self.peers[peer] else {
                continue
            }
            writer.writeInt32(peer.namespace)
            writer.writeInt64(peer.id)
            writer.writeInt32(value.count)
            writer.writeInt32(value.lastTime)
        }
        return writer.data
    }

    public init?(data: Data) {
        var reader = GGBinaryReader(data)
        guard let version = reader.readUInt8(), version == GGAntiDeleteSummary.formatVersion, let count = reader.readUInt32() else {
            return nil
        }
        var peers: [GGPeerKey: GGAntiDeletePeerSummary] = [:]
        for _ in 0 ..< count {
            guard let namespace = reader.readInt32(), let id = reader.readInt64(), let entryCount = reader.readInt32(), let lastTime = reader.readInt32() else {
                return nil
            }
            if let peer = GGPeerKey(namespace: namespace, id: id), entryCount > 0 {
                peers[peer] = GGAntiDeletePeerSummary(count: entryCount, lastTime: lastTime)
            }
        }
        self.init(peers: peers)
    }
}

/// The content of an entry whose message is not in Postbox (old archive, export files).
public struct GGAntiDeleteArchivedContent: Equatable {
    private static let formatVersion: UInt8 = 1

    public var date: Int32
    public var deletedAt: Int32
    public var authorName: String?
    public var authorUsername: String?
    public var text: String
    public var mediaDescription: String?

    public init(date: Int32, deletedAt: Int32, authorName: String?, authorUsername: String?, text: String, mediaDescription: String?) {
        self.date = date
        self.deletedAt = deletedAt
        self.authorName = authorName
        self.authorUsername = authorUsername
        self.text = text
        self.mediaDescription = mediaDescription
    }

    public func encode() -> Data {
        var writer = GGBinaryWriter()
        writer.writeUInt8(GGAntiDeleteArchivedContent.formatVersion)
        writer.writeInt32(self.date)
        writer.writeInt32(self.deletedAt)
        writer.writeOptionalString(self.authorName)
        writer.writeOptionalString(self.authorUsername)
        writer.writeString(self.text)
        writer.writeOptionalString(self.mediaDescription)
        return writer.data
    }

    public init?(data: Data) {
        var reader = GGBinaryReader(data)
        guard let version = reader.readUInt8(), version == GGAntiDeleteArchivedContent.formatVersion else {
            return nil
        }
        guard let date = reader.readInt32(), let deletedAt = reader.readInt32() else {
            return nil
        }
        guard let authorName = reader.readOptionalString(), let authorUsername = reader.readOptionalString(), let text = reader.readString(), let mediaDescription = reader.readOptionalString() else {
            return nil
        }
        self.init(date: date, deletedAt: deletedAt, authorName: authorName, authorUsername: authorUsername, text: text, mediaDescription: mediaDescription)
    }
}

/// A bookmarked message, for «Все закладки» and the bookmark row under the chat search.
public struct GGBookmarkEntry: Equatable {
    public var message: GGMessageKey
    public var threadId: Int64?
    public var title: String
    public var createdAt: Int32
    /// The message's own date, to sort bookmarks of a chat in chat order.
    public var messageDate: Int32

    public init(message: GGMessageKey, threadId: Int64?, title: String, createdAt: Int32, messageDate: Int32) {
        self.message = message
        self.threadId = threadId
        self.title = title
        self.createdAt = createdAt
        self.messageDate = messageDate
    }
}

/// All bookmarks of an account, newest first. Bounded.
public struct GGBookmarkList: Equatable {
    public static let maximumCount = 1000
    private static let formatVersion: UInt8 = 1

    public private(set) var entries: [GGBookmarkEntry]

    public init(entries: [GGBookmarkEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool {
        return self.entries.isEmpty
    }

    public func entry(for message: GGMessageKey) -> GGBookmarkEntry? {
        return self.entries.first(where: { $0.message == message })
    }

    /// Bookmarks of one chat in chat order (oldest message first), for the search row.
    public func entries(peer: GGPeerKey, threadId: Int64?) -> [GGBookmarkEntry] {
        return self.entries.filter { entry in
            if entry.message.peer != peer {
                return false
            }
            if let threadId {
                return entry.threadId == threadId
            }
            return true
        }.sorted(by: { lhs, rhs in
            if lhs.messageDate != rhs.messageDate {
                return lhs.messageDate < rhs.messageDate
            }
            return lhs.message < rhs.message
        })
    }

    /// Puts `entry` first. Returns the oldest entries pushed out by the cap: the caller takes their
    /// mark off the messages too, or they would keep a bookmark no list shows.
    @discardableResult
    public mutating func set(_ entry: GGBookmarkEntry) -> [GGBookmarkEntry] {
        self.entries.removeAll(where: { $0.message == entry.message })
        self.entries.insert(entry, at: 0)
        if self.entries.count > GGBookmarkList.maximumCount {
            let evicted = Array(self.entries[GGBookmarkList.maximumCount...])
            self.entries.removeLast(self.entries.count - GGBookmarkList.maximumCount)
            return evicted
        }
        return []
    }

    @discardableResult
    public mutating func remove(_ messages: Set<GGMessageKey>) -> Int {
        let before = self.entries.count
        self.entries.removeAll(where: { messages.contains($0.message) })
        return before - self.entries.count
    }

    public func encode() -> Data {
        var writer = GGBinaryWriter()
        writer.writeUInt8(GGBookmarkList.formatVersion)
        writer.writeUInt32(UInt32(clamping: self.entries.count))
        for entry in self.entries {
            writer.writeInt32(entry.message.peer.namespace)
            writer.writeInt64(entry.message.peer.id)
            writer.writeInt32(entry.message.namespace)
            writer.writeInt32(entry.message.id)
            if let threadId = entry.threadId {
                writer.writeBool(true)
                writer.writeInt64(threadId)
            } else {
                writer.writeBool(false)
            }
            writer.writeString(entry.title)
            writer.writeInt32(entry.createdAt)
            writer.writeInt32(entry.messageDate)
        }
        return writer.data
    }

    public init?(data: Data) {
        var reader = GGBinaryReader(data)
        guard let version = reader.readUInt8(), version == GGBookmarkList.formatVersion, let count = reader.readUInt32() else {
            return nil
        }
        var entries: [GGBookmarkEntry] = []
        for _ in 0 ..< count {
            guard let peerNamespace = reader.readInt32(), let peerId = reader.readInt64(), let namespace = reader.readInt32(), let id = reader.readInt32(), let hasThread = reader.readBool() else {
                return nil
            }
            var threadId: Int64?
            if hasThread {
                guard let value = reader.readInt64() else {
                    return nil
                }
                threadId = value
            }
            guard let title = reader.readString(), let createdAt = reader.readInt32(), let messageDate = reader.readInt32() else {
                return nil
            }
            if let peer = GGPeerKey(namespace: peerNamespace, id: peerId) {
                entries.append(GGBookmarkEntry(message: GGMessageKey(peer: peer, namespace: namespace, id: id), threadId: threadId, title: title, createdAt: createdAt, messageDate: messageDate))
            }
        }
        self.init(entries: entries)
    }
}
