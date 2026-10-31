import Foundation
import Postbox
import TelegramCore

// `result.json` in Telegram Desktop's format, written as a stream: the file only ever grows by
// committed pages, and a resumed job first cuts it back to the last committed length. Nothing of
// the history is held in memory beyond one page.

/// Appends to one file; can cut it back to a committed length.
final class GGChatExportStream {
    private let handle: FileHandle

    /// Opens (creating if needed) and truncates the file to `length`.
    init(url: URL, length: UInt64) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle.truncate(atOffset: length)
        try self.handle.seekToEnd()
    }

    func append(_ text: String) throws {
        try self.handle.write(contentsOf: Data(text.utf8))
    }

    /// Flushes to disk and returns the length now committed.
    func commit() throws -> UInt64 {
        try self.handle.synchronize()
        return try self.handle.offset()
    }

    func close() {
        try? self.handle.close()
    }
}

enum GGChatExportJSON {
    /// Telegram Desktop's placeholders for files that are not in the export.
    static let notIncluded = "(File not included. Change data exporting settings to download.)"
    static let tooLarge = "(File exceeds maximum size. Change data exporting settings to download.)"
    static let unavailable = "(File unavailable, please try again later)"

    static func string(_ value: String) -> String {
        return GGChatExportEscape.json(value)
    }

    /// `{"name":…,"type":…,"id":…,"messages":[` — the start of a chat object.
    static func chatHeader(name: String, type: String, peerId: PeerId) -> String {
        return "{\"name\":\(GGChatExportJSON.string(name)),\"type\":\(GGChatExportJSON.string(type)),\"id\":\(peerId.id._internalGetInt64Value()),\"messages\":["
    }

    static let chatFooter = "\n]}"

    private static func mediaPath(_ media: GGChatExportMedia, chatDirectory: String) -> String {
        switch media.state {
        case let .saved(path):
            return chatDirectory.isEmpty ? path : chatDirectory + "/" + path
        case .notIncluded:
            return GGChatExportJSON.notIncluded
        case .tooLarge:
            return GGChatExportJSON.tooLarge
        case .unavailable, .pending:
            return GGChatExportJSON.unavailable
        }
    }

    /// One message object. `chatDirectory` prefixes file paths (paths are relative to the export root).
    static func message(_ item: GGChatExportItem, chatDirectory: String, format: GGChatExportFormat) -> String {
        var fields: [String] = []
        fields.append("\"id\":\(item.index.id.id)")
        fields.append("\"type\":\(item.isService ? "\"service\"" : "\"message\"")")
        fields.append("\"date\":\(GGChatExportJSON.string(format.iso(item.timestamp)))")
        fields.append("\"date_unixtime\":\(GGChatExportJSON.string("\(item.timestamp)"))")
        if let edited = item.editedTimestamp {
            fields.append("\"edited\":\(GGChatExportJSON.string(format.iso(edited)))")
            fields.append("\"edited_unixtime\":\(GGChatExportJSON.string("\(edited)"))")
        }
        if item.isService {
            fields.append("\"actor\":\(GGChatExportJSON.string(item.authorName))")
            if let authorId = item.authorId {
                fields.append("\"actor_id\":\(GGChatExportJSON.string(authorId))")
            }
            fields.append("\"action\":\"other\"")
            fields.append(GGChatExportText.jsonFields(text: item.serviceText ?? "", entities: []))
            return "{" + fields.joined(separator: ",") + "}"
        }
        fields.append("\"from\":\(GGChatExportJSON.string(item.authorName))")
        if let authorId = item.authorId {
            fields.append("\"from_id\":\(GGChatExportJSON.string(authorId))")
        }
        if let forwardedFrom = item.forwardedFrom {
            fields.append("\"forwarded_from\":\(GGChatExportJSON.string(forwardedFrom))")
        }
        if let replyToId = item.replyToId {
            fields.append("\"reply_to_message_id\":\(replyToId)")
        }
        if let media = item.media {
            let path = GGChatExportJSON.mediaPath(media, chatDirectory: chatDirectory)
            if media.kind == .photo {
                fields.append("\"photo\":\(GGChatExportJSON.string(path))")
                if let size = media.size {
                    fields.append("\"photo_file_size\":\(size)")
                }
            } else {
                fields.append("\"file\":\(GGChatExportJSON.string(path))")
                if let fileName = media.fileName {
                    fields.append("\"file_name\":\(GGChatExportJSON.string(fileName))")
                }
                if let size = media.size {
                    fields.append("\"file_size\":\(size)")
                }
                if let mediaType = media.kind.jsonMediaType {
                    fields.append("\"media_type\":\(GGChatExportJSON.string(mediaType))")
                }
                if let stickerEmoji = media.stickerEmoji {
                    fields.append("\"sticker_emoji\":\(GGChatExportJSON.string(stickerEmoji))")
                }
                if let mimeType = media.mimeType {
                    fields.append("\"mime_type\":\(GGChatExportJSON.string(mimeType))")
                }
                if let duration = media.duration {
                    fields.append("\"duration_seconds\":\(duration)")
                }
            }
            if let width = media.width, let height = media.height {
                fields.append("\"width\":\(width)")
                fields.append("\"height\":\(height)")
            }
        }
        if let contact = item.contact {
            fields.append("\"contact_information\":{\"first_name\":\(GGChatExportJSON.string(contact.firstName)),\"last_name\":\(GGChatExportJSON.string(contact.lastName)),\"phone_number\":\(GGChatExportJSON.string(contact.phone))}")
        }
        if let location = item.location {
            fields.append("\"location_information\":{\"latitude\":\(location.latitude),\"longitude\":\(location.longitude)}")
            if let title = location.title {
                fields.append("\"place_name\":\(GGChatExportJSON.string(title))")
            }
        }
        if let poll = item.poll {
            let answers = poll.answers.map { answer in
                return "{\"text\":\(GGChatExportJSON.string(answer.text)),\"voters\":\(answer.voters),\"chosen\":\(answer.chosen ? "true" : "false")}"
            }
            fields.append("\"poll\":{\"question\":\(GGChatExportJSON.string(poll.question)),\"closed\":\(poll.isClosed ? "true" : "false"),\"total_voters\":\(poll.totalVoters),\"answers\":[\(answers.joined(separator: ","))]}")
        }
        fields.append(GGChatExportText.jsonFields(text: item.text, entities: item.entities))
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// `{"about":…,"list":[…]}` from prepared objects.
    static func section(about: String, objects: [String]) -> String {
        return "{\"about\":\(GGChatExportJSON.string(about)),\"list\":[" + objects.joined(separator: ",\n") + "]}"
    }

    static func object(_ pairs: [(String, String?)]) -> String {
        var fields: [String] = []
        for (key, value) in pairs {
            if let value = value {
                fields.append("\(GGChatExportJSON.string(key)):\(value)")
            }
        }
        return "{" + fields.joined(separator: ",") + "}"
    }
}
