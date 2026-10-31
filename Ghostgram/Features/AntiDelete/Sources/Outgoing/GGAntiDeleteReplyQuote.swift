import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import LocalizedPeerData
import GGCore
import GGHooks
import GGFeaturesShared

/// What a reply to a deleted message quotes (AyuGram's pseudo-reply): the author line and the text
/// the author sent, plain — never a local edit, which only the user sees. Remembered when such a
/// message is drawn, when its menu opens and when a reply to it starts, so the outgoing pipeline
/// never needs Postbox on the send path.
struct GGDeletedQuoteMaterial {
    /// Nil in a one-to-one chat with the author: there is only one person it could be.
    let author: String?
    /// The author to link the line to — a user only (a text mention can not point at a chat).
    let authorUserId: PeerId?
    let text: String
}

/// LRU of quote material for messages kept as deleted, per account.
final class GGDeletedQuoteCache {
    static let shared = GGDeletedQuoteCache()

    private struct Key: Hashable {
        let accountPeerId: PeerId
        let messageId: MessageId
    }

    private let capacity = 512
    private let lock = NSLock()
    private var values: [Key: GGDeletedQuoteMaterial] = [:]
    private var order: [Key] = []

    func material(accountPeerId: PeerId, messageId: MessageId) -> GGDeletedQuoteMaterial? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.values[Key(accountPeerId: accountPeerId, messageId: messageId)]
    }

    func contains(accountPeerId: PeerId, messageId: MessageId) -> Bool {
        return self.material(accountPeerId: accountPeerId, messageId: messageId) != nil
    }

    func set(_ material: GGDeletedQuoteMaterial, accountPeerId: PeerId, messageId: MessageId) {
        let key = Key(accountPeerId: accountPeerId, messageId: messageId)
        self.lock.lock()
        if self.values.updateValue(material, forKey: key) == nil {
            self.order.append(key)
            if self.order.count > self.capacity {
                let removed = self.order.removeFirst()
                self.values.removeValue(forKey: removed)
            }
        }
        self.lock.unlock()
    }
}

