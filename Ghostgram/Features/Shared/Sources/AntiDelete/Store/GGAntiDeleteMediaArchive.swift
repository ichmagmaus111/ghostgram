import Darwin
import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore

/// «Сохранять медиа удалённых»: a deleted message keeps only a reference to its media, and the
/// cache cleanup would eventually delete the file, which can not be downloaded again once the
/// server has deleted the message. The archive keeps a hard link (no extra space while the cache
/// still has the file) per message and resource in `<account>/ghostgram/antiDelete/media`, and
/// links it back into the media cache when the chat with the message is opened.
/// Never for secret chats: their media must not outlive the chat outside the media box.
public enum GGAntiDeleteMediaArchive {
    public static let maximumFileSize: Int64 = 100 * 1024 * 1024

    static func directory(basePath: String) -> String {
        return basePath + "/ghostgram/antiDelete/media"
    }

    private static func sanitized(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
        return result
    }

    static func archivedPath(basePath: String, messageId: MessageId, resourceId: MediaResourceId) -> String {
        let peer = messageId.peerId.ggKey
        let name = "\(peer.namespace)_\(peer.id)_\(messageId.namespace)_\(messageId.id)_" + GGAntiDeleteMediaArchive.sanitized(resourceId.stringRepresentation)
        return GGAntiDeleteMediaArchive.directory(basePath: basePath) + "/" + name
    }

    /// The resources worth keeping: the largest photo, the file itself (bounded size).
    static func resources(of message: Message) -> [(resource: TelegramMediaResource, media: Media, contentType: MediaResourceUserContentType)] {
        if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
            return []
        }
        var result: [(resource: TelegramMediaResource, media: Media, contentType: MediaResourceUserContentType)] = []
        for media in message.media {
            if let image = media as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations) {
                result.append((representation.resource, image, .image))
            } else if let file = media as? TelegramMediaFile {
                if let size = file.size, size > GGAntiDeleteMediaArchive.maximumFileSize {
                    continue
                }
                let contentType: MediaResourceUserContentType
                if file.isInstantVideo {
                    contentType = .audioVideoMessage
                } else if file.isVideo {
                    contentType = .video
                } else if file.isVoice || file.isMusic {
                    contentType = .audio
                } else if file.isSticker || file.isAnimatedSticker {
                    contentType = .sticker
                } else {
                    contentType = .file
                }
                result.append((file.resource, file, contentType))
            }
        }
        return result
    }

    private static func ensureDirectory(_ path: String) {
        if FileManager.default.fileExists(atPath: path) {
            return
        }
        let _ = try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func link(from source: String, to destination: String) {
        if FileManager.default.fileExists(atPath: destination) {
            return
        }
        if Darwin.link(source, destination) != 0 {
            let _ = try? FileManager.default.copyItem(atPath: source, toPath: destination)
        }
    }

    /// After new deleted entries were indexed (anti-delete queue).
    static func archive(postbox: Postbox, basePath: String, peerId: PeerId, entries: [GGAntiDeleteLogEntry]) {
        if !GGAntiDeleteSettings.keepMedia.value || peerId.namespace == Namespaces.Peer.SecretChat {
            return
        }
        let ids = entries.filter { !$0.isArchiveOnly }.map { MessageId(peerId: peerId, namespace: $0.namespace, id: $0.id) }
        if ids.isEmpty {
            return
        }
        let _ = (postbox.transaction { transaction -> [Message] in
            return ids.compactMap { transaction.getMessage($0) }
        }
        |> deliverOn(GGAntiDeleteAccounts.shared.queue)).start(next: { messages in
            let directory = GGAntiDeleteMediaArchive.directory(basePath: basePath)
            GGAntiDeleteMediaArchive.ensureDirectory(directory)
            for message in messages {
                for item in GGAntiDeleteMediaArchive.resources(of: message) {
                    let destination = GGAntiDeleteMediaArchive.archivedPath(basePath: basePath, messageId: message.id, resourceId: item.resource.id)
                    if let path = postbox.mediaBox.completedResourcePath(id: item.resource.id) {
                        GGAntiDeleteMediaArchive.link(from: path, to: destination)
                        continue
                    }
                    // Not downloaded yet: try now, while the file reference may still be valid.
                    let reference = AnyMediaReference.message(message: MessageReference(message), media: item.media).resourceReference(item.resource)
                    let _ = (fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: .peer(peerId), userContentType: item.contentType, reference: reference)
                    |> deliverOn(GGAntiDeleteAccounts.shared.queue)).start(error: { _ in
                    }, completed: {
                        if let path = postbox.mediaBox.completedResourcePath(id: item.resource.id) {
                            GGAntiDeleteMediaArchive.link(from: path, to: destination)
                        }
                    })
                }
            }
        })
    }

    /// Puts archived files back into the media cache for kept messages of a chat whose cached
    /// copy is gone. Returns (async) the messages that got something back, to redraw them.
    public static func restore(postbox: Postbox, basePath: String, peerId: PeerId, completion: @escaping ([MessageId]) -> Void) {
        if peerId.namespace == Namespaces.Peer.SecretChat {
            completion([])
            return
        }
        let directory = GGAntiDeleteMediaArchive.directory(basePath: basePath)
        let _ = (postbox.transaction { transaction -> [Message] in
            let log = GGAntiDeleteIndexStore.readLog(transaction, kind: .deleted, peerId: peerId)
            return log.entries.filter { !$0.isArchiveOnly }.compactMap { transaction.getMessage(MessageId(peerId: peerId, namespace: $0.namespace, id: $0.id)) }
        }
        |> deliverOn(GGAntiDeleteAccounts.shared.queue)).start(next: { messages in
            if !FileManager.default.fileExists(atPath: directory) {
                completion([])
                return
            }
            var restored: [MessageId] = []
            for message in messages {
                var didRestore = false
                for item in GGAntiDeleteMediaArchive.resources(of: message) {
                    if postbox.mediaBox.completedResourcePath(id: item.resource.id) != nil {
                        continue
                    }
                    let archived = GGAntiDeleteMediaArchive.archivedPath(basePath: basePath, messageId: message.id, resourceId: item.resource.id)
                    if FileManager.default.fileExists(atPath: archived) {
                        GGAntiDeleteMediaArchive.link(from: archived, to: postbox.mediaBox.resourcePath(item.resource))
                        didRestore = true
                    }
                }
                if didRestore {
                    restored.append(message.id)
                }
            }
            completion(restored)
        })
    }

    /// Removes the archived files of messages that are deleted for real (anti-delete queue).
    static func remove(basePath: String, items: [(messageId: MessageId, resourceIds: [MediaResourceId])]) {
        for item in items {
            for resourceId in item.resourceIds {
                let path = GGAntiDeleteMediaArchive.archivedPath(basePath: basePath, messageId: item.messageId, resourceId: resourceId)
                unlink(path)
            }
        }
    }

    /// Everything of an account (history cleared).
    static func removeAll(basePath: String) {
        let _ = try? FileManager.default.removeItem(atPath: GGAntiDeleteMediaArchive.directory(basePath: basePath))
    }
}
