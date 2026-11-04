// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// What leaves the device about the user's own activity: online status, "typing",
// read receipts (messages, threads, stories), consumption of media content.

import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit
import GGCore

public struct GGPresenceContext {
    public let accountId: AccountRecordId
    public let accountPeerId: PeerId
}

public struct GGTypingRequest {
    public let peer: Peer
    public let threadId: Int64?
    /// nil = the activity ends.
    public let activity: PeerInputActivity?
    public let accountPeerId: PeerId
}

/// What a read receipt would tell the server.
public enum GGReadReceiptKind {
    /// `messages.readHistory` / `channels.readHistory` / `messages.readEncryptedHistory`.
    /// `maxId` is nil for index-based (secret chat) read states.
    case history(maxId: MessageId.Id?)
    /// The read state of the chat is about to be re-validated against the server, which would
    /// replace a local-only read with the server's unread one. `false` keeps the local state.
    case historyValidation
    /// `messages.readDiscussion` / `messages.readSavedHistory`.
    case thread(threadId: Int64, maxId: MessageId.Id)
    /// `stories.readStories` up to `maxId`.
    case stories(maxId: Int32)
    /// `stories.incrementStoryViews` for a pinned (profile) story.
    case storyView(id: Int32)
    /// `messages.readMessageContents` / `channels.readMessageContents` (voice listened, mentions…).
    case messageContents(ids: [MessageId])
}

public struct GGReadReceiptRequest {
    public let peerId: PeerId
    public let kind: GGReadReceiptKind
    public let accountPeerId: PeerId?

    public var accountId: AccountRecordId? {
        return self.accountPeerId.flatMap(GGAccountHooks.accountId(forAccountPeerId:))
    }
}

public struct GGContentConsumptionRequest {
    public let message: Message
    public let transaction: Transaction

    public var accountPeerId: PeerId? {
        return ggAccountPeerId(transaction: self.transaction)
    }
}

public enum GGPresenceHooks {
    /// Transformer of the "keep the account online" signal before it reaches the presence
    /// manager (`account.updateStatus`). Ghost mode maps it to `false`, "always online" to
    /// `true`. One signal per account, no timers.
    public static let onlinePresence = GGHookPoint<(Signal<Bool, NoError>, GGPresenceContext) -> Signal<Bool, NoError>>("presence.online")

    /// Policy: `false` keeps a "typing…" / activity update from being sent.
    public static let sendTyping = GGHookPoint<(GGTypingRequest) -> Bool?>("presence.sendTyping")

    /// Policy: `false` keeps a read receipt on the device. The local read state is applied and
    /// confirmed as synchronized, so nothing retries it (no validate loop).
    public static let sendReadReceipt = GGHookPoint<(GGReadReceiptRequest) -> Bool?>("presence.sendReadReceipt")

    /// Policy: `false` leaves media content unconsumed: no "listened/viewed" flag, no
    /// self-destruct countdown, nothing sent to the other side (view-once kept, ghost mode).
    public static let consumeContent = GGHookPoint<(GGContentConsumptionRequest) -> Bool?>("presence.consumeContent")
}

// MARK: - Call-site helpers (TelegramCore internal)

func ggOnlinePresenceSignal(_ signal: Signal<Bool, NoError>, accountId: AccountRecordId, accountPeerId: PeerId) -> Signal<Bool, NoError> {
    if GGPresenceHooks.onlinePresence.isEmpty {
        return signal
    }
    let context = GGPresenceContext(accountId: accountId, accountPeerId: accountPeerId)
    var result = signal
    for handler in GGPresenceHooks.onlinePresence.handlers {
        result = handler(result, context)
    }
    return result
}

func ggShouldSendTyping(peer: Peer, threadId: Int64?, activity: PeerInputActivity?, accountPeerId: PeerId) -> Bool {
    if GGPresenceHooks.sendTyping.isEmpty {
        return true
    }
    let request = GGTypingRequest(peer: peer, threadId: threadId, activity: activity, accountPeerId: accountPeerId)
    for handler in GGPresenceHooks.sendTyping.handlers {
        if let value = handler(request) {
            return value
        }
    }
    return true
}