enum GGAntiDeleteReplyQuote {
    /// Remembers a message kept as deleted (decorations, menu, reply start). Cheap: strings only.
    static func remember(_ message: Message, context: AccountContext) {
        guard message.ggIsDeleted else {
            return
        }
        if GGDeletedQuoteCache.shared.contains(accountPeerId: context.account.peerId, messageId: message.id) {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let author = message.effectiveAuthor
        // One-to-one with the person being quoted (a secret chat with them too): the name would only
        // repeat what the chat already says.
        var chatUserId = message.id.peerId
        if let secretChat = message.peers[message.id.peerId] as? TelegramSecretChat {
            chatUserId = secretChat.regularPeerId
        }
        var authorTitle: String?
        var authorUserId: PeerId?
        if let author, !(chatUserId.namespace == Namespaces.Peer.CloudUser && author.id == chatUserId) {
            let title = EnginePeer(author).displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            authorTitle = title.isEmpty ? nil : title
            if author is TelegramUser {
                authorUserId = author.id
            }
        }
        // The original text: «Изменить локально» promises the new text is seen by the user only, and
        // this one leaves the device in the outgoing message.
        var text = message.text
        if text.isEmpty, let token = ggAntiDeleteMediaToken(message.media) {
            text = ggAntiDeleteMediaTitle(token)
        }
        GGDeletedQuoteCache.shared.set(GGDeletedQuoteMaterial(author: authorTitle, authorUserId: authorUserId, text: text), accountPeerId: context.account.peerId, messageId: message.id)
    }

    /// `GGChatScreenHooks.replySubject`: the reply target is loaded once off the main thread, so
    /// the quote is ready long before Send (drafts restored after a relaunch included).
    static func warmUp(_ request: GGReplyRequest) {
        let context = request.context
        let messageId = request.messageId
        if GGDeletedQuoteCache.shared.contains(accountPeerId: context.account.peerId, messageId: messageId) {
            return
        }
        let _ = (context.account.postbox.transaction { transaction -> Message? in
            return transaction.getMessage(messageId)
        }
        |> deliverOnMainQueue).start(next: { message in
            if let message {
                GGAntiDeleteReplyQuote.remember(message, context: context)
            }
        })
    }

    private static func spans(_ entities: [MessageTextEntity]) -> [GGQuoteSpan<MessageTextEntityType>] {
        return entities.map { GGQuoteSpan(range: $0.range, kind: .original($0.type)) }
    }

    private static func entities(_ spans: [GGQuoteSpan<MessageTextEntityType>], authorUserId: PeerId?) -> [MessageTextEntity] {
        return spans.compactMap { span in
            switch span.kind {
            case .blockQuote:
                return MessageTextEntity(range: span.range, type: .BlockQuote(isCollapsed: false))
            case .bold:
                return MessageTextEntity(range: span.range, type: .Bold)
            case .authorLink:
                return authorUserId.map { MessageTextEntity(range: span.range, type: .TextMention(peerId: $0)) }
            case let .original(type):
                return MessageTextEntity(range: span.range, type: type)
            }
        }
    }

    /// Stickers, round videos, dice… take no caption: the quote goes as a message before them.
    private static func allowsCaption(_ media: Media) -> Bool {
        if let file = media as? TelegramMediaFile {
            return !(file.isSticker || file.isAnimatedSticker || file.isInstantVideo)
        }
        return media is TelegramMediaImage
    }

    /// `GGOutgoingHooks.messages`, before the other transformers (order −100): a reply to a
    /// message the server deleted is sent as AyuGram's pseudo-reply — an ordinary message with the
    /// quote on top, never as a reply the server would reject. Always on while anti-delete keeps
    /// messages: there is nothing to set up.
    static func transform(_ messages: inout [EnqueueMessage], context: GGOutgoingContext) {
        let accountPeerId = context.account.peerId
        var hasReplyToDeleted = false
        for message in messages {
            if case let .message(_, _, _, _, _, replyToMessageId, _, _, _, _) = message, let reply = replyToMessageId, GGDeletedQuoteCache.shared.contains(accountPeerId: accountPeerId, messageId: reply.messageId) {
                hasReplyToDeleted = true
                break
            }
        }
        if !hasReplyToDeleted {
            return
        }
        var quotedGroups = Set<Int64>()
        var result: [EnqueueMessage] = []
        for message in messages {
            guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message, let reply = replyToMessageId, let material = GGDeletedQuoteCache.shared.material(accountPeerId: accountPeerId, messageId: reply.messageId) else {
                result.append(message)
                continue
            }
            if let localGroupingKey, quotedGroups.contains(localGroupingKey) {
                result.append(message.withUpdatedReplyToMessageId(nil))
                continue
            }
            var messageEntities: [MessageTextEntity] = []
            for attribute in attributes {
                if let attribute = attribute as? TextEntitiesMessageAttribute {
                    messageEntities = attribute.entities
                    break
                }
            }
            let linksAuthor = material.authorUserId != nil
            if let media = mediaReference?.media, !GGAntiDeleteReplyQuote.allowsCaption(media) {
                // A sticker or a round video takes no caption: the quote goes right before it.
                if let built = GGAntiDeleteQuoteBuilder.build(author: material.author, linksAuthor: linksAuthor, quotedText: material.text, messageText: "", messageSpans: [GGQuoteSpan<MessageTextEntityType>](), maximumLength: 4096) {
                    result.append(.message(text: built.text, attributes: [TextEntitiesMessageAttribute(entities: GGAntiDeleteReplyQuote.entities(built.spans, authorUserId: material.authorUserId))], inlineStickers: [:], mediaReference: nil, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                }
                result.append(message.withUpdatedReplyToMessageId(nil))
                continue
            }
            let limit = mediaReference == nil ? 4096 : 1024
            guard let built = GGAntiDeleteQuoteBuilder.build(author: material.author, linksAuthor: linksAuthor, quotedText: material.text, messageText: text, messageSpans: GGAntiDeleteReplyQuote.spans(messageEntities), maximumLength: limit) else {
                // No room for a quote: still never send a reply the server rejects.
                result.append(message.withUpdatedReplyToMessageId(nil))
                continue
            }
            var updatedAttributes = attributes.filter { !($0 is TextEntitiesMessageAttribute) }
            updatedAttributes.append(TextEntitiesMessageAttribute(entities: GGAntiDeleteReplyQuote.entities(built.spans, authorUserId: material.authorUserId)))
            result.append(.message(text: built.text, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: nil, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets))
            if let localGroupingKey {
                quotedGroups.insert(localGroupingKey)
            }
        }
        messages = result
    }
}

/// Localized title of a media token stored with deleted / edited messages.
func ggAntiDeleteMediaTitle(_ token: String) -> String {
    if token.hasPrefix("file:") {
        return String(token.dropFirst("file:".count))
    }
    switch token {
    case "photo":
        return GGStrings.AntiDelete.Media.photo
    case "video":
        return GGStrings.AntiDelete.Media.video
    case "round":
        return GGStrings.AntiDelete.Media.round
    case "voice":
        return GGStrings.AntiDelete.Media.voice
    case "audio":
        return GGStrings.AntiDelete.Media.audio
    case "sticker":
        return GGStrings.AntiDelete.Media.sticker
    case "location":
        return GGStrings.AntiDelete.Media.location
    case "contact":
        return GGStrings.AntiDelete.Media.contact
    case "poll":
        return GGStrings.AntiDelete.Media.poll
    default:
        return GGStrings.AntiDelete.Media.file
    }
}
