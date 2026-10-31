import Foundation
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import TelegramStringFormatting
import LocalizedPeerData

// A history message as the writers see it: author, dates, reply, forward, text with entities,
// a service line, and at most one media item (with where its file went, if it was downloaded).

enum GGChatExportMediaKind {
    case photo
    case video
    case videoMessage
    case voiceMessage
    case audio
    case sticker
    case gif
    case file

    /// Telegram Desktop's folder.
    var directory: String {
        switch self {
        case .photo:
            return "photos"
        case .video, .gif:
            return "video_files"
        case .videoMessage:
            return "round_video_messages"
        case .voiceMessage:
            return "voice_messages"
        case .sticker:
            return "stickers"
        case .audio, .file:
            return "files"
        }
    }

    /// Telegram Desktop's `media_type`; nil for photos and plain files.
    var jsonMediaType: String? {
        switch self {
        case .photo, .file:
            return nil
        case .video:
            return "video_file"
        case .gif:
            return "animation"
        case .videoMessage:
            return "video_message"
        case .voiceMessage:
            return "voice_message"
        case .audio:
            return "audio_file"
        case .sticker:
            return "sticker"
        }
    }

    func isIncluded(in options: GGChatExportOptions) -> Bool {
        switch self {
        case .photo:
            return options.photos
        case .video:
            return options.videos
        case .videoMessage:
            return options.videoMessages
        case .voiceMessage:
            return options.voiceMessages
        case .sticker:
            return options.stickers
        case .gif:
            return options.gifs
        case .audio, .file:
            return options.files
        }
    }
}

enum GGChatExportMediaState {
    /// Included by the options and within the size limit: to be downloaded.
    case pending
    case saved(relativePath: String)
    case notIncluded
    case tooLarge
    /// Included, but the download failed.
    case unavailable
}

final class GGChatExportMedia {
    let kind: GGChatExportMediaKind
    let reference: MediaResourceReference
    let size: Int64?
    let fileName: String?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let duration: Int?
    let stickerEmoji: String?
    /// Deterministic name inside its folder: a resumed job writes the same file again.
    let targetName: String
    var state: GGChatExportMediaState = .notIncluded

    init(kind: GGChatExportMediaKind, reference: MediaResourceReference, size: Int64?, fileName: String?, mimeType: String?, width: Int?, height: Int?, duration: Int?, stickerEmoji: String?, targetName: String) {
        self.kind = kind
        self.reference = reference
        self.size = size
        self.fileName = fileName
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.duration = duration
        self.stickerEmoji = stickerEmoji
        self.targetName = targetName
    }

    var relativePath: String? {
        if case let .saved(path) = self.state {
            return path
        }
        return nil
    }
}

struct GGChatExportPoll {
    let question: String
    let isClosed: Bool
    let totalVoters: Int
    let answers: [(text: String, voters: Int, chosen: Bool)]
}

final class GGChatExportItem {
    let index: MessageIndex
    let isService: Bool
    let timestamp: Int32
    let editedTimestamp: Int32?
    let authorName: String
    /// `user123`, `channel123`, `chat123` as Telegram Desktop writes it.
    let authorId: String?
    let authorKey: PeerId?
    let forwardedFrom: String?
    let replyToId: Int32?
    let text: String
    let entities: [MessageTextEntity]
    let serviceText: String?
    let media: GGChatExportMedia?
    let contact: (firstName: String, lastName: String, phone: String)?
    let location: (latitude: Double, longitude: Double, title: String?)?
    let poll: GGChatExportPoll?

    init(index: MessageIndex, isService: Bool, timestamp: Int32, editedTimestamp: Int32?, authorName: String, authorId: String?, authorKey: PeerId?, forwardedFrom: String?, replyToId: Int32?, text: String, entities: [MessageTextEntity], serviceText: String?, media: GGChatExportMedia?, contact: (firstName: String, lastName: String, phone: String)?, location: (latitude: Double, longitude: Double, title: String?)?, poll: GGChatExportPoll?) {
        self.index = index
        self.isService = isService
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
        self.authorName = authorName
        self.authorId = authorId
        self.authorKey = authorKey
        self.forwardedFrom = forwardedFrom
        self.replyToId = replyToId
        self.text = text
        self.entities = entities
        self.serviceText = serviceText
        self.media = media
        self.contact = contact
        self.location = location
        self.poll = poll
    }
}

