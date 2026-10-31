import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore

/// «Обход защиты от копирования»: the server refuses to forward messages of a protected chat, so
/// with the bypass on such messages are sent as new messages (a copy). Media is uploaded again
/// from the copy already on this device (downloaded first when it is not), the text keeps its
/// entities, and the copy is marked verbatim so the outgoing text stages never change it.
/// Called from `ChatControllerForwardMessages.swift` (TelegramUI) for every forward path.
public enum GGForwardCopy {
    public struct Result {
        /// Messages to enqueue instead of the forwards, in the original order.
        public let messages: [EnqueueMessage]
        /// How many source messages had nothing that can be sent again (polls, games…).
        public let skippedCount: Int
        /// How many source messages were not sent because their media could not be downloaded
        /// (deleted from the server, an expired file reference…). The rest of the batch still goes.
        public let failedCount: Int
    }

    /// One source message after the copy step.
    private enum Outcome {
        case message(EnqueueMessage)
        case unsupported
        case failed
    }

    /// The media of a copy: none, a reuploadable local copy, or a download that failed.
    private enum MediaCopy {
        case noMedia
        case media(Media)
        case failed
    }

    /// Copy protection was lifted on this device for the message (the real server flag is set), or
    /// it is self-destructing media kept by «Не сжигать» (shown as ordinary media there; the server
    /// does not forward view-once or timer media, a copy goes without the timer).
    public static func needsCopy(_ message: Message) -> Bool {
        if GGMessagesSettings.keepSelfDestructingMedia.value && message.ggRawContainsSecretMedia {
            return true
        }
        guard GGMessagesSettings.copyProtectionBypass.value else {
            return false
        }
        if message.flags.contains(.CopyProtected) {
            return true
        }
        if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
            return true
        }
        if let group = message.peers[message.id.peerId] as? TelegramGroup, group.flags.contains(.copyProtectionEnabled) {
            return true
        }
        if let channel = message.peers[message.id.peerId] as? TelegramChannel, channel.flags.contains(.copyProtectionEnabled) {
            return true
        }
        return false
    }

    public static func needsCopy(_ messages: [Message]) -> Bool {
        for message in messages where GGForwardCopy.needsCopy(message) {
            return true
        }
        return false
    }

    /// Replaces, in a prepared batch, every forward of a message that needs a copy with the copy.
    /// The forward's own attributes (schedule, silent, paid…) move to the copy; its correlation id
    /// and thread stay. Other messages are kept as they are, in order.
    public static func convert(_ batch: [EnqueueMessage], sources: [Message], account: Account, hideNames: Bool, hideCaptions: Bool) -> Signal<Result, NoError> {
        var sourcesById: [MessageId: Message] = [:]
        for message in sources {
            sourcesById[message.id] = message
        }
        var groupingKeys: [Int64: Int64] = [:]
        let addsAttribution = GGMessagesSettings.forwardAttribution.value && !hideNames
        let signals: [Signal<Outcome, NoError>] = batch.map { item -> Signal<Outcome, NoError> in
            guard case let .forward(source, threadId, _, attributes, correlationId) = item, let message = sourcesById[source], GGForwardCopy.needsCopy(message) else {
                return .single(.message(item))
            }
            var localGroupingKey: Int64?
            if let groupingKey = message.groupingKey {
                if let current = groupingKeys[groupingKey] {
                    localGroupingKey = current
                } else {
                    let value = Int64.random(in: Int64.min ... Int64.max)
                    groupingKeys[groupingKey] = value
                    localGroupingKey = value
                }
            }
            let extra = attributes.filter { !($0 is ForwardOptionsMessageAttribute) }
            return GGForwardCopy.copy(account: account, message: message, addsAttribution: addsAttribution, hideCaption: hideCaptions, threadId: threadId, localGroupingKey: localGroupingKey)
            |> map { outcome -> Outcome in
                guard case let .message(copy) = outcome else {
                    return outcome
                }
                return .message(copy.withUpdatedAttributes { current in
                    return current + extra
                }.withUpdatedCorrelationId(correlationId))
            }
        }
        return combineLatest(signals)
        |> take(1)
        |> map { results -> Result in
            var messages: [EnqueueMessage] = []
            var skipped = 0
            var failed = 0
            for result in results {
                switch result {
                case let .message(message):
                    messages.append(message)
                case .unsupported:
                    skipped += 1
                case .failed:
                    failed += 1
                }
            }
            return Result(messages: messages, skippedCount: skipped, failedCount: failed)
        }
    }

    /// Copies of `messages` (forwards for those that need no copy), for direct sends.
    public static func makeMessages(account: Account, messages: [Message], hideNames: Bool, hideCaptions: Bool, forwardAttributes: [MessageAttribute], threadId: Int64?) -> Signal<Result, NoError> {
        let batch = messages.map { message -> EnqueueMessage in
            return .forward(source: message.id, threadId: threadId, grouping: .auto, attributes: forwardAttributes, correlationId: nil)
        }
        return GGForwardCopy.convert(batch, sources: messages, account: account, hideNames: hideNames, hideCaptions: hideCaptions)
    }

    private static func copy(account: Account, message: Message, addsAttribution: Bool, hideCaption: Bool, threadId: Int64?, localGroupingKey: Int64?) -> Signal<Outcome, NoError> {
        var copiedMedia: Media?
        var mediaSignal: Signal<MediaCopy, NoError> = .single(.noMedia)
        var hasUncopyableMedia = false
        for media in message.media {
            if media is TelegramMediaWebpage {
                continue
            }
            if let image = media as? TelegramMediaImage {
                mediaSignal = GGForwardCopy.reuploadable(image: image, message: message, account: account)
            } else if let file = media as? TelegramMediaFile {
                mediaSignal = GGForwardCopy.reuploadable(file: file, message: message, account: account)
            } else if media is TelegramMediaMap || media is TelegramMediaContact || media is TelegramMediaDice {
                copiedMedia = media
            } else {
                hasUncopyableMedia = true
            }
            break
        }

        var text = message.text
        var entities: [MessageTextEntity] = message.textEntitiesAttribute?.entities ?? []
        let hasMedia = message.media.contains(where: { !($0 is TelegramMediaWebpage) })
        if hideCaption && hasMedia {
            text = ""
            entities = []
        }
        if addsAttribution, let attribution = GGForwardCopy.attribution(message) {
            let shift = (attribution.text as NSString).length + 2
            entities = entities.map { entity in
                return MessageTextEntity(range: (entity.range.lowerBound + shift) ..< (entity.range.upperBound + shift), type: entity.type)
            }
            entities.insert(attribution.entity, at: 0)
            text = attribution.text + "\n\n" + text
        }
        let finalText = text
        let finalEntities = entities

        return mediaSignal
        |> map { reuploaded -> Outcome in
            let media: Media?
            switch reuploaded {
            case .noMedia:
                media = copiedMedia
            case let .media(value):
                media = value
            case .failed:
                // Never send the caption alone when the photo or file it belongs to is missing.
                return .failed
            }
            if media == nil && (hasUncopyableMedia || finalText.isEmpty) {
                return .unsupported
            }
            var attributes: [MessageAttribute] = [GGOutgoingVerbatimAttribute()]
            if !finalEntities.isEmpty {
                attributes.append(TextEntitiesMessageAttribute(entities: finalEntities))
            }
            return .message(.message(text: finalText, attributes: attributes, inlineStickers: [:], mediaReference: media.flatMap { AnyMediaReference.standalone(media: $0) }, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: localGroupingKey, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        }
    }

    private struct Attribution {
        let text: String
        let entity: MessageTextEntity
    }

    /// «From …» as a link to the author (a mention entity, never «@» typed into the text).
    private static func attribution(_ message: Message) -> Attribution? {
        let author: Peer?
        if let forwardInfo = message.forwardInfo {
            author = forwardInfo.author ?? forwardInfo.source
        } else if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info {
            author = channel
        } else {
            author = message.author
        }
        guard let author else {
            return nil
        }
        let title = author.debugDisplayTitle
        if title.isEmpty {
            return nil
        }
        let range = 0 ..< (title as NSString).length
        if author is TelegramUser {
            return Attribution(text: title, entity: MessageTextEntity(range: range, type: .TextMention(peerId: author.id)))
        } else if let addressName = author.addressName, !addressName.isEmpty {
            return Attribution(text: title, entity: MessageTextEntity(range: range, type: .TextUrl(url: "https://t.me/\(addressName)")))
        } else {
            return Attribution(text: title, entity: MessageTextEntity(range: range, type: .Bold))
        }
    }

    // MARK: Media

    /// The complete local copy of a resource: from the cache, or downloaded first. nil when the
    /// download fails — the copy is then reported, never waited for forever (without a network it
    /// simply waits for one, as any download does).
    private static func completedPath(account: Account, message: Message, media: Media, resource: MediaResource, contentType: MediaResourceUserContentType) -> Signal<String?, NoError> {
        let mediaBox = account.postbox.mediaBox
        let reference = MediaResourceReference.media(media: AnyMediaReference.message(message: MessageReference(message), media: media), resource: resource)
        let fetch = fetchedMediaResource(mediaBox: mediaBox, userLocation: .peer(message.id.peerId), userContentType: contentType, reference: reference)
        let path = Signal<String?, NoError> { subscriber in
            let fetchDisposable = fetch.start(error: { _ in
                subscriber.putNext(nil)
                subscriber.putCompletion()
            })
            let dataDisposable = (mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false))
            |> filter { $0.complete }
            |> take(1)).start(next: { data in
                subscriber.putNext(data.path)
                subscriber.putCompletion()
            })
            return ActionDisposable {
                fetchDisposable.dispose()
                dataDisposable.dispose()
            }
        }
        // The data and the failed fetch can race: the first answer wins.
        return path |> take(1)
    }

    private static func reuploadable(image: TelegramMediaImage, message: Message, account: Account) -> Signal<MediaCopy, NoError> {
        guard let largest = largestImageRepresentation(image.representations) else {
            return .single(.failed)
        }
        return GGForwardCopy.completedPath(account: account, message: message, media: image, resource: largest.resource, contentType: .image)
        |> map { path -> MediaCopy in
            guard let path else {
                return .failed
            }
            let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: Int64.random(in: Int64.min ... Int64.max))
            let representation = TelegramMediaImageRepresentation(dimensions: largest.dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: image.immediateThumbnailData)
            return .media(TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: Int64.min ... Int64.max)), representations: [representation], immediateThumbnailData: image.immediateThumbnailData, reference: nil, partialReference: nil, flags: []))
        }
    }

    private static func reuploadable(file: TelegramMediaFile, message: Message, account: Account) -> Signal<MediaCopy, NoError> {
        let contentType: MediaResourceUserContentType
        if file.isVideo {
            contentType = .video
        } else if file.isVoice || file.isMusic {
            contentType = .audio
        } else if file.isSticker || file.isAnimatedSticker {
            contentType = .sticker
        } else {
            contentType = .file
        }
        return GGForwardCopy.completedPath(account: account, message: message, media: file, resource: file.resource, contentType: contentType)
        |> map { path -> MediaCopy in
            guard let path else {
                return .failed
            }
            let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: Int64.random(in: Int64.min ... Int64.max), isUniquelyReferencedTemporaryFile: false, size: file.size)
            return .media(TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: file.previewRepresentations, videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes, alternativeRepresentations: []))
        }
    }
}
