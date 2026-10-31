import Foundation
import Postbox
import TelegramCore
import GGCore

// HTML of the export. Own templates and stylesheet (no Telegram Desktop assets), with Telegram
// Desktop's page structure and class names: pages of up to 1000 messages linked to each other,
// joined messages of one author, day separators, media blocks. Every value is escaped; only http(s),
// tg, mailto and tel links are kept.

enum GGChatExportHTML {
    static let pageSize = 1000

    static func pageFileName(_ number: Int) -> String {
        return number <= 1 ? "messages.html" : "messages\(number).html"
    }

    static func document(title: String, body: String, assetPrefix: String) -> String {
        var html = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\"/>\n<title>"
        html += GGChatExportEscape.html(title)
        html += "</title>\n<meta content=\"width=device-width, initial-scale=1.0\" name=\"viewport\"/>\n<link href=\""
        html += assetPrefix
        html += "css/style.css\" rel=\"stylesheet\"/>\n</head>\n<body>\n<div class=\"page_wrap\">\n<div class=\"page_header\"><div class=\"content\"><div class=\"text bold\">"
        html += GGChatExportEscape.html(title)
        html += "</div></div></div>\n<div class=\"page_body\">\n"
        html += body
        html += "\n</div>\n</div>\n</body>\n</html>\n"
        return html
    }

    /// One page of a chat. `previous` is the last message of the previous page (joining, days).
    static func messagesPage(chatTitle: String, items: [GGChatExportItem], previous: GGChatExportItem?, pageNumber: Int, hasNext: Bool, assetPrefix: String, format: GGChatExportFormat) -> String {
        var body = "<div class=\"history\">\n"
        if pageNumber > 1 {
            body += "<a class=\"pagination block_link\" href=\"\(GGChatExportHTML.pageFileName(pageNumber - 1))\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.previous))</a>\n"
        }
        var last = previous
        for item in items {
            if last == nil || !format.sameDay(last!.timestamp, item.timestamp) {
                body += "<div class=\"message service\"><div class=\"body details\">\(GGChatExportEscape.html(format.day(item.timestamp)))</div></div>\n"
                last = nil
            }
            body += GGChatExportHTML.message(item, previous: last, format: format)
            last = item
        }
        if hasNext {
            body += "<a class=\"pagination block_link\" href=\"\(GGChatExportHTML.pageFileName(pageNumber + 1))\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.next))</a>\n"
        }
        body += "</div>"
        return GGChatExportHTML.document(title: chatTitle, body: body, assetPrefix: assetPrefix)
    }

