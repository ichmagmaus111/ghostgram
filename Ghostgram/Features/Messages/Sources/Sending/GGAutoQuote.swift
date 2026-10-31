import Foundation
import Postbox
import TelegramCore
import AccountContext
import GGHooks
import GGCore
import GGFeaturesShared

/// «Отвечать цитатой» (+ «Кроме комментариев»): the default quote of a new reply — the message
/// text, cut to the server's quote limit, with its entities. It does not replace the reply setup;
/// it answers one question at the place where the reply subject is built, so the reply to a deleted
/// message (W2-2) and the quote never overwrite each other.
///
/// `GGChatScreenHooks.replySubject` transforms only the inner subject (to-do item, poll option);
/// the quote comes from `GGChatScreenHooks.replyQuote`.
enum GGAutoQuote {
    static let defaultMaximumLength = 1024

    static func register() {
        GGChatScreenHooks.replyQuote.register({ message, request in
            return GGAutoQuote.quote(message: message, context: request.context, chatLocation: request.chatLocation)
        })
    }

    static func quote(message: Message, context: AccountContext, chatLocation: ChatLocation) -> EngineMessageReplyQuote? {
        guard GGMessagesSettings.autoQuoteReply.value else {
            return nil
        }
        if GGMessagesSettings.autoQuoteSkipComments.value, case let .replyThread(replyThreadMessage) = chatLocation, replyThreadMessage.isChannelPost {
            return nil
        }
        let text = message.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        var maximumLength = GGAutoQuote.defaultMaximumLength
        if let data = context.currentAppConfiguration.with({ $0 }).data, let value = data["quote_length_max"] as? Double {
            maximumLength = max(1, Int(value))
        }
        let length = (text as NSString).length
        var quoteText = text
        var quoteLength = length
        if length > maximumLength {
            // Never cut a surrogate pair.
            let range = (text as NSString).rangeOfComposedCharacterSequence(at: maximumLength - 1)
            quoteLength = range.location
            quoteText = (text as NSString).substring(to: quoteLength)
        }
        // Only what a quote can carry (bold, italic, spoiler, custom emoji…), computed the way the
        // send path checks a quote against its message: a link, mention, hashtag or code entity in
        // the quote would make that check fail («Цитата устарела») and the message would not go.
        let entities = messageTextEntitiesInRange(entities: message.textEntitiesAttribute?.entities ?? [], range: NSRange(location: 0, length: quoteLength), onlyQuoteable: true)
        if quoteText.isEmpty {
            return nil
        }
        return EngineMessageReplyQuote(text: quoteText, offset: nil, entities: entities, media: nil)
    }
}
