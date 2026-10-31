import Foundation

// «Ответ на удалённое», as AyuGram does it (owner, 2026-10-27). The server no longer has the
// message, so a reply to it can not be sent as a reply (the server rejects an unknown reply id).
// The reply becomes an ordinary message with a block quote on top:
//
//     ┌ **Author**        ← bold, linked to the author; only where it says something new
//     │ the quoted text, ≤ 100 characters, «…» past that
//     └
//     what the user typed
//
// The author line is left out in a one-to-one chat with that same author: there is only one
// person it could be. The quoted text goes plain, as in AyuGram. Pure: ranges are UTF-16 offsets
// as in `MessageTextEntity`, the payload type is the caller's.

public enum GGQuoteSpanKind<Payload> {
    case blockQuote
    case bold
    /// A link to the quoted message's author (the caller makes it a text mention).
    case authorLink
    /// A formatting span of the message text, moved to its new place.
    case original(Payload)
}

public struct GGQuoteSpan<Payload> {
    public var range: Range<Int>
    public var kind: GGQuoteSpanKind<Payload>

    public init(range: Range<Int>, kind: GGQuoteSpanKind<Payload>) {
        self.range = range
        self.kind = kind
    }
}

public struct GGQuoteResult<Payload> {
    public var text: String
    public var spans: [GGQuoteSpan<Payload>]
}

public enum GGAntiDeleteQuoteBuilder {
    /// Longest quoted text (AyuGram's limit); longer texts are cut at a character boundary and get «…».
    public static let maximumQuoteLength = 100

    /// - Parameters:
    ///   - author: the author line, or nil when it is left out (a one-to-one chat with the author).
    ///   - linksAuthor: the author line also links to the author (a user the account can mention).
    ///   - quotedText: the deleted message's text (a media title for media without text).
    ///   - messageText / messageSpans: what the user is sending (may be empty: a media reply).
    ///   - maximumLength: the limit of the outgoing text (4096 for text, the caption limit for media).
    /// - Returns: nil when there is nothing to quote or no room for it (the caller sends without
    ///   the reply).
    public static func build<Payload>(author: String?, linksAuthor: Bool, quotedText: String, messageText: String, messageSpans: [GGQuoteSpan<Payload>], maximumLength: Int) -> GGQuoteResult<Payload>? {
        if quotedText.isEmpty {
            return nil
        }
        let header = author ?? ""
        let headerLength = (header as NSString).length
        let messageLength = (messageText as NSString).length
        // [header + "\n"] + quote [+ "\n" + message]
        let separatorLength = messageText.isEmpty ? 0 : 1
        let headerPartLength = headerLength == 0 ? 0 : headerLength + 1
        let budget = maximumLength - messageLength - separatorLength - headerPartLength
        if budget < 2 {
            return nil
        }

        var quote = quotedText
        let quoteLimit = min(budget, GGAntiDeleteQuoteBuilder.maximumQuoteLength)
        if (quote as NSString).length > quoteLimit {
            quote = GGAntiDeleteQuoteBuilder.prefix(of: quote, utf16Limit: quoteLimit - 1) + "…"
        }

        var text = ""
        var spans: [GGQuoteSpan<Payload>] = []
        if headerLength != 0 {
            text = header + "\n"
            spans.append(GGQuoteSpan(range: 0 ..< headerLength, kind: .bold))
            if linksAuthor {
                spans.append(GGQuoteSpan(range: 0 ..< headerLength, kind: .authorLink))
            }
        }
        text += quote
        let quoteEnd = (text as NSString).length
        spans.insert(GGQuoteSpan(range: 0 ..< quoteEnd, kind: .blockQuote), at: 0)

        if !messageText.isEmpty {
            text += "\n"
            let messageStart = (text as NSString).length
            text += messageText
            for span in messageSpans {
                spans.append(GGQuoteSpan(range: (span.range.lowerBound + messageStart) ..< (span.range.upperBound + messageStart), kind: span.kind))
            }
        }
        return GGQuoteResult(text: text, spans: spans)
    }

    /// The longest prefix of whole characters whose UTF-16 length fits.
    static func prefix(of string: String, utf16Limit: Int) -> String {
        var result = ""
        var length = 0
        for character in string {
            let characterLength = String(character).utf16.count
            if length + characterLength > utf16Limit {
                break
            }
            result.append(character)
            length += characterLength
        }
        return result
    }
}