func ggShouldSendReadReceipt(peerId: PeerId, kind: GGReadReceiptKind, accountPeerId: PeerId?) -> Bool {
    if GGPresenceHooks.sendReadReceipt.isEmpty {
        return true
    }
    let request = GGReadReceiptRequest(peerId: peerId, kind: kind, accountPeerId: accountPeerId)
    for handler in GGPresenceHooks.sendReadReceipt.handlers {
        if let value = handler(request) {
            return value
        }
    }
    return true
}

/// GHOST hook target: `synchronizeConsumeMessageContents` of the mention / reply consumption
/// (`ManagedConsumePersonalMessagesActions`), which sends `readMessageContents` past every read
/// receipt (a voice reply turns «listened» for its sender). When `sendReadReceipt` keeps it
/// (`.messageContents`), the mention is marked seen on the device only — what upstream does after the
/// server answered — and nothing is sent. Nil: go on as upstream.
func ggConsumePersonalMessageLocallyIfKept(postbox: Postbox, accountPeerId: PeerId, id: MessageId) -> Signal<Void, NoError>? {
    if GGPresenceHooks.sendReadReceipt.isEmpty {
        return nil
    }
    if ggShouldSendReadReceipt(peerId: id.peerId, kind: .messageContents(ids: [id]), accountPeerId: accountPeerId) {
        return nil
    }
    return postbox.transaction { transaction -> Void in
        transaction.setPendingMessageAction(type: .consumeUnseenPersonalMessage, id: id, action: nil)
        transaction.updateMessage(id, update: { currentMessage in
            var attributes = currentMessage.attributes
            var changed = false
            for j in 0 ..< attributes.count {
                if let attribute = attributes[j] as? ConsumablePersonalMentionMessageAttribute, !attribute.consumed {
                    attributes[j] = ConsumablePersonalMentionMessageAttribute(consumed: true, pending: false)
                    changed = true
                    break
                }
            }
            var updatedTags = currentMessage.tags
            if updatedTags.contains(.unseenPersonalMessage) {
                updatedTags.remove(.unseenPersonalMessage)
                changed = true
            }
            if !changed {
                return .skip
            }
            var storeForwardInfo: StoreMessageForwardInfo?
            if let forwardInfo = currentMessage.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
            }
            return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: updatedTags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
        })
    }
}

func ggShouldSendReadReceipt(peerId: PeerId, readState: PeerReadState, accountPeerId: PeerId?) -> Bool {
    if GGPresenceHooks.sendReadReceipt.isEmpty {
        return true
    }
    let maxId: MessageId.Id?
    switch readState {
    case let .idBased(maxIncomingReadId, _, _, _, _):
        maxId = maxIncomingReadId
    case .indexBased:
        maxId = nil
    }
    return ggShouldSendReadReceipt(peerId: peerId, kind: .history(maxId: maxId), accountPeerId: accountPeerId)
}

func ggShouldConsumeContent(message: Message, transaction: Transaction) -> Bool {
    if GGPresenceHooks.consumeContent.isEmpty {
        return true
    }
    let request = GGContentConsumptionRequest(message: message, transaction: transaction)
    for handler in GGPresenceHooks.consumeContent.handlers {
        if let value = handler(request) {
            return value
        }
    }
    return true
}

/// A forum topic / monoforum thread read (`messages.readDiscussion` / `messages.readSavedHistory`)
/// from the interactive paths (swipe «read», «read all» in a forum). Inside the transaction.
func ggShouldSendThreadReadReceipt(transaction: Transaction, peerId: PeerId, threadId: Int64, maxId: MessageId.Id) -> Bool {
    if GGPresenceHooks.sendReadReceipt.isEmpty {
        return true
    }
    return ggShouldSendReadReceipt(peerId: peerId, kind: .thread(threadId: threadId, maxId: maxId), accountPeerId: ggAccountPeerId(transaction: transaction))
}

/// "Listened / opened" of a secret chat message goes to the other side through the chat's own
/// layer (`readMessagesContent`). Cloud chats are not asked here: their receipt is sent (and
/// asked) by `synchronizeConsumeMessageContents`.
func ggShouldSendSecretContentRead(message: Message, transaction: Transaction) -> Bool {
    if GGPresenceHooks.sendReadReceipt.isEmpty || message.id.peerId.namespace != Namespaces.Peer.SecretChat {
        return true
    }
    return ggShouldSendReadReceipt(peerId: message.id.peerId, kind: .messageContents(ids: [message.id]), accountPeerId: ggAccountPeerId(transaction: transaction))
}

