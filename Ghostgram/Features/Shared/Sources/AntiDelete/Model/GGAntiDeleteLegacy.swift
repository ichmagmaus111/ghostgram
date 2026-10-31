import Foundation
import GGCore

// Readers of what the old Ghostgram left behind (same bundle id, so its files are in place):
//   Documents/ghostgram_deleted_archive.json   [ArchivedMessage]
//   Documents/ghostgram_local_edits.json       ["<peer toInt64>_<id>": [text]]
//   Documents/ghostgram_message_bookmarks.json [MessageBookmark]
//   Documents/ghostgram_edited_reactions.json  (not read: the feature was removed; deleted only)
//   UserDefaults ghostgram_edit_history        ["<peer toInt64>_<id>": [{text, editDate}]]
// Every reader is lenient: a damaged element is skipped, never the whole file. Peers were stored
// as `PeerId.toInt64()`, message namespaces not at all (the old code kept cloud messages).

public struct GGLegacyDeletedEntry: Equatable {
    public let peer: GGPeerKey
    public let messageId: Int32
    public let timestamp: Int32
    public let deletedAt: Int32
    public let authorName: String?
    public let authorUsername: String?
    public let text: String
    public let mediaDescription: String?
    public let threadId: Int64?
}

public struct GGLegacyEditVersion: Equatable {
    public let text: String
    public let date: Int32
}

public struct GGLegacyEditEntry: Equatable {
    public let message: GGMessageKey
    /// Oldest first.
    public let versions: [GGLegacyEditVersion]
}

public struct GGLegacyLocalEdit: Equatable {
    public let message: GGMessageKey
    /// The latest local version (the old client showed only the last one).
    public let text: String
}

public struct GGLegacyBookmark: Equatable {
    public let message: GGMessageKey
    public let title: String
    public let messageDate: Int32
    public let createdAt: Int32
}

public enum GGAntiDeleteLegacyParser {
    /// File names in the old app's Documents directory.
    public static let deletedArchiveFiles = ["ghostgram_deleted_archive.json", "ghostgram_deleted_archive.backup.json"]
    public static let localEditsFile = "ghostgram_local_edits.json"
    public static let bookmarksFile = "ghostgram_message_bookmarks.json"
    /// Reactions of the old client: removed without import (the feature is gone since 2026-10-27).
    public static let editedReactionsFiles = ["ghostgram_edited_reactions.json", "ghostgram_edited_reactions.backup.json"]
    public static let deletedReactionsFiles = ["ghostgram_deleted_reactions.json", "ghostgram_deleted_reactions.backup.json"]

