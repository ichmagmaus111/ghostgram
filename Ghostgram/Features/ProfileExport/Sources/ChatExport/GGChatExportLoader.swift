import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore

// History and media for the export, without keeping a chat in memory.
//
// History is read window by window, oldest first, straight from Postbox
// (`aroundMessageHistoryViewForLocation`) — not through `AccountViewTracker`, so no webpage, poll or
// channel refresh is triggered per window. Holes inside a window are filled by the account's own hole
// manager (an open view reports its holes); the window waits for that with a timeout, so a failing
// server does not hang the job.

struct GGChatExportWindow {
    /// Messages strictly after the requested index, oldest first.
    let messages: [Message]
    /// No more messages after the last one.
    let reachedEnd: Bool
}

enum GGChatExportLoadError {
    case timeout
}

enum GGChatExportLoader {
    static let windowSize = 200
    static let windowTimeout: Double = 120.0
    /// A file whose download made no progress for this long while the account was online is given
    /// up (no network, connecting: the clock waits).
    static let mediaStallTimeout: Double = 90.0

    static func window(postbox: Postbox, peerId: PeerId, after: MessageIndex?, queue: Queue) -> Signal<GGChatExportWindow, GGChatExportLoadError> {
        let anchor: HistoryViewInputAnchor
        if let after = after {
            anchor = .index(after)
        } else {
            anchor = .lowerBound
        }
        let views = postbox.aroundMessageHistoryViewForLocation(
            .peer(peerId: peerId, threadId: nil),
            anchor: anchor,
            ignoreMessagesInTimestampRange: nil,
            ignoreMessageIds: Set(),
            count: GGChatExportLoader.windowSize,
            fixedCombinedReadStates: nil,
            topTaggedMessageIdNamespaces: Set(),
            tag: nil,
            appendMessagesFromTheSameGroup: false,
            namespaces: .not(Namespaces.Message.allNonRegular),
            orderStatistics: []
        )
        let window = views
        |> mapToSignal { view, _, _ -> Signal<GGChatExportWindow, NoError> in
            var messages: [Message] = []
            for entry in view.entries {
                if let after = after, entry.index <= after {
                    continue
                }
                messages.append(entry.message)
            }
            let reachedEnd = view.laterId == nil && !view.holeLater
            if !messages.isEmpty {
                return .single(GGChatExportWindow(messages: messages, reachedEnd: reachedEnd))
            }
            if reachedEnd && !view.isLoading {
                return .single(GGChatExportWindow(messages: [], reachedEnd: true))
            }
            // A hole right after the anchor is being filled: wait for the next view.
            return .complete()
        }
        |> take(1)
        |> castError(GGChatExportLoadError.self)
        return window
        |> timeout(GGChatExportLoader.windowTimeout, queue: queue, alternate: .fail(.timeout))
    }

    static func contentType(_ kind: GGChatExportMediaKind) -> MediaResourceUserContentType {
        switch kind {
        case .photo:
            return .image
        case .video, .gif:
            return .video
        case .videoMessage, .voiceMessage:
            return .audioVideoMessage
        case .audio:
            return .audio
        case .sticker:
            return .sticker
        case .file:
            return .file
        }
    }

    /// Downloads one file and puts it into `folder` / `subfolder` (a hard link to the cached file, a
    /// copy when that is not possible). Sets `media.state` (path relative to `folder`); never fails.
    ///
    /// A file that can not be downloaded is «unavailable» at once: a failed fetch (no access, a
    /// server error) ends the wait, and so does a download that made no progress for
    /// `mediaStallTimeout` while `connectionStatus` was online. Without network the wait just goes
    /// on — the export pauses instead of writing every file off (it used to hold the whole queue
    /// 15 minutes on each file that never came).
    static func save(_ media: GGChatExportMedia, postbox: Postbox, peerId: PeerId, folder: URL, subfolder: String?, connectionStatus: Signal<ConnectionStatus, NoError>) -> Signal<Int64, NoError> {
        let resource = media.reference.resource
        let fetch = fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: .peer(peerId), userContentType: GGChatExportLoader.contentType(media.kind), reference: media.reference)
        let data = postbox.mediaBox.resourceData(resource)
        |> filter { $0.complete }
        |> take(1)
        |> map { data -> String? in
            return data.path
        }
        // Each status change (progress) or connection change restarts the clock; only online time counts.
        let stalled: Signal<Void, NoError> = combineLatest(postbox.mediaBox.resourceStatus(resource), connectionStatus)
        |> mapToSignal { _, connection -> Signal<Void, NoError> in
            switch connection {
            case .online, .updating:
                return .single(Void()) |> delay(GGChatExportLoader.mediaStallTimeout, queue: Queue.concurrentDefaultQueue())
            case .waitingForNetwork, .connecting:
                return .never()
            }
        }
        |> take(1)
        return Signal { subscriber in
            let finished = Atomic<Bool>(value: false)
            let dataDisposable = MetaDisposable()
            let fetchDisposable = MetaDisposable()
            let stallDisposable = MetaDisposable()
            let finish: (String?) -> Void = { path in
                if finished.swap(true) {
                    return
                }
                dataDisposable.dispose()
                fetchDisposable.dispose()
                stallDisposable.dispose()
                var savedBytes: Int64 = 0
                if let path = path {
                    let directory = subfolder.map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
                    let target = directory.appendingPathComponent(media.targetName)
                    let fileManager = FileManager.default
                    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                    try? fileManager.removeItem(at: target)
                    var stored = (try? fileManager.linkItem(atPath: path, toPath: target.path)) != nil
                    if !stored {
                        stored = (try? fileManager.copyItem(atPath: path, toPath: target.path)) != nil
                    }
                    if stored {
                        media.state = .saved(relativePath: subfolder.map { $0 + "/" + media.targetName } ?? media.targetName)
                        savedBytes = ((try? fileManager.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    } else {
                        media.state = .unavailable
                    }
                } else {
                    media.state = .unavailable
                }
                subscriber.putNext(savedBytes)
                subscriber.putCompletion()
            }
            // The file first: one already in the cache is saved without starting a download.
            dataDisposable.set(data.start(next: { path in
                finish(path)
            }))
            if !finished.with({ $0 }) {
                fetchDisposable.set(fetch.start(error: { _ in
                    // The server will not give it (no access, an error): unavailable, next file.
                    finish(nil)
                }))
                stallDisposable.set(stalled.start(next: { _ in
                    finish(nil)
                }))
            }
            return ActionDisposable {
                let _ = finished.swap(true)
                fetchDisposable.dispose()
                dataDisposable.dispose()
                stallDisposable.dispose()
            }
        }
    }
}