    private static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        var result = ""
        for word in words {
            if let first = word.first {
                result.append(first)
            }
        }
        return result.uppercased()
    }

    private static func userpicClass(_ peerId: PeerId?) -> Int {
        guard let peerId = peerId else {
            return 1
        }
        let raw = peerId.id._internalGetInt64Value()
        return Int((raw % 7 + 7) % 7) + 1
    }

    private static func message(_ item: GGChatExportItem, previous: GGChatExportItem?, format: GGChatExportFormat) -> String {
        let id = item.index.id.id
        if item.isService {
            return "<div class=\"message service\" id=\"message\(id)\"><div class=\"body details\">\(GGChatExportEscape.htmlMultiline(item.serviceText ?? ""))</div></div>\n"
        }
        var joined = false
        if let previous = previous, !previous.isService, previous.authorKey == item.authorKey, item.forwardedFrom == nil, item.timestamp - previous.timestamp < 900 {
            joined = true
        }
        var html = "<div class=\"message default clearfix\(joined ? " joined" : "")\" id=\"message\(id)\">\n"
        if !joined {
            html += "<div class=\"pull_left userpic_wrap\"><div class=\"userpic userpic\(GGChatExportHTML.userpicClass(item.authorKey))\"><div class=\"initials\">\(GGChatExportEscape.html(GGChatExportHTML.initials(item.authorName)))</div></div></div>\n"
        }
        html += "<div class=\"body\">\n"
        var dateTitle = format.full(item.timestamp)
        if let edited = item.editedTimestamp {
            dateTitle += "\n" + GGStrings.ChatExport.Output.edited(date: format.full(edited))
        }
        html += "<div class=\"pull_right date details\" title=\"\(GGChatExportEscape.html(dateTitle))\">\(GGChatExportEscape.html(format.time(item.timestamp)))</div>\n"
        if !joined {
            html += "<div class=\"from_name\">\(GGChatExportEscape.html(item.authorName))</div>\n"
        }
        if let forwardedFrom = item.forwardedFrom {
            html += "<div class=\"forwarded details\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.forwarded(name: forwardedFrom)))</div>\n"
        }
        if let replyToId = item.replyToId {
            html += "<div class=\"reply_to details\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.inReplyTo)) <a href=\"#message\(replyToId)\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.thisMessage))</a></div>\n"
        }
        if let media = item.media {
            html += "<div class=\"media_wrap clearfix\">\(GGChatExportHTML.media(media, format: format))</div>\n"
        }
        if let contact = item.contact {
            let name = [contact.firstName, contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            html += GGChatExportHTML.mediaCard(cssClass: "media_contact", title: name.isEmpty ? GGStrings.ChatExport.Output.contact : name, description: contact.phone, status: nil, link: nil)
        }
        if let location = item.location {
            let link = String(format: "https://maps.apple.com/?ll=%.6f,%.6f", location.latitude, location.longitude)
            html += GGChatExportHTML.mediaCard(cssClass: "media_location", title: location.title ?? GGStrings.ChatExport.Output.location, description: String(format: "%.6f, %.6f", location.latitude, location.longitude), status: nil, link: link)
        }
        if let poll = item.poll {
            html += "<div class=\"media_poll\"><div class=\"question bold\">\(GGChatExportEscape.html(poll.question))</div>"
            if poll.isClosed {
                html += "<div class=\"details\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.pollClosed))</div>"
            }
            for answer in poll.answers {
                html += "<div class=\"answer\">\(answer.chosen ? "✓ " : "")\(GGChatExportEscape.html(answer.text)) <span class=\"details\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.votes(count: answer.voters)))</span></div>"
            }
            html += "<div class=\"total details\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.votes(count: poll.totalVoters)))</div></div>\n"
        }
        if !item.text.isEmpty {
            html += "<div class=\"text\">\(GGChatExportText.html(text: item.text, entities: item.entities))</div>\n"
        }
        html += "</div>\n</div>\n"
        return html
    }

    private static func mediaCard(cssClass: String, title: String, description: String?, status: String?, link: String?) -> String {
        var inner = "<div class=\"fill pull_left\"></div><div class=\"body\"><div class=\"title bold\">\(GGChatExportEscape.html(title))</div>"
        if let description = description {
            inner += "<div class=\"description\">\(GGChatExportEscape.html(description))</div>"
        }
        if let status = status {
            inner += "<div class=\"status details\">\(GGChatExportEscape.html(status))</div>"
        }
        inner += "</div>"
        if let link = link {
            return "<a class=\"media clearfix pull_left block_link \(cssClass)\" href=\"\(GGChatExportEscape.html(link))\">\(inner)</a>\n"
        }
        return "<div class=\"media clearfix pull_left \(cssClass)\">\(inner)</div>\n"
    }

    private static func mediaTitle(_ media: GGChatExportMedia) -> String {
        switch media.kind {
        case .photo:
            return GGStrings.ChatExport.Output.photo
        case .video:
            return GGStrings.ChatExport.Output.video
        case .gif:
            return GGStrings.ChatExport.Output.gif
        case .videoMessage:
            return GGStrings.ChatExport.Output.videoMessage
        case .voiceMessage:
            return GGStrings.ChatExport.Output.voiceMessage
        case .sticker:
            return media.stickerEmoji.map { GGStrings.ChatExport.Output.sticker + " " + $0 } ?? GGStrings.ChatExport.Output.sticker
        case .audio, .file:
            return media.fileName ?? GGStrings.ChatExport.Output.file
        }
    }

    private static func mediaClass(_ kind: GGChatExportMediaKind) -> String {
        switch kind {
        case .photo, .sticker:
            return "media_photo"
        case .video, .gif, .videoMessage:
            return "media_video"
        case .voiceMessage:
            return "media_voice_message"
        case .audio:
            return "media_audio_file"
        case .file:
            return "media_file"
        }
    }

    private static func media(_ media: GGChatExportMedia, format: GGChatExportFormat) -> String {
        var status: [String] = []
        if let duration = media.duration {
            status.append(GGChatExportFormat.duration(duration))
        }
        if let size = media.size {
            status.append(GGChatExportFormat.fileSize(size))
        }
        let statusText = status.isEmpty ? nil : status.joined(separator: ", ")
        switch media.state {
        case let .saved(path):
            let escapedPath = GGChatExportEscape.html(path)
            if media.kind == .photo {
                var width = Double(media.width ?? 260)
                var height = Double(media.height ?? 260)
                let scale = min(1.0, min(260.0 / max(1.0, width), 260.0 / max(1.0, height)))
                width = floor(width * scale)
                height = floor(height * scale)
                return "<a class=\"photo_wrap clearfix pull_left\" href=\"\(escapedPath)\"><img class=\"photo\" src=\"\(escapedPath)\" style=\"width: \(Int(width))px; height: \(Int(height))px\"/></a>\n"
            }
            if media.kind == .sticker, (media.targetName as NSString).pathExtension.lowercased() == "webp" {
                return "<a class=\"sticker_wrap clearfix pull_left\" href=\"\(escapedPath)\"><img class=\"sticker\" src=\"\(escapedPath)\" style=\"width: 128px; height: 128px\"/></a>\n"
            }
            return GGChatExportHTML.mediaCard(cssClass: GGChatExportHTML.mediaClass(media.kind), title: GGChatExportHTML.mediaTitle(media), description: nil, status: statusText, link: path)
        case .notIncluded:
            return GGChatExportHTML.mediaCard(cssClass: GGChatExportHTML.mediaClass(media.kind), title: GGChatExportHTML.mediaTitle(media), description: GGStrings.ChatExport.Output.notIncluded, status: statusText, link: nil)
        case .tooLarge:
            return GGChatExportHTML.mediaCard(cssClass: GGChatExportHTML.mediaClass(media.kind), title: GGChatExportHTML.mediaTitle(media), description: GGStrings.ChatExport.Output.tooLarge, status: statusText, link: nil)
        case .unavailable, .pending:
            return GGChatExportHTML.mediaCard(cssClass: GGChatExportHTML.mediaClass(media.kind), title: GGChatExportHTML.mediaTitle(media), description: GGStrings.ChatExport.Output.unavailable, status: statusText, link: nil)
        }
    }

    // MARK: - Lists (account export)

    /// A page with one block per row: a bold title and «label: value» lines.
    static func listPage(title: String, rows: [(title: String, lines: [(String, String)])], assetPrefix: String) -> String {
        var body = "<div class=\"page_list\">\n"
        if rows.isEmpty {
            body += "<div class=\"entry details\">\(GGChatExportEscape.html(GGStrings.ChatExport.Output.empty))</div>\n"
        }
        for row in rows {
            body += "<div class=\"entry\"><div class=\"name bold\">\(GGChatExportEscape.html(row.title))</div>"
            for (label, value) in row.lines where !value.isEmpty {
                body += "<div class=\"details_entry details\">\(GGChatExportEscape.html(label)): \(GGChatExportEscape.html(value))</div>"
            }
            body += "</div>\n"
        }
        body += "</div>"
        return GGChatExportHTML.document(title: title, body: body, assetPrefix: assetPrefix)
    }

    /// A page of links (the index of an account export, the list of chats).
    static func linksPage(title: String, header: [(String, String)], links: [(title: String, subtitle: String?, href: String)], assetPrefix: String) -> String {
        var body = ""
        if !header.isEmpty {
            body += "<div class=\"personal_info\">"
            for (label, value) in header where !value.isEmpty {
                body += "<div class=\"details_entry\"><span class=\"details\">\(GGChatExportEscape.html(label)):</span> \(GGChatExportEscape.html(value))</div>"
            }
            body += "</div>\n"
        }
        body += "<div class=\"page_list\">\n"
        for link in links {
            body += "<a class=\"entry block_link\" href=\"\(GGChatExportEscape.html(link.href))\"><div class=\"name bold\">\(GGChatExportEscape.html(link.title))</div>"
            if let subtitle = link.subtitle {
                body += "<div class=\"details\">\(GGChatExportEscape.html(subtitle))</div>"
            }
            body += "</a>\n"
        }
        body += "</div>"
        return GGChatExportHTML.document(title: title, body: body, assetPrefix: assetPrefix)
    }

    /// The stylesheet of the tree (`css/style.css`), written once per export.
    static let stylesheet = """
    body { margin: 0; font: 13px/18px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #fff; color: #000; }
    a { color: #168acd; text-decoration: none; }
    .page_wrap { max-width: 720px; margin: 0 auto; }
    .page_header { position: sticky; top: 0; background: #fff; border-bottom: 1px solid #e3e6e8; padding: 12px 16px; z-index: 1; }
    .bold { font-weight: 700; }
    .details { color: #70777b; }
    .history, .page_list, .personal_info { padding: 8px 16px 24px; }
    .clearfix:after { content: ""; display: table; clear: both; }
    .pull_left { float: left; }
    .pull_right { float: right; }
    .message { padding: 6px 0; }
    .message.joined { padding-top: 0; }
    .message.service { text-align: center; padding: 10px 0; }
    .message.service .body { display: inline-block; background: #f1f3f4; border-radius: 12px; padding: 4px 12px; }
    .userpic_wrap { margin-right: 10px; }
    .userpic { width: 42px; height: 42px; border-radius: 50%; color: #fff; text-align: center; }
    .userpic .initials { line-height: 42px; font-weight: 700; }
    .message .body { margin-left: 52px; }
    .message.service .body { margin-left: 0; }
    .userpic1 { background: #ff5555; } .userpic2 { background: #64bf47; } .userpic3 { background: #ffab00; }
    .userpic4 { background: #4f9cd9; } .userpic5 { background: #9884e8; } .userpic6 { background: #e671a5; }
    .userpic7 { background: #47bcd1; }
    .from_name { color: #3892db; font-weight: 700; padding-bottom: 2px; }
    .forwarded, .reply_to { padding-bottom: 2px; }
    .text { word-wrap: break-word; white-space: normal; }
    .text pre, .text code { font-family: Menlo, Consolas, monospace; background: #f5f5f5; border-radius: 4px; }
    .text pre { padding: 6px; white-space: pre-wrap; }
    .text blockquote { margin: 4px 0; padding-left: 8px; border-left: 3px solid #3892db; }
    .spoiler { background: #70777b; color: transparent; border-radius: 3px; }
    .spoiler:hover { background: transparent; color: inherit; }
    .media_wrap { padding: 4px 0; }
    .photo { border-radius: 8px; display: block; }
    .media { display: block; margin: 4px 0; }
    .media .fill { width: 40px; height: 40px; border-radius: 50%; background: #3892db; margin-right: 10px; }
    .media .body { margin-left: 50px; }
    .media_poll { padding: 4px 0; }
    .media_poll .answer { padding: 2px 0; }
    .pagination { display: block; text-align: center; padding: 10px; }
    .entry { display: block; padding: 8px 0; border-bottom: 1px solid #f1f3f4; color: inherit; }
    @media (prefers-color-scheme: dark) {
      body, .page_header { background: #17212b; color: #f5f5f5; }
      .page_header, .entry { border-color: #0e1621; }
      .message.service .body, .text pre, .text code { background: #202b36; }
      .details { color: #8a9aab; }
    }
    """
}
