import Foundation

// The GCONNECT badge table as the server signs it (`GET v1/tg/badges`):
//
//     {"s":"tg","v":<version>,"ts":<unix seconds>,
//      "b":{"<telegram user id>":{"k":"s|d|c","i":"<picture id>","t":0|1,"c":"RRGGBB","x":"<text>"}},
//      "img":{"<picture id>":[width,height]}}
//
// k: s — supporter (ghost), d — GCONNECT team (ghost in a rosette), c — the owner's own picture.
// A picture id is 16 lowercase hex digits: the first half of the picture's sha256.

enum GGNickBadgeKind: UInt8 {
    case supporter = 0
    case team = 1
    case custom = 2
}

/// One row of the table: what is drawn next to a name.
struct GGNickBadge: Equatable {
    let kind: GGNickBadgeKind
    /// `custom` only.
    let imageId: String?
    /// `custom` only: recolour the picture with `colorRGB`.
    let tinted: Bool
    /// 0xRRGGBB picked by the owner in the bot.
    let colorRGB: UInt32
    /// The owner's own line for the bulletin, already cleaned (plain text, one line, ≤ 160).
    let text: String?

    static let defaultColorRGB: UInt32 = 0xFE2C55
}

/// The installed table. Immutable; replaced as a whole.
final class GGNickBadgeTable {
    let version: Int64
    /// Unix seconds the server built it. An older table never replaces a newer one.
    let timestamp: Int64
    let badges: [Int64: GGNickBadge]

    init(version: Int64, timestamp: Int64, badges: [Int64: GGNickBadge]) {
        self.version = version
        self.timestamp = timestamp
        self.badges = badges
    }

    static let empty = GGNickBadgeTable(version: 0, timestamp: 0, badges: [:])
}

enum GGNickBadgeParser {
    static let scope = "tg"
    static let textLimit = 160

    static func isImageId(_ value: String) -> Bool {
        let utf8 = value.utf8
        if utf8.count != 16 {
            return false
        }
        for byte in utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isHexLetter = byte >= 0x61 && byte <= 0x66
            if !isDigit && !isHexLetter {
                return false
            }
        }
        return true
    }

    private static func color(_ value: Any?) -> UInt32? {
        guard let string = value as? String, string.utf8.count == 6 else {
            return nil
        }
        return UInt32(string, radix: 16)
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

    /// The owner's line as it may be shown: no control or direction-override characters (they would
    /// let a line pretend to be someone else's text), no line breaks, at most `textLimit` characters.
    static func cleanText(_ value: Any?) -> String? {
        guard let raw = value as? String else {
            return nil
        }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x09:
                scalars.append(" ")
            case 0x00 ... 0x1F, 0x7F ... 0x9F:
                continue
            case 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return nil
        }
        if text.count > GGNickBadgeParser.textLimit {
            return String(text.prefix(GGNickBadgeParser.textLimit))
        }
        return text
    }

    /// A body whose signature was already checked. Nil when it is not a Telegram table.
    static func parse(_ body: Data) -> GGNickBadgeTable? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        guard (root["s"] as? String) == GGNickBadgeParser.scope, let rows = root["b"] as? [String: Any] else {
            return nil
        }
        let pictures = root["img"] as? [String: Any] ?? [:]
        var badges: [Int64: GGNickBadge] = [:]
        badges.reserveCapacity(rows.count)
        for (key, value) in rows {
            guard let userId = Int64(key), userId > 0, let row = value as? [String: Any] else {
                continue
            }
            var kind: GGNickBadgeKind
            switch row["k"] as? String {
            case "d":
                kind = .team
            case "c":
                kind = .custom
            default:
                kind = .supporter
            }
            var imageId: String?
            var tinted = false
            if kind == .custom {
                // A picture still under review, or one the table does not describe, is drawn as the
                // supporter ghost — exactly what the server itself would show.
                if let id = row["i"] as? String, GGNickBadgeParser.isImageId(id), let size = pictures[id] as? [Any], size.count == 2 {
                    imageId = id
                    tinted = (row["t"] as? NSNumber)?.boolValue ?? false
                } else {
                    kind = .supporter
                }
            }
            badges[userId] = GGNickBadge(
                kind: kind,
                imageId: imageId,
                tinted: tinted,
                colorRGB: GGNickBadgeParser.color(row["c"]) ?? GGNickBadge.defaultColorRGB,
                text: GGNickBadgeParser.cleanText(row["x"])
            )
        }
        return GGNickBadgeTable(
            version: GGNickBadgeParser.int64(root["v"]) ?? 0,
            timestamp: GGNickBadgeParser.int64(root["ts"]) ?? 0,
            badges: badges
        )
    }
}

/// `GET v1/config`: which bot sells the badge and for how much (the local currency when the server
/// knows it). Not signed: it is only shown on the badge screen.
struct GGNickBadgeServerConfig: Equatable {
    struct Price: Equatable {
        let stars: Int?
        let usd: String?
        let local: String?
    }

    let bot: String?
    let standard: Price?
    let custom: Price?

    static func parse(_ data: Data) -> GGNickBadgeServerConfig? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let prices = root["prices"] as? [String: Any] ?? [:]
        let local = root["local"] as? [String: Any] ?? [:]
        let localIsUSD = (local["currency"] as? String ?? "USD") == "USD"

        func price(_ key: String) -> Price? {
            guard let entry = prices[key] as? [String: Any] else {
                return nil
            }
            var usd: String?
            if let string = entry["usd"] as? String {
                usd = string
            } else if let number = entry["usd"] as? NSNumber {
                usd = number.stringValue
            }
            let localText = localIsUSD ? nil : GGNickBadgeParser.cleanText(local[key])
            return Price(stars: (entry["stars"] as? NSNumber)?.intValue, usd: usd, local: localText)
        }

        var bot = (root["bot"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        if let value = bot, value.isEmpty || !GGNickBadgeServerConfig.isUsername(value) {
            bot = nil
        }
        return GGNickBadgeServerConfig(bot: bot, standard: price("standard"), custom: price("custom"))
    }

    /// A Telegram username: 4…32 latin letters, digits and underscores. Anything else from the
    /// server is ignored rather than put into a link.
    static func isUsername(_ value: String) -> Bool {
        let utf8 = value.utf8
        if utf8.count < 4 || utf8.count > 32 {
            return false
        }
        for byte in utf8 {
            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            let isDigit = byte >= 0x30 && byte <= 0x39
            if !isLetter && !isDigit && byte != 0x5F {
                return false
            }
        }
        return true
    }
}