    private static func array(_ data: Data) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        return (object as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func dictionary(_ data: Data) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return [:]
        }
        return object as? [String: Any] ?? [:]
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }

    private static func int32(_ value: Any?) -> Int32? {
        guard let value = int64(value) else {
            return nil
        }
        return Int32(exactly: value)
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    /// `ghostgram_deleted_archive.json`. Duplicates (same chat and id) keep the first entry.
    public static func deletedArchive(_ data: Data) -> [GGLegacyDeletedEntry] {
        var result: [GGLegacyDeletedEntry] = []
        var seen = Set<GGMessageKey>()
        for item in array(data) {
            guard let peerValue = int64(item["peerId"]), let messageId = int32(item["messageId"]) else {
                continue
            }
            let peer = GGLegacyKeys.peerKey(fromLegacyInt64: peerValue)
            let key = GGMessageKey(peer: peer, namespace: 0, id: messageId)
            if !seen.insert(key).inserted {
                continue
            }
            let text = item["text"] as? String ?? ""
            let entry = GGLegacyDeletedEntry(
                peer: peer,
                messageId: messageId,
                timestamp: int32(item["timestamp"]) ?? 0,
                deletedAt: int32(item["deletedAt"]) ?? 0,
                authorName: string(item["authorName"]),
                authorUsername: string(item["authorUsername"]),
                text: text,
                mediaDescription: string(item["mediaDescription"]),
                threadId: int64(item["threadId"])
            )
            result.append(entry)
        }
        return result
    }

    /// `ghostgram_edit_history` (UserDefaults data).
    public static func editHistory(_ data: Data) -> [GGLegacyEditEntry] {
        var result: [GGLegacyEditEntry] = []
        for (key, value) in dictionary(data) {
            guard let message = GGLegacyKeys.messageKey(fromLegacyString: key), let records = value as? [Any] else {
                continue
            }
            var versions: [GGLegacyEditVersion] = []
            for case let record as [String: Any] in records {
                guard let text = record["text"] as? String else {
                    continue
                }
                versions.append(GGLegacyEditVersion(text: text, date: int32(record["editDate"]) ?? 0))
            }
            if versions.isEmpty {
                continue
            }
            versions.sort(by: { $0.date < $1.date })
            result.append(GGLegacyEditEntry(message: message, versions: versions))
        }
        result.sort(by: { $0.message < $1.message })
        return result
    }

    /// `ghostgram_local_edits.json`.
    public static func localEdits(_ data: Data) -> [GGLegacyLocalEdit] {
        var result: [GGLegacyLocalEdit] = []
        for (key, value) in dictionary(data) {
            guard let message = GGLegacyKeys.messageKey(fromLegacyString: key), let versions = value as? [Any] else {
                continue
            }
            guard let text = versions.compactMap({ $0 as? String }).last, !text.isEmpty else {
                continue
            }
            result.append(GGLegacyLocalEdit(message: message, text: text))
        }
        result.sort(by: { $0.message < $1.message })
        return result
    }

    /// `ghostgram_message_bookmarks.json`.
    public static func bookmarks(_ data: Data) -> [GGLegacyBookmark] {
        var result: [GGLegacyBookmark] = []
        var seen = Set<GGMessageKey>()
        for item in array(data) {
            guard let peerValue = int64(item["peerId"]), let namespace = int32(item["namespace"]), let id = int32(item["id"]) else {
                continue
            }
            let message = GGMessageKey(peer: GGLegacyKeys.peerKey(fromLegacyInt64: peerValue), namespace: namespace, id: id)
            if !seen.insert(message).inserted {
                continue
            }
            let createdAt: Int32
            if let value = item["createdAt"] as? NSNumber {
                createdAt = Int32(clamping: Int64(value.doubleValue))
            } else {
                createdAt = 0
            }
            result.append(GGLegacyBookmark(message: message, title: item["title"] as? String ?? "", messageDate: int32(item["timestamp"]) ?? 0, createdAt: createdAt))
        }
        return result
    }
}

/// UserDefaults blobs of the old client, moved out of UserDefaults by the global migration and
/// imported per account later (off the main thread). Plain JSON in the app's own container,
/// removed as soon as every account has imported it.
public struct GGAntiDeleteLegacyStash: Equatable {
    public var editHistory: Data?
    public var archiveMirror: Data?

    public init(editHistory: Data?, archiveMirror: Data?) {
        self.editHistory = editHistory
        self.archiveMirror = archiveMirror
    }

    public var isEmpty: Bool {
        return self.editHistory == nil && self.archiveMirror == nil
    }

    public func encode() -> Data {
        var writer = GGBinaryWriter()
        writer.writeUInt8(1)
        writer.writeOptionalString(self.editHistory.map { $0.base64EncodedString() })
        writer.writeOptionalString(self.archiveMirror.map { $0.base64EncodedString() })
        return writer.data
    }

    public init?(data: Data) {
        var reader = GGBinaryReader(data)
        guard let version = reader.readUInt8(), version == 1 else {
            return nil
        }
        guard let editHistory = reader.readOptionalString(), let archiveMirror = reader.readOptionalString() else {
            return nil
        }
        self.editHistory = editHistory.flatMap { Data(base64Encoded: $0) }
        self.archiveMirror = archiveMirror.flatMap { Data(base64Encoded: $0) }
    }
}
