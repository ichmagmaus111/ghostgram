import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

/// Translates stored messages of a chat through a translator of plain texts and keeps the result in
/// `TranslationMessageAttribute`, like upstream: the text, a poll's question, options and solution,
/// a voice message's transcription. Rich messages (an InstantPage body) are not touched here.
///
/// Two users: the Google / system providers (GGMessages, `GGTranslationHooks.translateMessages`) and
/// the chat translation without Premium through Telegram's own text translation
/// (`GGMessagesPolicy.translateChatWithoutPremium`).
public enum GGStoredMessagesTranslation {
    public typealias TranslateTexts = ([(String, [MessageTextEntity])]) -> Signal<[(String, [MessageTextEntity])], TranslationError>

    private enum Item {
        case text(MessageId, String, [MessageTextEntity])
        case poll(MessageId, TelegramMediaPoll)
        case transcription(MessageId, String)
    }

    /// `maxTextsPerCall`: the most texts one translator call gets (a poll is never split); nil = all
    /// in one call. Calls go one after another: a burst of parallel requests is what a server limits.
    public static func translate(postbox: Postbox, messageIds: [MessageId], toLang: String, maxTextsPerCall: Int? = nil, translateTexts: @escaping TranslateTexts) -> Signal<Void, TranslationError> {
        return postbox.transaction { transaction -> [Item] in
            var items: [Item] = []
            for id in messageIds {
                guard let message = transaction.getMessage(id) else {
                    continue
                }
                if message.attributes.contains(where: { $0 is RichTextMessageAttribute }) {
                    continue
                }
                if let poll = message.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll {
                    items.append(.poll(id, poll))
                } else if let transcription = message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute, !transcription.text.isEmpty, !transcription.isPending {
                    items.append(.transcription(id, transcription.text))
                } else if !message.text.isEmpty {
                    items.append(.text(id, message.text, message.textEntitiesAttribute?.entities ?? []))
                }
            }
            return items
        }
        |> castError(TranslationError.self)
        |> mapToSignal { items -> Signal<Void, TranslationError> in
            if items.isEmpty {
                return .single(Void())
            }
            var batches: [[Item]] = [[]]
            var batchSize = 0
            for item in items {
                let size = GGStoredMessagesTranslation.texts(of: item).count
                if let maxTextsPerCall, batchSize > 0, batchSize + size > maxTextsPerCall {
                    batches.append([])
                    batchSize = 0
                }
                batches[batches.count - 1].append(item)
                batchSize += size
            }
            var signal: Signal<Void, TranslationError> = .single(Void())
            for batch in batches {
                signal = signal
                |> mapToSignal { _ -> Signal<Void, TranslationError> in
                    return GGStoredMessagesTranslation.translate(batch: batch, postbox: postbox, toLang: toLang, translateTexts: translateTexts)
                }
            }
            return signal
        }
    }

    private static func texts(of item: Item) -> [(String, [MessageTextEntity])] {
        switch item {
        case let .text(_, text, entities):
            return [(text, entities)]
        case let .poll(_, poll):
            var texts: [(String, [MessageTextEntity])] = [(poll.text, poll.textEntities)]
            for option in poll.options {
                texts.append((option.text, option.entities))
            }
            if let solution = poll.results.solution {
                texts.append((solution.text, solution.entities))
            }
            return texts
        case let .transcription(_, text):
            return [(text, [])]
        }
    }

    private static func translate(batch: [Item], postbox: Postbox, toLang: String, translateTexts: @escaping TranslateTexts) -> Signal<Void, TranslationError> {
        var texts: [(String, [MessageTextEntity])] = []
        for item in batch {
            texts.append(contentsOf: GGStoredMessagesTranslation.texts(of: item))
        }
        return translateTexts(texts)
        |> mapToSignal { results -> Signal<Void, TranslationError> in
            return postbox.transaction { transaction -> Void in
                var cursor = 0
                func next() -> (String, [MessageTextEntity]) {
                    let value = cursor < results.count ? results[cursor] : ("", [])
                    cursor += 1
                    return value
                }
                for item in batch {
                    let id: MessageId
                    let attribute: TranslationMessageAttribute?
                    switch item {
                    case let .text(messageId, _, _):
                        id = messageId
                        let value = next()
                        attribute = value.0.isEmpty ? nil : TranslationMessageAttribute(text: value.0, entities: value.1, toLang: toLang)
                    case let .poll(messageId, poll):
                        id = messageId
                        let title = next()
                        var options: [TranslationMessageAttribute.Additional] = []
                        for option in poll.options {
                            let value = next()
                            options.append(TranslationMessageAttribute.Additional(text: value.0.isEmpty ? option.text : value.0, entities: value.0.isEmpty ? option.entities : value.1))
                        }
                        var solution: TranslationMessageAttribute.Additional?
                        if poll.results.solution != nil {
                            let value = next()
                            if !value.0.isEmpty {
                                solution = TranslationMessageAttribute.Additional(text: value.0, entities: value.1)
                            }
                        }
                        attribute = TranslationMessageAttribute(text: title.0.isEmpty ? poll.text : title.0, entities: title.0.isEmpty ? poll.textEntities : title.1, additional: options, pollSolution: solution, toLang: toLang)
                    case let .transcription(messageId, _):
                        id = messageId
                        let value = next()
                        attribute = value.0.isEmpty ? nil : TranslationMessageAttribute(text: value.0, entities: value.1, toLang: toLang)
                    }
                    // An empty answer (a service that returned fewer texts) leaves the message as it
                    // is instead of showing an empty «translation».
                    guard let attribute else {
                        continue
                    }
                    transaction.updateMessage(id, update: { current in
                        let forwardInfo = current.forwardInfo.flatMap(StoreMessageForwardInfo.init)
                        var attributes = current.attributes.filter { !($0 is TranslationMessageAttribute) }
                        attributes.append(attribute)
                        return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: forwardInfo, authorId: current.author?.id, text: current.text, attributes: attributes, media: current.media))
                    })
                }
            }
            |> castError(TranslationError.self)
        }
    }
}
