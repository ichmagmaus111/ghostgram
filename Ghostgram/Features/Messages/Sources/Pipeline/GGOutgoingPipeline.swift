import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGFeaturesShared

extension GGTextReplacementRule: GGSettingValue {}

/// The one outgoing text pipeline: `GGOutgoingHooks.textStages` runs the three stages of
/// `GGTextPipeline` in their fixed order over text + entities (formatting and custom emoji move
/// with the text). It covers every `.message` that goes through `enqueueMessages`: the composer,
/// bot buttons, captions, inline results, plugins of the future. Copies (forward fallback) carry
/// `GGOutgoingVerbatimAttribute` and are skipped; rich messages (an InstantPage body) are skipped
/// because their text is derived from the page. Edits of sent messages are not transformed.
enum GGOutgoingPipeline {
    /// Global: the user's own dictionary.
    static let replacementRules = GGSetting<[GGTextReplacementRule]>("sending.wordReplacementRules", default: [])

    static func register() {
        GGOutgoingHooks.textStages.register({ text, context in
            GGOutgoingPipeline.transform(&text, context: context)
        }, order: 100)
        GGChatScreenHooks.lifecycle.register({ event, screen in
            if case .willAppear = event {
                GGBotPeerCache.shared.noteChat(screen.chatLocation, context: screen.context)
            }
        })
        // A reply with a bot keyboard button's text: the bot expects it exactly (in a group the
        // bot can not be told from the chat, so the button itself marks the message).
        GGChatScreenHooks.botButtonReplyAttributes.register({
            return [GGOutgoingVerbatimAttribute()]
        })
    }

    static func configuration(accountId: GGAccountID) -> GGTextPipelineConfiguration {
        var configuration = GGTextPipelineConfiguration()
        if GGMessagesSettings.wordReplacement.value {
            configuration.replacementRules = GGOutgoingPipeline.replacementRules.value
        }
        configuration.antiCaps = GGMessagesSettings.antiCaps.value
        if GGMessagesSettings.hyperlinkSpoof.value {
            configuration.hyperlink = GGMessagesSettings.hyperlinkTarget.value(for: accountId) != nil
        }
        return configuration
    }

    static func transform(_ text: inout GGOutgoingText, context: GGOutgoingTextContext) {
        let accountId = context.account.id.gg
        let configuration = GGOutgoingPipeline.configuration(accountId: accountId)
        if configuration.isEmpty {
            return
        }
        let attributes = context.message.attributes
        if GGOutgoingVerbatimAttribute.isPresent(in: attributes) {
            return
        }
        if attributes.contains(where: { $0 is RichTextMessageAttribute }) {
            return
        }
        let pipelineContext = GGTextPipelineContext(
            isBot: GGBotPeerCache.shared.isBot(context.peerId, accountPeerId: context.account.peerId),
            isSavedMessages: context.peerId == context.account.peerId,
            isVerbatim: false
        )
        let target = GGMessagesSettings.hyperlinkTarget.value(for: accountId)
        let result = GGOutgoingPipeline.run(text, configuration: configuration, context: pipelineContext, hyperlinkTarget: target.map { PeerId(ggKey: $0) })
        if result != text {
            text = result
        }
    }

    /// Also used by the preview of the «Отправка» tab.
    static func run(_ text: GGOutgoingText, configuration: GGTextPipelineConfiguration, context: GGTextPipelineContext, hyperlinkTarget: PeerId?) -> GGOutgoingText {
        var configuration = configuration
        if hyperlinkTarget == nil {
            configuration.hyperlink = false
        }
        let input = GGPipelineText(text: text.text, entities: text.entities.enumerated().map { index, entity in
            return GGPipelineEntity(range: entity.range, isProtected: GGOutgoingPipeline.isProtected(entity.type), excludesOverlay: GGOutgoingPipeline.excludesOverlay(entity.type), tag: index)
        })
        let output = GGTextPipeline.run(input, configuration: configuration, context: context)
        if output == input {
            return text
        }
        var entities: [MessageTextEntity] = []
        for entity in output.entities {
            if entity.tag == GGPipelineEntity.addedOverlay {
                if let hyperlinkTarget {
                    entities.append(MessageTextEntity(range: entity.range, type: .TextMention(peerId: hyperlinkTarget)))
                }
            } else if entity.tag >= 0 && entity.tag < text.entities.count {
                entities.append(MessageTextEntity(range: entity.range, type: text.entities[entity.tag].type))
            }
        }
        entities.sort(by: { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.range.upperBound > rhs.range.upperBound
        })
        return GGOutgoingText(text: output.text, entities: entities)
    }

    /// The stages never change the text under these.
    static func isProtected(_ type: MessageTextEntityType) -> Bool {
        switch type {
        case .Mention, .Hashtag, .BotCommand, .Url, .Email, .Code, .Pre, .TextUrl, .TextMention, .PhoneNumber, .BankCard, .TonAddress, .CustomEmoji, .FormattedDate:
            return true
        case .Unknown, .Bold, .Italic, .Strikethrough, .BlockQuote, .Underline, .Spoiler, .Custom:
            return false
        }
    }

    /// Link-like and code entities: the mention overlay is never put over them.
    static func excludesOverlay(_ type: MessageTextEntityType) -> Bool {
        switch type {
        case .Mention, .Hashtag, .BotCommand, .Url, .Email, .Code, .Pre, .TextUrl, .TextMention, .PhoneNumber, .BankCard, .TonAddress, .FormattedDate:
            return true
        case .Unknown, .Bold, .Italic, .Strikethrough, .BlockQuote, .Underline, .Spoiler, .Custom, .CustomEmoji:
            return false
        }
    }
}

/// «Is this chat a bot?» for the text stages, which run before the Postbox transaction and can not
/// read the peer. Filled when a chat screen appears (sends nearly always come from an open chat);
/// an unknown peer counts as not a bot.
final class GGBotPeerCache {
    static let shared = GGBotPeerCache()

    private struct Key: Hashable {
        let accountPeerId: PeerId
        let peerId: PeerId
    }

    private let lock = NSLock()
    private var bots = Set<Key>()
    private var checked = Set<Key>()

    func isBot(_ peerId: PeerId, accountPeerId: PeerId) -> Bool {
        if peerId.namespace != Namespaces.Peer.CloudUser {
            return false
        }
        self.lock.lock()
        let result = self.bots.contains(Key(accountPeerId: accountPeerId, peerId: peerId))
        self.lock.unlock()
        return result
    }

    func noteChat(_ chatLocation: ChatLocation, context: AccountContext) {
        guard let peerId = chatLocation.peerId, peerId.namespace == Namespaces.Peer.CloudUser else {
            return
        }
        let key = Key(accountPeerId: context.account.peerId, peerId: peerId)
        self.lock.lock()
        let isNew = self.checked.insert(key).inserted
        self.lock.unlock()
        if !isNew {
            return
        }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, case let .user(user)? = peer, user.botInfo != nil else {
                return
            }
            self.lock.lock()
            self.bots.insert(key)
            self.lock.unlock()
        })
    }
}
