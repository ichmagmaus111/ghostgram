import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore
import GGHooks
import GGFeaturesShared

/// Batch transformers of outgoing messages (`GGOutgoingHooks.messages`), after the text stages:
/// - the verbatim marker of copies is removed before the message is stored;
/// - anonymous stickers: a new upload without the pack reference, reused within the session;
/// - «без "с помощью"»: inline bot results that can be sent as a normal message lose the bot link;
/// - the local creator mode: messages to such a channel are stored on this device only.
enum GGOutgoingTransforms {
    static func register() {
        GGOutgoingHooks.messages.register({ messages, context in
            GGOutgoingTransforms.transform(&messages, context: context)
        }, order: 500)
        GGOutgoingHooks.didEnqueue.register({ context, _ in
            GGAnonymousStickers.shared.learnUploadedCopies(account: context.account, peerId: context.peerId)
        })
        GGOutgoingHooks.reuploadsCloudFile.register({ _, attributes in
            return GGInlineReuploadAttribute.isPresent(in: attributes)
        })
    }

    static func transform(_ messages: inout [EnqueueMessage], context: GGOutgoingContext) {
        if GGMessagesPolicy.isLocalCreatorMode(accountId: context.account.id, peerId: context.peerId) {
            GGLocalCreatorMode.storeLocally(messages, account: context.account, peerId: context.peerId)
            messages = []
            return
        }
        let anonymousStickers = GGMessagesSettings.anonymousStickers.value
        let withoutVia = GGMessagesSettings.sendWithoutViaBot.value
        for index in messages.indices {
            var message = messages[index]
            if GGOutgoingVerbatimAttribute.isPresent(in: message.attributes) {
                message = message.withUpdatedAttributes { attributes in
                    return attributes.filter { !($0 is GGOutgoingVerbatimAttribute) }
                }
            }
            if withoutVia {
                message = GGInlineBotAttribution.withoutBotLink(message)
            }
            if anonymousStickers {
                message = GGAnonymousStickers.shared.anonymized(message, account: context.account)
            }
            messages[index] = message
        }
    }
}

// MARK: - Inline bots

enum GGInlineBotAttribution {
    /// An inline result whose content can be sent on its own (text, cloud photo or file, location,
    /// contact) becomes a normal message: no «via @bot», no bot keyboard. Games, invoices and
    /// results with web content keep the inline path (the decoration still hides «via» locally).
    static func withoutBotLink(_ message: EnqueueMessage) -> EnqueueMessage {
        guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message else {
            return message
        }
        guard attributes.contains(where: { $0 is OutgoingChatContextResultMessageAttribute }) else {
            return message
        }
        let media = mediaReference?.media
        if let media, !GGInlineBotAttribution.canSendDirectly(media) {
            return message
        }
        var updatedAttributes = attributes.filter { attribute in
            return !(attribute is OutgoingChatContextResultMessageAttribute) && !(attribute is InlineBotMessageAttribute) && !(attribute is ReplyMarkupMessageAttribute)
        }
        // Sounds go up as a new file: sent by the bot's reference (`inputMediaDocument`) they never left
        // (owner, 2026-10-30: «@sounds не отправляются при включённом «без «с помощью»»»). The old client
        // re-uploaded every inline file; pictures, GIFs and stickers keep the reference, which works.
        if let file = media as? TelegramMediaFile, GGInlineBotAttribution.isSound(file) {
            updatedAttributes.append(GGInlineReuploadAttribute())
        }
        var updatedText = text
        if media != nil && !GGMessagesSettings.keepInlineBotCaption.value {
            updatedText = ""
            updatedAttributes = updatedAttributes.filter { !($0 is TextEntitiesMessageAttribute) }
        }
        if media == nil && updatedText.isEmpty {
            return message
        }
        return .message(text: updatedText, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: media.flatMap { AnyMediaReference.standalone(media: $0) }, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
    }

    /// Voice, music and round videos: what an inline «sounds» bot sends.
    static func isSound(_ file: TelegramMediaFile) -> Bool {
        return file.isVoice || file.isMusic || file.isInstantVideo || file.attributes.contains(where: { attribute in
            if case .Audio = attribute {
                return true
            }
            return false
        })
    }

    static func canSendDirectly(_ media: Media) -> Bool {
        if let image = media as? TelegramMediaImage {
            if case .cloud? = image.reference {
                return true
            }
            return false
        }
        if let file = media as? TelegramMediaFile {
            return file.resource is CloudDocumentMediaResource
        }
        return media is TelegramMediaMap || media is TelegramMediaContact
    }
}

// MARK: - Anonymous stickers

/// A sticker is sent as a new upload of the file already on this device, with the pack reference
/// removed (the recipient can not open the pack). The first send of a sticker uploads it; the
/// uploaded copy is remembered for the session, so sending the same sticker again reuses it by
/// reference instead of uploading again. Nothing is written on the main thread: the file is
/// referenced in place (`LocalFileReferenceMediaResource`), not copied.
final class GGAnonymousStickers {
    static let shared = GGAnonymousStickers()

    private struct Pending {
        let originalFileId: MediaId
        let size: Int64?
        let mimeType: String
    }