/// What the converters need from the app (captured once when the job starts).
struct GGChatExportEnvironment {
    let accountPeerId: PeerId
    let strings: PresentationStrings
    let nameDisplayOrder: PresentationPersonNameOrder
    let dateTimeFormat: PresentationDateTimeFormat
}

enum GGChatExportConvert {
    static func name(_ peer: Peer?, environment: GGChatExportEnvironment) -> String {
        guard let peer = peer else {
            return ""
        }
        return EnginePeer(peer).displayTitle(strings: environment.strings, displayOrder: environment.nameDisplayOrder)
    }

    static func peerIdString(_ peerId: PeerId) -> String {
        let raw = peerId.id._internalGetInt64Value()
        if peerId.namespace == Namespaces.Peer.CloudUser {
            return "user\(raw)"
        } else if peerId.namespace == Namespaces.Peer.CloudChannel {
            return "channel\(raw)"
        } else {
            return "chat\(raw)"
        }
    }

    /// Telegram Desktop's chat type.
    static func chatType(_ peer: Peer, accountPeerId: PeerId) -> String {
        if peer.id == accountPeerId {
            return "saved_messages"
        }
        if let user = peer as? TelegramUser {
            return user.botInfo != nil ? "bot_chat" : "personal_chat"
        }
        if peer is TelegramSecretChat {
            return "personal_chat"
        }
        if let channel = peer as? TelegramChannel {
            let isPublic = channel.addressName != nil
            if case .broadcast = channel.info {
                return isPublic ? "public_channel" : "private_channel"
            }
            return isPublic ? "public_supergroup" : "private_supergroup"
        }
        return "private_group"
    }

    static func item(_ message: Message, environment: GGChatExportEnvironment, options: GGChatExportOptions, format: GGChatExportFormat) -> GGChatExportItem {
        let author = message.effectiveAuthor ?? message.author
        var editedTimestamp: Int32?
        var replyToId: Int32?
        var entities: [MessageTextEntity] = []
        for attribute in message.attributes {
            if let attribute = attribute as? EditedMessageAttribute, !attribute.isHidden {
                editedTimestamp = attribute.date
            } else if let attribute = attribute as? ReplyMessageAttribute, attribute.messageId.peerId == message.id.peerId {
                replyToId = attribute.messageId.id
            } else if let attribute = attribute as? TextEntitiesMessageAttribute {
                entities = attribute.entities
            }
        }

        var forwardedFrom: String?
        if let forwardInfo = message.forwardInfo {
            if let forwardAuthor = forwardInfo.author {
                forwardedFrom = GGChatExportConvert.name(forwardAuthor, environment: environment)
            } else if let signature = forwardInfo.authorSignature {
                forwardedFrom = signature
            }
        }

        var serviceText: String?
        var isService = false
        var media: GGChatExportMedia?
        var contact: (firstName: String, lastName: String, phone: String)?
        var location: (latitude: Double, longitude: Double, title: String?)?
        var poll: GGChatExportPoll?
        for messageMedia in message.media {
            if messageMedia is TelegramMediaAction {
                isService = true
                let text = plainServiceMessageString(strings: environment.strings, nameDisplayOrder: environment.nameDisplayOrder, dateTimeFormat: environment.dateTimeFormat, message: EngineMessage(message), accountPeerId: environment.accountPeerId, forChatList: false, forForumOverview: false)?.text
                serviceText = text ?? ""
            } else if media == nil, let exportMedia = GGChatExportConvert.media(messageMedia, message: message, format: format) {
                media = exportMedia
            } else if let value = messageMedia as? TelegramMediaContact {
                contact = (value.firstName, value.lastName, value.phoneNumber)
            } else if let value = messageMedia as? TelegramMediaMap {
                location = (value.latitude, value.longitude, value.venue?.title)
            } else if let value = messageMedia as? TelegramMediaPoll {
                var answers: [(text: String, voters: Int, chosen: Bool)] = []
                for option in value.options {
                    let voters = value.results.voters?.first(where: { $0.opaqueIdentifier == option.opaqueIdentifier })
                    answers.append((option.text, Int(voters?.count ?? 0), voters?.selected ?? false))
                }
                poll = GGChatExportPoll(question: value.text, isClosed: value.isClosed, totalVoters: Int(value.results.totalVoters ?? 0), answers: answers)
            }
        }
        if let exportMedia = media {
            exportMedia.state = exportMedia.kind.isIncluded(in: options) ? .pending : .notIncluded
            if exportMedia.kind.isIncluded(in: options), options.sizeLimitBytes > 0, let size = exportMedia.size, size > options.sizeLimitBytes {
                exportMedia.state = .tooLarge
            }
        }

        return GGChatExportItem(
            index: message.index,
            isService: isService,
            timestamp: message.timestamp,
            editedTimestamp: editedTimestamp,
            authorName: GGChatExportConvert.name(author, environment: environment),
            authorId: author.flatMap { GGChatExportConvert.peerIdString($0.id) },
            authorKey: author?.id,
            forwardedFrom: forwardedFrom,
            replyToId: replyToId,
            text: message.text,
            entities: entities,
            serviceText: serviceText,
            media: media,
            contact: contact,
            location: location,
            poll: poll
        )
    }