/// Reads a feature sends explicitly («Прочитать», «Прочитать на сервере», a kept read sent later).
/// They bypass `sendReadReceipt` (the user asked for them) and apply the `pts` the server returns,
/// so the next update does not see a gap and fetch the difference. The requests live here because
/// the API layer is TelegramCore's own (`internal import TelegramApi`, `Network.request` internal).
public enum GGExplicitReadRequests {
    /// The chat read on the server up to `maxId`: a forum topic (`threadId`), a monoforum thread
    /// (`subPeer`), a channel, a user or a basic group. A secret chat is read up to `secretMaxDate`.
    public static func readHistory(account: Account, peer: Peer, subPeer: Peer?, threadId: Int64?, maxId: Int32, secretMaxDate: Int32) -> Signal<Bool, NoError> {
        if let secretChat = peer as? TelegramSecretChat {
            guard secretMaxDate > 0 else {
                return .single(false)
            }
            let inputChat = Api.InputEncryptedChat.inputEncryptedChat(.init(chatId: Int32(truncatingIfNeeded: peer.id.id._internalGetInt64Value()), accessHash: secretChat.accessHash))
            return ggSucceeded(account.network.request(Api.functions.messages.readEncryptedHistory(peer: inputChat, maxDate: secretMaxDate)))
        }
        guard let inputPeer = apiInputPeer(peer) else {
            return .single(false)
        }
        if let threadId {
            if let subPeer, let subInputPeer = apiInputPeer(subPeer) {
                return ggSucceeded(account.network.request(Api.functions.messages.readSavedHistory(parentPeer: inputPeer, peer: subInputPeer, maxId: maxId)))
            }
            return ggSucceeded(account.network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: threadId), readMaxId: maxId)))
        }
        if let inputChannel = apiInputChannel(peer) {
            return ggSucceeded(account.network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: maxId)))
        }
        // `messages.readHistory` (users and basic groups; channels and topics return no pts).
        return account.network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: maxId))
        |> map { result -> Bool in
            ggApplyAffectedMessages(account: account, result)
            return true
        }
        |> `catch` { _ -> Signal<Bool, NoError> in
            return .single(false)
        }
    }

    /// "Listened / opened" for these messages of `peer` (voice, round video, view-once media); nil
    /// `peer` = a user or a basic group (`messages.readMessageContents`).
    public static func readMessageContents(account: Account, peer: Peer?, ids: [Int32]) -> Signal<Bool, NoError> {
        if let peer, let inputChannel = apiInputChannel(peer) {
            return ggSucceeded(account.network.request(Api.functions.channels.readMessageContents(channel: inputChannel, id: ids)))
        }
        return account.network.request(Api.functions.messages.readMessageContents(id: ids))
        |> map { result -> Bool in
            ggApplyAffectedMessages(account: account, result)
            return true
        }
        |> `catch` { _ -> Signal<Bool, NoError> in
            return .single(false)
        }
    }

    /// A story marked as viewed for its author: `stories.readStories` (up to it) for an active one,
    /// `stories.incrementStoryViews` for an expired one (open only from the profile).
    public static func readStory(account: Account, peer: Peer, storyId: Int32, isExpired: Bool) -> Signal<Bool, NoError> {
        guard let inputPeer = apiInputPeer(peer) else {
            return .single(false)
        }
        if isExpired {
            return ggSucceeded(account.network.request(Api.functions.stories.incrementStoryViews(peer: inputPeer, id: [storyId])))
        }
        return ggSucceeded(account.network.request(Api.functions.stories.readStories(peer: inputPeer, maxId: storyId)))
    }

    /// One "offline" (`account.updateStatus`).
    public static func sendOffline(account: Account) -> Signal<Never, NoError> {
        return account.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in .single(.boolFalse) }
        |> ignoreValues
    }
}

private func ggSucceeded<T>(_ signal: Signal<T, MTRpcError>) -> Signal<Bool, NoError> {
    return signal
    |> map { _ -> Bool in true }
    |> `catch` { _ -> Signal<Bool, NoError> in .single(false) }
}

private func ggApplyAffectedMessages(account: Account, _ result: Api.messages.AffectedMessages) {
    switch result {
    case let .affectedMessages(affectedMessagesData):
        account.stateManager.addUpdateGroups([.updatePts(pts: affectedMessagesData.pts, ptsCount: affectedMessagesData.ptsCount)])
    }
}
