// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// The outgoing pipeline: every message sent through `enqueueMessages(account:peerId:messages:)`
// (text, media, stickers, forwards, voice) passes these points once, in this order:
//   1. `textStages`  — ordered transformations of text + entities (formatting is preserved);
//   2. `messages`    — the whole batch: attributes, sticker replacement;
//   3. `didEnqueue`  — observers after the messages are stored (e.g. "read on action").
// Stages run on the caller's thread before the Postbox transaction: keep them fast and pure.
// Network work (translation before sending) belongs to the UI point
// `GGChatScreenHooks.willSendText`, which may be asynchronous.
//
// The send delay (`sendDelay`) is asked later, INSIDE the transaction that stores the batch, where the
// chat's peer is at hand (a bot can not take a scheduled message) — and by the standalone senders too
// (share extension, quick forward, Siri), which never pass `enqueueMessages`.

import Foundation
import Postbox
import SwiftSignalKit
import GGCore

public struct GGOutgoingContext {
    public let account: Account
    public let peerId: PeerId
}

/// Text of one outgoing message with its entities (bold, links, custom emoji…).
public struct GGOutgoingText: Equatable {
    public var text: String
    public var entities: [MessageTextEntity]

    public init(text: String, entities: [MessageTextEntity]) {
        self.text = text
        self.entities = entities
    }
}

/// What a text stage knows about the message it transforms.
public struct GGOutgoingTextContext {
    public let account: Account
    public let peerId: PeerId
    /// The message as the UI enqueued it (media, reply, thread, attributes).
    public let message: EnqueueMessage
    public let hasMedia: Bool
    public let threadId: Int64?
}

/// What the send delay decides on. Asked inside the Postbox transaction that stores the batch
/// (`enqueueMessages`) or sends it right away (the standalone senders), with the chat's peer at hand.
public struct GGOutgoingDelayRequest {
    public let accountPeerId: PeerId
    public let peerId: PeerId
    /// The chat as stored in this account's Postbox; nil when it is not there.
    public let peer: Peer?
    /// Attributes of every message of the batch (already scheduled, paid, view-once…).
    public let attributes: [[MessageAttribute]]
    /// The server's time now (`Network.globalTime`).
    public let serverTime: Double
}

/// A message of a standalone sender (share extension, quick forward, Siri) the server accepted. That
/// path stores nothing locally, so `didEnqueue` never hears of it.
public struct GGStandaloneSendContext {
    public let accountPeerId: PeerId
    public let peerId: PeerId
    /// It went out scheduled (the send delay or the sender's own schedule).
    public let isScheduled: Bool
}

public enum GGOutgoingHooks {
    /// Transformer chain over text + entities of every `.message` with non-empty text.
    /// A stage must keep entity ranges valid for the text it returns.
    public static let textStages = GGHookPoint<(inout GGOutgoingText, GGOutgoingTextContext) -> Void>("outgoing.textStages")

    /// Transformer over the whole batch (after the text stages): add attributes,
    /// drop `InlineBotMessageAttribute`, replace a sticker's media, clear bubble-up sets… The send
    /// delay is not here: it needs the chat's peer (`sendDelay`).
    public static let messages = GGHookPoint<(inout [EnqueueMessage], GGOutgoingContext) -> Void>("outgoing.messages")

    /// Observer after the messages are stored (ids in the order of the batch, nil = failed).
    public static let didEnqueue = GGHookPoint<(GGOutgoingContext, [MessageId?]) -> Void>("outgoing.didEnqueue")

    /// Observer: the user set or removed reactions on messages of a chat ("read on action").
    public static let didReact = GGHookPoint<(GGOutgoingContext, [MessageId]) -> Void>("outgoing.didReact")

    /// Policy: the server time to schedule the whole batch for (send delay), nil — send as is. First
    /// non-nil wins. Inside a Postbox transaction, any process: snapshot reads only.
    public static let sendDelay = GGHookPoint<(GGOutgoingDelayRequest) -> Int32?>("outgoing.sendDelay")

    /// Observer: a standalone sender's message was accepted by the server (any process, network queue).
    public static let didSendStandalone = GGHookPoint<(GGStandaloneSendContext) -> Void>("outgoing.didSendStandalone")

    /// Policy: send this cloud file as a fresh upload (download, then upload as a new document) instead
    /// of by reference — e.g. a sound of an inline bot sent without «via», which the server does not
    /// take by the bot's reference. First true wins. Upload path, any thread: attribute checks only.
    public static let reuploadsCloudFile = GGHookPoint<(TelegramMediaFile, [MessageAttribute]) -> Bool>("outgoing.reuploadsCloudFile")

    /// Async transformer of a batch that has forwards, before `enqueueMessages` stores it: forwards the
    /// server would refuse (protected content with the bypass on, kept self-destructing media) become
    /// copies — on every path that forwards (the share sheet, profile media, search, the forward
    /// panel), not only the chat's own forward flow. nil = nothing to change; the first non-nil wins.
    public static let forwardCopies = GGHookPoint<(Account, [EnqueueMessage]) -> Signal<[EnqueueMessage], NoError>?>("outgoing.forwardCopies")
}

/// GHOST hook target: `enqueueMessages`, after the text stages. The batch as it is (synchronously)
/// when it has no forwards or nobody converts them.
func ggConvertForwardCopies(_ messages: [EnqueueMessage], account: Account) -> Signal<[EnqueueMessage], NoError> {
    if GGOutgoingHooks.forwardCopies.isEmpty || !messages.contains(where: { if case .forward = $0 { return true } else { return false } }) {
        return .single(messages)
    }
    for handler in GGOutgoingHooks.forwardCopies.handlers {
        if let signal = handler(account, messages) {
            return signal
        }
    }
    return .single(messages)
}