    private static func fileExtension(fileName: String?, mimeType: String, fallback: String) -> String {
        if let fileName = fileName {
            let pathExtension = (fileName as NSString).pathExtension
            if !pathExtension.isEmpty {
                return pathExtension
            }
        }
        switch mimeType.lowercased() {
        case "video/mp4":
            return "mp4"
        case "video/webm":
            return "webm"
        case "audio/ogg":
            return "ogg"
        case "audio/mpeg":
            return "mp3"
        case "audio/mp4", "audio/x-m4a":
            return "m4a"
        case "image/webp":
            return "webp"
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "application/x-tgsticker":
            return "tgs"
        default:
            return fallback
        }
    }

    private static func media(_ media: Media, message: Message, format: GGChatExportFormat) -> GGChatExportMedia? {
        let messageReference = MessageReference(message)
        let datePart = format.fileDate(message.timestamp)
        let idPart = "\(message.id.id)"
        if let image = media as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations) {
            return GGChatExportMedia(
                kind: .photo,
                reference: .media(media: .message(message: messageReference, media: image), resource: representation.resource),
                size: representation.resource.size,
                fileName: nil,
                mimeType: "image/jpeg",
                width: Int(representation.dimensions.width),
                height: Int(representation.dimensions.height),
                duration: nil,
                stickerEmoji: nil,
                targetName: "photo_\(idPart)@\(datePart).jpg"
            )
        }
        guard let file = media as? TelegramMediaFile else {
            return nil
        }
        let kind: GGChatExportMediaKind
        if file.isSticker || file.isAnimatedSticker || file.isVideoSticker {
            kind = .sticker
        } else if file.isInstantVideo {
            kind = .videoMessage
        } else if file.isVoice {
            kind = .voiceMessage
        } else if file.isAnimated {
            kind = .gif
        } else if file.isVideo {
            kind = .video
        } else if file.isMusic {
            kind = .audio
        } else {
            kind = .file
        }
        var stickerEmoji: String?
        for attribute in file.attributes {
            if case let .Sticker(displayText, _, _) = attribute {
                stickerEmoji = displayText
            }
        }
        let targetName: String
        switch kind {
        case .sticker:
            targetName = "sticker_\(idPart).\(GGChatExportConvert.fileExtension(fileName: file.fileName, mimeType: file.mimeType, fallback: "webp"))"
        case .voiceMessage:
            targetName = "audio_\(idPart)@\(datePart).\(GGChatExportConvert.fileExtension(fileName: nil, mimeType: file.mimeType, fallback: "ogg"))"
        case .videoMessage:
            targetName = "file_\(idPart)@\(datePart).mp4"
        default:
            if let fileName = file.fileName, !fileName.isEmpty {
                targetName = idPart + "_" + GGChatExportEscape.fileName(fileName)
            } else {
                targetName = "file_\(idPart)@\(datePart).\(GGChatExportConvert.fileExtension(fileName: nil, mimeType: file.mimeType, fallback: "bin"))"
            }
        }
        let dimensions = file.dimensions
        return GGChatExportMedia(
            kind: kind,
            reference: .media(media: .message(message: messageReference, media: file), resource: file.resource),
            size: file.size ?? file.resource.size,
            fileName: file.fileName,
            mimeType: file.mimeType,
            width: dimensions.flatMap { Int($0.width) },
            height: dimensions.flatMap { Int($0.height) },
            duration: file.duration.flatMap { Int($0) },
            stickerEmoji: stickerEmoji,
            targetName: targetName
        )
    }
}
