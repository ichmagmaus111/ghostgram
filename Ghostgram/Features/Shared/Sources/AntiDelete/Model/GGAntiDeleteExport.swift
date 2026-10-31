import Foundation
import GGCore

// Export / import of the histories, in the same spirit as the settings file of GGCore: a JSON
// object with a format name and a version, canonical keys (`GGMessageKey.stringValue`), the
// account it came from. Secret chats are never exported (the file is plain text). An import only
// adds archive entries: it never marks a live message as deleted.

public struct GGAntiDeleteExportFile: Codable, Equatable {
    public static let formatName = "ghostgram.antiDelete"
    public static let currentVersion = 1

    public struct Deleted: Codable, Equatable {
        public var message: GGMessageKey
        public var thread: Int64?
        public var date: Int32
        public var deletedAt: Int32
        public var author: String?
        public var username: String?
        public var text: String
        public var media: String?

        public init(message: GGMessageKey, thread: Int64?, date: Int32, deletedAt: Int32, author: String?, username: String?, text: String, media: String?) {
            self.message = message
            self.thread = thread
            self.date = date
            self.deletedAt = deletedAt
            self.author = author
            self.username = username
            self.text = text
            self.media = media
        }
    }

    public struct Version: Codable, Equatable {
        public var text: String
        public var date: Int32

        public init(text: String, date: Int32) {
            self.text = text
            self.date = date
        }
    }

    public struct Edited: Codable, Equatable {
        public var message: GGMessageKey
        public var thread: Int64?
        public var author: String?
        public var current: String
        public var versions: [Version]

        public init(message: GGMessageKey, thread: Int64?, author: String?, current: String, versions: [Version]) {
            self.message = message
            self.thread = thread
            self.author = author
            self.current = current
            self.versions = versions
        }
    }

    public var format: String
    public var version: Int
    public var account: GGAccountID?
    public var exportedAt: Int32
    public var deleted: [Deleted]
    public var edited: [Edited]

    public init(account: GGAccountID?, exportedAt: Int32, deleted: [Deleted], edited: [Edited]) {
        self.format = GGAntiDeleteExportFile.formatName
        self.version = GGAntiDeleteExportFile.currentVersion
        self.account = account
        self.exportedAt = exportedAt
        self.deleted = deleted
        self.edited = edited
    }

    /// Secret chats are dropped here, whatever the caller collected.
    public func encode() -> Data? {
        var copy = self
        copy.deleted = copy.deleted.filter { !GGAntiDeleteExportFile.isSecretChat($0.message.peer) }
        copy.edited = copy.edited.filter { !GGAntiDeleteExportFile.isSecretChat($0.message.peer) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(copy)
    }

    public enum ImportError: Error, Equatable {
        case invalidFormat
        case unsupportedVersion(Int)
    }

    public static func decode(_ data: Data) -> Result<GGAntiDeleteExportFile, ImportError> {
        guard let file = try? JSONDecoder().decode(GGAntiDeleteExportFile.self, from: data), file.format == GGAntiDeleteExportFile.formatName else {
            return .failure(.invalidFormat)
        }
        if file.version > GGAntiDeleteExportFile.currentVersion {
            return .failure(.unsupportedVersion(file.version))
        }
        var result = file
        result.deleted = result.deleted.filter { !GGAntiDeleteExportFile.isSecretChat($0.message.peer) }
        result.edited = result.edited.filter { !GGAntiDeleteExportFile.isSecretChat($0.message.peer) }
        return .success(result)
    }

    /// `Namespaces.Peer.SecretChat` (TelegramCore) is 3; the model does not link TelegramCore.
    public static func isSecretChat(_ peer: GGPeerKey) -> Bool {
        return peer.namespace == 3
    }
}
