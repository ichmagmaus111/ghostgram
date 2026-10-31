import Foundation
import GGCore

/// What the notification service hands to the app: it marks the messages in the shared Postbox
/// itself, but the index is the app's job (`GGSharedInbox("antiDelete.index")`). The first byte
/// is the format version.
public struct GGAntiDeleteInboxRecord: Equatable {
    public enum Kind: UInt8 {
        /// Entries for the deleted log.
        case deleted = 0
        /// Entries for the edited log.
        case edited = 1
    }

    private static let formatVersion: UInt8 = 1

    public var account: GGAccountID
    public var kind: Kind
    public var peer: GGPeerKey
    public var entries: [GGAntiDeleteLogEntry]

    public init(account: GGAccountID, kind: Kind, peer: GGPeerKey, entries: [GGAntiDeleteLogEntry]) {
        self.account = account
        self.kind = kind
        self.peer = peer
        self.entries = entries
    }

    public func encode() -> Data {
        var writer = GGBinaryWriter()
        writer.writeUInt8(GGAntiDeleteInboxRecord.formatVersion)
        writer.writeInt64(self.account.rawValue)
        writer.writeUInt8(self.kind.rawValue)
        writer.writeInt32(self.peer.namespace)
        writer.writeInt64(self.peer.id)
        let log = GGAntiDeletePeerLog(entries: self.entries)
        var data = writer.data
        data.append(log.encode())
        return data
    }

    public init?(data: Data) {
        var reader = GGBinaryReader(data)
        guard let version = reader.readUInt8(), version == GGAntiDeleteInboxRecord.formatVersion else {
            return nil
        }
        guard let account = reader.readInt64(), let kindValue = reader.readUInt8(), let kind = Kind(rawValue: kindValue) else {
            return nil
        }
        guard let peerNamespace = reader.readInt32(), let peerId = reader.readInt64(), let peer = GGPeerKey(namespace: peerNamespace, id: peerId) else {
            return nil
        }
        // version (1) + account (8) + kind (1) + peer (12)
        let headerLength = 1 + 8 + 1 + 4 + 8
        if data.count < headerLength {
            return nil
        }
        guard let log = GGAntiDeletePeerLog(data: data.subdata(in: data.startIndex + headerLength ..< data.endIndex)) else {
            return nil
        }
        self.init(account: GGAccountID(rawValue: account), kind: kind, peer: peer, entries: log.entries)
    }
}
