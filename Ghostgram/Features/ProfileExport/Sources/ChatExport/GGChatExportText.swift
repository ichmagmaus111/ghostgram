import Foundation
import Postbox
import TelegramCore

// Message text with entities, for both formats. Entity ranges are UTF-16 offsets; they may nest
// and overlap, so the text is cut at every entity boundary and each piece is written with the
// entities that cover it (HTML: nested tags; JSON: Telegram Desktop's `text_entities`, one type per
// piece — the outermost one).

struct GGChatExportTextPiece {
    let text: String
    let entities: [MessageTextEntityType]
}

enum GGChatExportText {
    static func pieces(text: String, entities: [MessageTextEntity]) -> [GGChatExportTextPiece] {
        let utf16 = Array(text.utf16)
        if entities.isEmpty || utf16.isEmpty {
            return utf16.isEmpty ? [] : [GGChatExportTextPiece(text: text, entities: [])]
        }
        var bounds = Set<Int>([0, utf16.count])
        var valid: [MessageTextEntity] = []
        for entity in entities {
            let lower = max(0, min(utf16.count, entity.range.lowerBound))
            let upper = max(lower, min(utf16.count, entity.range.upperBound))
            if lower < upper {
                bounds.insert(lower)
                bounds.insert(upper)
                valid.append(MessageTextEntity(range: lower ..< upper, type: entity.type))
            }
        }
        let sorted = bounds.sorted()
        var result: [GGChatExportTextPiece] = []
        for index in 0 ..< sorted.count - 1 {
            let lower = sorted[index]
            let upper = sorted[index + 1]
            let piece = String(decoding: utf16[lower ..< upper], as: UTF16.self)
            let covering = valid.filter { $0.range.lowerBound <= lower && $0.range.upperBound >= upper }.map { $0.type }
            result.append(GGChatExportTextPiece(text: piece, entities: covering))
        }
        return result
    }

    // MARK: - HTML

    static func html(text: String, entities: [MessageTextEntity]) -> String {
        var result = ""
        for piece in GGChatExportText.pieces(text: text, entities: entities) {
            var open = ""
            var close = ""
            for type in piece.entities {
                let tags = GGChatExportText.htmlTags(type, pieceText: piece.text)
                open += tags.open
                close = tags.close + close
            }
            result += open + GGChatExportEscape.htmlMultiline(piece.text) + close
        }
        return result
    }

    private static func htmlTags(_ type: MessageTextEntityType, pieceText: String) -> (open: String, close: String) {
        switch type {
        case .Bold:
            return ("<strong>", "</strong>")
        case .Italic:
            return ("<em>", "</em>")
        case .Underline:
            return ("<u>", "</u>")
        case .Strikethrough:
            return ("<s>", "</s>")
        case .Code:
            return ("<code>", "</code>")
        case .Pre:
            return ("<pre>", "</pre>")
        case .Spoiler:
            return ("<span class=\"spoiler\">", "</span>")
        case .BlockQuote:
            return ("<blockquote>", "</blockquote>")
        case .Url:
            if let link = GGChatExportEscape.safeLink(pieceText) {
                return ("<a href=\"\(GGChatExportEscape.html(link))\">", "</a>")
            }
            return ("", "")
        case let .TextUrl(url):
            if let link = GGChatExportEscape.safeLink(url) {
                return ("<a href=\"\(GGChatExportEscape.html(link))\">", "</a>")
            }
            return ("", "")
        case .Email:
            return ("<a href=\"mailto:\(GGChatExportEscape.html(pieceText))\">", "</a>")
        case .PhoneNumber:
            return ("<a href=\"tel:\(GGChatExportEscape.html(pieceText))\">", "</a>")
        case .Mention:
            let username = pieceText.hasPrefix("@") ? String(pieceText.dropFirst()) : pieceText
            if let encoded = username.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                return ("<a href=\"https://t.me/\(encoded)\">", "</a>")
            }
            return ("", "")
        case .Hashtag, .BotCommand, .BankCard, .TonAddress, .TextMention, .CustomEmoji, .FormattedDate, .Custom, .Unknown:
            return ("<span class=\"entity\">", "</span>")
        }
    }

    // MARK: - JSON

    /// Telegram Desktop's type name of an entity.
    static func jsonType(_ type: MessageTextEntityType) -> String {
        switch type {
        case .Unknown, .Custom, .FormattedDate:
            return "unknown"
        case .Mention:
            return "mention"
        case .Hashtag:
            return "hashtag"
        case .BotCommand:
            return "bot_command"
        case .Url:
            return "link"
        case .Email:
            return "email"
        case .Bold:
            return "bold"
        case .Italic:
            return "italic"
        case .Code:
            return "code"
        case .Pre:
            return "pre"
        case .TextUrl:
            return "text_link"
        case .TextMention:
            return "mention_name"
        case .PhoneNumber:
            return "phone"
        case .Strikethrough:
            return "strikethrough"
        case .BlockQuote:
            return "blockquote"
        case .Underline:
            return "underline"
        case .BankCard:
            return "bank_card"
        case .TonAddress:
            return "unknown"
        case .Spoiler:
            return "spoiler"
        case .CustomEmoji:
            return "custom_emoji"
        }
    }

    /// One `text_entities` object for a piece.
    private static func jsonEntity(_ piece: GGChatExportTextPiece) -> String {
        guard let type = piece.entities.first else {
            return "{\"type\":\"plain\",\"text\":\(GGChatExportEscape.json(piece.text))}"
        }
        var fields = "\"type\":\(GGChatExportEscape.json(GGChatExportText.jsonType(type))),\"text\":\(GGChatExportEscape.json(piece.text))"
        switch type {
        case let .TextUrl(url):
            fields += ",\"href\":\(GGChatExportEscape.json(url))"
        case let .TextMention(peerId):
            fields += ",\"user_id\":\(peerId.id._internalGetInt64Value())"
        case let .CustomEmoji(_, fileId):
            fields += ",\"document_id\":\(GGChatExportEscape.json("\(fileId)"))"
        case let .Pre(language):
            fields += ",\"language\":\(GGChatExportEscape.json(language ?? ""))"
        case let .BlockQuote(isCollapsed):
            fields += ",\"collapsed\":\(isCollapsed ? "true" : "false")"
        default:
            break
        }
        return "{" + fields + "}"
    }

    /// `"text"` and `"text_entities"` fields (without the surrounding braces).
    static func jsonFields(text: String, entities: [MessageTextEntity]) -> String {
        let pieces = GGChatExportText.pieces(text: text, entities: entities)
        var textValue: String
        if pieces.allSatisfy({ $0.entities.isEmpty }) {
            textValue = GGChatExportEscape.json(text)
        } else {
            var parts: [String] = []
            for piece in pieces {
                if piece.entities.isEmpty {
                    parts.append(GGChatExportEscape.json(piece.text))
                } else {
                    parts.append(GGChatExportText.jsonEntity(piece))
                }
            }
            textValue = "[" + parts.joined(separator: ",") + "]"
        }
        if pieces.isEmpty {
            textValue = "\"\""
        }
        let entitiesValue = "[" + pieces.map(GGChatExportText.jsonEntity).joined(separator: ",") + "]"
        return "\"text\":\(textValue),\"text_entities\":\(entitiesValue)"
    }
}