/// GHOST hook target: the upload of a message's cloud file (`mediaContentToUpload`), before it is
/// sent by reference. false (one load) when nobody asks for a fresh upload.
func ggOutgoingReuploadsCloudFile(_ file: TelegramMediaFile, attributes: [MessageAttribute]) -> Bool {
    if GGOutgoingHooks.reuploadsCloudFile.isEmpty {
        return false
    }
    for handler in GGOutgoingHooks.reuploadsCloudFile.handlers {
        if handler(file, attributes) {
            return true
        }
    }
    return false
}

private func ggOutgoingSendDelay(_ request: GGOutgoingDelayRequest) -> Int32? {
    for handler in GGOutgoingHooks.sendDelay.handlers {
        if let value = handler(request) {
            return value
        }
    }
    return nil
}

/// GHOST hook target: the transaction of `enqueueMessages(account:peerId:messages:)`, before the batch
/// is stored. Every message gets the schedule of the send delay, or none of them does.
func ggApplyOutgoingSendDelay(_ messages: [(Bool, EnqueueMessage)], transaction: Transaction, account: Account, peerId: PeerId) -> [(Bool, EnqueueMessage)] {
    if GGOutgoingHooks.sendDelay.isEmpty || messages.isEmpty {
        return messages
    }
    let request = GGOutgoingDelayRequest(accountPeerId: account.peerId, peerId: peerId, peer: transaction.getPeer(peerId), attributes: messages.map { $0.1.attributes }, serverTime: account.network.globalTime)
    guard let scheduleTime = ggOutgoingSendDelay(request) else {
        return messages
    }
    return messages.map { item -> (Bool, EnqueueMessage) in
        return (item.0, item.1.withUpdatedAttributes { attributes in
            var attributes = attributes
            attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: nil))
            return attributes
        })
    }
}

/// GHOST hook target: a standalone sender, inside its transaction. The message is not stored locally:
/// the schedule goes straight into the request. Nil — send now.
func ggStandaloneSendDelay(accountPeerId: PeerId, peerId: PeerId, peer: Peer, attributes: [MessageAttribute], serverTime: Double) -> Int32? {
    if GGOutgoingHooks.sendDelay.isEmpty {
        return nil
    }
    return ggOutgoingSendDelay(GGOutgoingDelayRequest(accountPeerId: accountPeerId, peerId: peerId, peer: peer, attributes: [attributes], serverTime: serverTime))
}

/// GHOST hook target: the server accepted a standalone sender's message.
func ggStandaloneMessageDidSend(accountPeerId: PeerId, peerId: PeerId, isScheduled: Bool) {
    if GGOutgoingHooks.didSendStandalone.isEmpty {
        return
    }
    let context = GGStandaloneSendContext(accountPeerId: accountPeerId, peerId: peerId, isScheduled: isScheduled)
    for handler in GGOutgoingHooks.didSendStandalone.handlers {
        handler(context)
    }
}

func ggMessagesDidReact(account: Account, messageIds: [MessageId]) {
    if GGOutgoingHooks.didReact.isEmpty {
        return
    }
    guard let peerId = messageIds.first?.peerId else {
        return
    }
    let context = GGOutgoingContext(account: account, peerId: peerId)
    for handler in GGOutgoingHooks.didReact.handlers {
        handler(context, messageIds)
    }
}

// MARK: - Call-site helpers (TelegramCore internal)

func ggTransformOutgoingMessages(_ messages: [EnqueueMessage], account: Account, peerId: PeerId) -> [EnqueueMessage] {
    var result = messages
    if !GGOutgoingHooks.textStages.isEmpty {
        result = result.map { ggApplyOutgoingTextStages($0, account: account, peerId: peerId) }
    }
    if !GGOutgoingHooks.messages.isEmpty {
        let context = GGOutgoingContext(account: account, peerId: peerId)
        for handler in GGOutgoingHooks.messages.handlers {
            handler(&result, context)
        }
    }
    return result
}

func ggOutgoingMessagesDidEnqueue(account: Account, peerId: PeerId, ids: [MessageId?]) {
    if GGOutgoingHooks.didEnqueue.isEmpty {
        return
    }
    let context = GGOutgoingContext(account: account, peerId: peerId)
    for handler in GGOutgoingHooks.didEnqueue.handlers {
        handler(context, ids)
    }
}

private func ggApplyOutgoingTextStages(_ message: EnqueueMessage, account: Account, peerId: PeerId) -> EnqueueMessage {
    guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message else {
        return message
    }
    if text.isEmpty {
        return message
    }
    var entities: [MessageTextEntity] = []
    for attribute in attributes {
        if let attribute = attribute as? TextEntitiesMessageAttribute {
            entities = attribute.entities
            break
        }
    }
    let original = GGOutgoingText(text: text, entities: entities)
    var value = original
    let context = GGOutgoingTextContext(account: account, peerId: peerId, message: message, hasMedia: mediaReference != nil, threadId: threadId)
    for handler in GGOutgoingHooks.textStages.handlers {
        handler(&value, context)
    }
    if value == original {
        return message
    }
    var updatedAttributes = attributes.filter { !($0 is TextEntitiesMessageAttribute) }
    if !value.entities.isEmpty {
        updatedAttributes.append(TextEntitiesMessageAttribute(entities: value.entities))
    }
    return .message(text: value.text, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
}