    private let lock = NSLock()
    /// account peer → original file id → the uploaded anonymous copy.
    private var uploaded: [PeerId: [MediaId: TelegramMediaFile]] = [:]
    private var pending: [PeerId: [Pending]] = [:]
    private var listeners: [PeerId: Disposable] = [:]

    func anonymized(_ message: EnqueueMessage, account: Account) -> EnqueueMessage {
        guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, _) = message else {
            return message
        }
        guard let file = mediaReference?.media as? TelegramMediaFile, file.isSticker || file.isAnimatedSticker || file.isVideoSticker else {
            return message
        }
        var hasPackReference = false
        var updatedFileAttributes: [TelegramMediaFileAttribute] = []
        for attribute in file.attributes {
            if case let .Sticker(displayText, packReference, maskData) = attribute {
                if packReference != nil {
                    hasPackReference = true
                }
                updatedFileAttributes.append(.Sticker(displayText: displayText, packReference: nil, maskData: maskData))
            } else {
                updatedFileAttributes.append(attribute)
            }
        }
        guard hasPackReference else {
            return message
        }
        // A sticker picked from an inline bot (@sticker) would otherwise be sent with
        // sendInlineBotResult, which ignores the media and references the pack again.
        let updatedAttributes = attributes.filter { attribute in
            return !(attribute is EmojiSearchQueryMessageAttribute) && !(attribute is OutgoingChatContextResultMessageAttribute) && !(attribute is InlineBotMessageAttribute) && !(attribute is ReplyMarkupMessageAttribute)
        }

        let accountPeerId = account.peerId
        self.lock.lock()
        let cached = self.uploaded[accountPeerId]?[file.fileId]
        self.lock.unlock()

        let anonymousFile: TelegramMediaFile
        if let cached {
            anonymousFile = cached
        } else {
            // A displayed sticker is already downloaded; a stat, not a write.
            guard let path = account.postbox.mediaBox.completedResourcePath(file.resource) else {
                GGLog.warning("messages", "anonymous sticker: file is not on the device yet, sent as is")
                return message
            }
            let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: Int64.random(in: Int64.min ... Int64.max), isUniquelyReferencedTemporaryFile: false, size: file.size)
            anonymousFile = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: file.previewRepresentations, videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: updatedFileAttributes, alternativeRepresentations: [])
            self.lock.lock()
            self.pending[accountPeerId, default: []].append(Pending(originalFileId: file.fileId, size: file.size, mimeType: file.mimeType))
            self.lock.unlock()
        }
        return .message(text: text, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: .standalone(media: anonymousFile), threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: [])
    }

    /// After an anonymous upload was enqueued: watch the chat's delivered messages once and
    /// remember the server's copy of the file (no pack, same size and type).
    func learnUploadedCopies(account: Account, peerId: PeerId) {
        let accountPeerId = account.peerId
        self.lock.lock()
        let hasPending = !(self.pending[accountPeerId]?.isEmpty ?? true)
        let isListening = self.listeners[accountPeerId] != nil
        self.lock.unlock()
        if !hasPending || isListening {
            return
        }
        let signal = account.pendingMessageManager.deliveredMessageEvents(peerId: peerId)
        |> mapToSignal { delivered -> Signal<[Message], NoError> in
            let ids = delivered.map { $0.id }
            return account.postbox.transaction { transaction -> [Message] in
                return ids.compactMap { transaction.getMessage($0) }
            }
        }
        |> timeout(120.0, queue: Queue.concurrentDefaultQueue(), alternate: .complete())
        let disposable = signal.start(next: { [weak self] messages in
            self?.match(messages, accountPeerId: accountPeerId)
        }, completed: { [weak self] in
            self?.stopListening(accountPeerId: accountPeerId, clearPending: true)
        })
        self.lock.lock()
        if self.listeners[accountPeerId] == nil {
            self.listeners[accountPeerId] = disposable
            self.lock.unlock()
        } else {
            self.lock.unlock()
            disposable.dispose()
        }
    }

    private func match(_ messages: [Message], accountPeerId: PeerId) {
        self.lock.lock()
        var pending = self.pending[accountPeerId] ?? []
        for message in messages {
            for media in message.media {
                guard let file = media as? TelegramMediaFile, file.fileId.namespace == Namespaces.Media.CloudFile else {
                    continue
                }
                var isAnonymousSticker = false
                for attribute in file.attributes {
                    if case let .Sticker(_, packReference, _) = attribute, packReference == nil {
                        isAnonymousSticker = true
                    }
                }
                guard isAnonymousSticker, let index = pending.firstIndex(where: { $0.size == file.size && $0.mimeType == file.mimeType }) else {
                    continue
                }
                let entry = pending.remove(at: index)
                self.uploaded[accountPeerId, default: [:]][entry.originalFileId] = file
            }
        }
        self.pending[accountPeerId] = pending
        let isDone = pending.isEmpty
        self.lock.unlock()
        if isDone {
            self.stopListening(accountPeerId: accountPeerId, clearPending: false)
        }
    }

    private func stopListening(accountPeerId: PeerId, clearPending: Bool) {
        self.lock.lock()
        let disposable = self.listeners.removeValue(forKey: accountPeerId)
        if clearPending {
            self.pending[accountPeerId] = nil
        }
        self.lock.unlock()
        disposable?.dispose()
    }
}
