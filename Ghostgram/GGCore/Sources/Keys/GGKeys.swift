import Foundation

// Canonical keys of Ghostgram. One encoding for the whole project: the account, the whole PeerId
// (namespace + id) and the whole MessageId (peer + namespace + id). Conversions to and from the
// TelegramCore types live in GGCore/Bridge/TelegramCore (`AccountRecordId.gg`, `PeerId.ggKey`,
// `MessageId.ggKey`). `PeerId.toInt64()` is never used as a key.

/// An account, by the raw value of its `AccountRecordId`.
public struct GGAccountID: Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Decimal raw value, the form used as a JSON object key.
    public var stringValue: String {
        return String(self.rawValue)
    }

    public init?(string: String) {
        guard let rawValue = GGKeyParsing.int64(string) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public var description: String {
        return "account(\(self.rawValue))"
    }

    public static func <(lhs: GGAccountID, rhs: GGAccountID) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// A whole `PeerId`: namespace (0…7, as in Postbox) and id.
public struct GGPeerKey: Hashable, Comparable, Codable, CustomStringConvertible {
    /// `PeerId.Namespace` holds three bits; anything else would crash in Postbox.
    public static let validNamespaces: ClosedRange<Int32> = 0 ... 7

    public let namespace: Int32
    public let id: Int64

    public init?(namespace: Int32, id: Int64) {
        guard GGPeerKey.validNamespaces.contains(namespace) else {
            return nil
        }
        self.namespace = namespace
        self.id = id
    }

    init(uncheckedNamespace namespace: Int32, id: Int64) {
        self.namespace = namespace
        self.id = id
    }

    /// "0:777000" — namespace, colon, id. Canonical: no signs or leading zeros other than "-".
    public var stringValue: String {
        return "\(self.namespace):\(self.id)"
    }

    public init?(string: String) {
        guard let separator = string.firstIndex(of: ":") else {
            return nil
        }
        guard let namespace = GGKeyParsing.int32(string[string.startIndex ..< separator]) else {
            return nil
        }
        guard let id = GGKeyParsing.int64(string[string.index(after: separator)...]) else {
            return nil
        }
        self.init(namespace: namespace, id: id)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let key = GGPeerKey(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid peer key")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.stringValue)
    }

    public var description: String {
        return self.stringValue
    }

    public static func <(lhs: GGPeerKey, rhs: GGPeerKey) -> Bool {
        if lhs.namespace != rhs.namespace {
            return lhs.namespace < rhs.namespace
        }
        return lhs.id < rhs.id
    }
}

/// A whole `MessageId`: peer, message namespace and id.
public struct GGMessageKey: Hashable, Comparable, Codable, CustomStringConvertible {
    public let peer: GGPeerKey
    public let namespace: Int32
    public let id: Int32

    public init(peer: GGPeerKey, namespace: Int32, id: Int32) {
        self.peer = peer
        self.namespace = namespace
        self.id = id
    }

    /// "0:777000/0:1234" — peer key, slash, message namespace, colon, message id.
    public var stringValue: String {
        return "\(self.peer.stringValue)/\(self.namespace):\(self.id)"
    }

    public init?(string: String) {
        guard let slash = string.firstIndex(of: "/") else {
            return nil
        }
        guard let peer = GGPeerKey(string: String(string[string.startIndex ..< slash])) else {
            return nil
        }
        let message = string[string.index(after: slash)...]
        guard let separator = message.firstIndex(of: ":") else {
            return nil
        }
        guard let namespace = GGKeyParsing.int32(message[message.startIndex ..< separator]) else {
            return nil
        }
        guard let id = GGKeyParsing.int32(message[message.index(after: separator)...]) else {
            return nil
        }
        self.init(peer: peer, namespace: namespace, id: id)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let key = GGMessageKey(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid message key")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.stringValue)
    }

    public var description: String {
        return self.stringValue
    }

    public static func <(lhs: GGMessageKey, rhs: GGMessageKey) -> Bool {
        if lhs.peer != rhs.peer {
            return lhs.peer < rhs.peer
        }
        if lhs.namespace != rhs.namespace {
            return lhs.namespace < rhs.namespace
        }
        return lhs.id < rhs.id
    }
}

/// Strict decimal parsing: the text must be exactly what `String(value)` prints, so every key has
/// one spelling and string equality is key equality.
enum GGKeyParsing {
    static func int64<S: StringProtocol>(_ text: S) -> Int64? {
        guard let value = Int64(text, radix: 10) else {
            return nil
        }
        guard String(value) == String(text) else {
            return nil
        }
        return value
    }

    static func int32<S: StringProtocol>(_ text: S) -> Int32? {
        guard let value = Int32(text, radix: 10) else {
            return nil
        }
        guard String(value) == String(text) else {
            return nil
        }
        return value
    }
}

/// Readers of the key forms the old Ghostgram stored, for migrations only.
public enum GGLegacyKeys {
    /// Decodes an old `PeerId.toInt64()` value. Same bit layout as `PeerId.init(_ n: Int64)` in
    /// `Postbox/Sources/Peer.swift`; the TelegramCore bridge cross-checks it in debug builds.
    public static func peerKey(fromLegacyInt64 value: Int64) -> GGPeerKey {
        let data = UInt64(bitPattern: value)
        let legacyNamespaceBits = (data >> 32) & 0xffffffff
        let idLowBits = data & 0xffffffff

        if legacyNamespaceBits == 0x7fffffff && idLowBits == 0 {
            return GGPeerKey(uncheckedNamespace: 7, id: 0)
        }

        let namespaceBits = (data >> 32) & 0x7
        let offsetIdHighBits = (data >> (32 + 3)) & 0xffffffff
        let idHighBits = offsetIdHighBits << 32

        let id: Int64
        if idHighBits == 0 && namespaceBits == 3 {
            id = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: idLowBits)))
        } else {
            id = Int64(bitPattern: idHighBits | idLowBits)
        }
        return GGPeerKey(uncheckedNamespace: Int32(truncatingIfNeeded: namespaceBits), id: id)
    }

    /// Encodes a key the way `PeerId.toInt64()` does. Nil where Postbox itself would trap
    /// (a negative id that does not fit 32 bits).
    public static func legacyInt64(of key: GGPeerKey) -> Int64? {
        let data: UInt64
        if key.id < 0 {
            guard let int32Value = Int32(exactly: key.id) else {
                return nil
            }
            data = UInt64(UInt32(bitPattern: int32Value))
        } else {
            data = UInt64(bitPattern: key.id)
        }
        let idLowBits = data & 0xffffffff
        let idHighBits = (data >> 32) & 0xffffffff

        var result: UInt64 = 0
        if key.namespace == 7 && key.id == 0 {
            result |= UInt64(0x7fffffff) << 32
            result |= idLowBits
        } else {
            result |= UInt64(UInt32(bitPattern: key.namespace) & 0x7) << 32
            result |= idHighBits << (32 + 3)
            result |= idLowBits
        }
        return Int64(bitPattern: result)
    }

    /// A peer stored by its bare id (`peerId.id._internalGetInt64Value()`) plus a known namespace.
    public static func peerKey(fromRawId id: Int64, namespace: Int32) -> GGPeerKey? {
        return GGPeerKey(namespace: namespace, id: id)
    }

    /// Old "peer_msg" keys: "<PeerId.toInt64()>_<message id>". The message namespace was not
    /// stored; the old code only kept cloud messages, so it defaults to 0 (`Namespaces.Message.Cloud`).
    public static func messageKey(fromLegacyString string: String, messageNamespace: Int32 = 0) -> GGMessageKey? {
        guard let separator = string.lastIndex(of: "_") else {
            return nil
        }
        guard let peerValue = GGKeyParsing.int64(string[string.startIndex ..< separator]) else {
            return nil
        }
        guard let messageId = GGKeyParsing.int32(string[string.index(after: separator)...]) else {
            return nil
        }
        return GGMessageKey(peer: GGLegacyKeys.peerKey(fromLegacyInt64: peerValue), namespace: messageNamespace, id: messageId)
    }
}
