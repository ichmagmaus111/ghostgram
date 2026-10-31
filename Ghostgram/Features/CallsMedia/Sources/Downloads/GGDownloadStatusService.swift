import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import FetchManagerImpl
import GGCore

/// What is downloading in one chat.
struct GGDownloadPeerStatus: Equatable {
    enum Kind: Equatable {
        case video
        case audio
        case image
        case file
    }

    var peerId: EnginePeer.Id
    /// The first download of the chat in Telegram's priority order.
    var topMessageId: MessageId
    var topFileName: String?
    var topKind: Kind
    var count: Int
    /// 0 when no size is known.
    var totalSize: Int64
    var downloadedSize: Int64
    /// 0…1, rounded to whole percents.
    var progress: Double
    var isPaused: Bool
}

/// Active downloads of one account, per chat.
///
/// Built from the fetch manager's summary (the same source as Telegram's own «Downloads» list) and
/// each entry's resource status. Status ticks arrive dozens of times a second; they only mark the
/// state dirty, and one snapshot is built at most every 0.25 s on this service's queue, rounded to
/// whole percents and published only when it changed. The set of chats with downloads is published
/// separately and changes only when a download starts or ends — the chat list re-lays out those rows
/// only, the percent is drawn by the row's own view.
final class GGDownloadStatusService {
    private static let lock = NSLock()
    private static var services: [AccountRecordId: GGDownloadStatusService] = [:]

    /// The account's service, created on the first call (main thread).
    static func service(for context: AccountContext) -> GGDownloadStatusService {
        GGDownloadStatusService.lock.lock()
        defer {
            GGDownloadStatusService.lock.unlock()
        }
        if let current = GGDownloadStatusService.services[context.account.id] {
            return current
        }
        let service = GGDownloadStatusService(context: context)
        GGDownloadStatusService.services[context.account.id] = service
        return service
    }

    /// The account's service if it exists (hot paths; never creates one).
    static func existing(accountId: AccountRecordId) -> GGDownloadStatusService? {
        GGDownloadStatusService.lock.lock()
        defer {
            GGDownloadStatusService.lock.unlock()
        }
        return GGDownloadStatusService.services[accountId]
    }

    private final class EntryContext {
        var entry: FetchManagerEntrySummary
        var isRemoved = false
        var status: EngineMediaResource.FetchStatus?
        var statusDisposable: Disposable?

        init(entry: FetchManagerEntrySummary) {
            self.entry = entry
        }

        deinit {
            self.statusDisposable?.dispose()
        }
    }

    private weak var context: AccountContext?
    private let queue = Queue(name: "org.ghostgram.downloadStatus")

    // Service queue only.
    private var entries: [FetchManagerLocationEntryId: EntryContext] = [:]
    private var isFlushScheduled = false
    private var lastPublished: [EnginePeer.Id: GGDownloadPeerStatus] = [:]

    private let snapshot = Atomic<[EnginePeer.Id: GGDownloadPeerStatus]>(value: [:])
    private let statusesPromise = ValuePromise<[EnginePeer.Id: GGDownloadPeerStatus]>([:], ignoreRepeated: true)
    private let peersPromise = ValuePromise<Set<EnginePeer.Id>>(Set(), ignoreRepeated: true)

    private var settingsDisposable: Disposable?
    private let entriesDisposable = MetaDisposable()

    private init(context: AccountContext) {
        self.context = context
        // Runs only while one of the two places that show the status is on.
        self.settingsDisposable = (combineLatest(GGCallsMediaSettings.statusInChatList.signal, GGCallsMediaSettings.statusInChat.signal)
        |> map { inList, inChat -> Bool in
            return inList || inChat
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] enabled in
            self?.setEnabled(enabled)
        })
    }

    deinit {
        self.settingsDisposable?.dispose()
        self.entriesDisposable.dispose()
    }

    /// Hot path (chat list layout, any thread): one locked read of the published snapshot.
    func status(peerId: EnginePeer.Id) -> GGDownloadPeerStatus? {
        return self.snapshot.with { $0[peerId] }
    }

    func statusSignal(peerId: EnginePeer.Id) -> Signal<GGDownloadPeerStatus?, NoError> {
        return self.statusesPromise.get()
        |> map { $0[peerId] }
        |> distinctUntilChanged
    }

    var statuses: Signal<[EnginePeer.Id: GGDownloadPeerStatus], NoError> {
        return self.statusesPromise.get()
    }

    /// Chats with at least one download; changes only when a download starts or ends.
    var activePeers: Signal<Set<EnginePeer.Id>, NoError> {
        return self.peersPromise.get()
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            guard let context = self.context, let fetchManager = context.fetchManager as? FetchManagerImpl else {
                return
            }
            let queue = self.queue
            let engine = context.engine
            self.entriesDisposable.set((fetchManager.entriesSummary
            |> deliverOn(queue)).start(next: { [weak self] entries in
                self?.update(entries: entries, engine: engine)
            }))
        } else {
            self.entriesDisposable.set(nil)
            self.queue.async {
                self.entries.removeAll()
                self.publish([:])
            }
        }
    }

    private func update(entries: [FetchManagerEntrySummary], engine: TelegramEngine) {
        var seen = Set<FetchManagerLocationEntryId>()
        for entry in entries {
            guard case .chat = entry.id.location, case .message? = entry.mediaReference else {
                continue
            }
            seen.insert(entry.id)
            let context: EntryContext
            if let current = self.entries[entry.id] {
                context = current
                context.entry = entry
                context.isRemoved = false
            } else {
                context = EntryContext(entry: entry)
                self.entries[entry.id] = context
            }
            if context.statusDisposable == nil {
                let id = entry.id
                context.statusDisposable = (engine.resources.status(resource: EngineMediaResource(entry.resourceReference.resource))
                |> deliverOn(self.queue)).start(next: { [weak self] status in
                    guard let strongSelf = self, let context = strongSelf.entries[id] else {
                        return
                    }
                    if context.status != status {
                        context.status = status
                        strongSelf.scheduleFlush()
                    }
                })
            }
        }
        for (id, context) in self.entries where !seen.contains(id) {
            context.isRemoved = true
        }
        self.scheduleFlush()
    }

    private func scheduleFlush() {
        if self.isFlushScheduled {
            return
        }
        self.isFlushScheduled = true
        self.queue.after(0.25, { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isFlushScheduled = false
            strongSelf.flush()
        })
    }

    private func flush() {
        // A finished or cancelled download leaves the summary; its context goes once its status
        // says so (or right away if it never got one).
        var dropped: [FetchManagerLocationEntryId] = []
        var byPeer: [EnginePeer.Id: [(EntryContext, Double)]] = [:]
        for (id, context) in self.entries {
            let progress: Double?
            switch context.status {
            case .Local:
                progress = nil
            case let .Fetching(_, value):
                progress = Double(value)
            case let .Paused(value):
                progress = Double(value)
            case .Remote:
                progress = context.isRemoved ? nil : 0.0
            case .none:
                progress = context.isRemoved ? nil : 0.0
            }
            guard let progress = progress else {
                dropped.append(id)
                continue
            }
            if context.isRemoved {
                dropped.append(id)
                continue
            }
            guard case let .chat(peerId) = id.location else {
                continue
            }
            byPeer[peerId, default: []].append((context, progress))
        }
        for id in dropped {
            self.entries.removeValue(forKey: id)
        }

        var result: [EnginePeer.Id: GGDownloadPeerStatus] = [:]
        for (peerId, items) in byPeer {
            let sorted = items.sorted(by: { $0.0.entry.priority < $1.0.entry.priority })
            guard let top = sorted.first, case let .message(messageReference, media)? = top.0.entry.mediaReference, let messageId = messageReference.id else {
                continue
            }
            var totalSize: Int64 = 0
            var downloadedSize: Double = 0.0
            var weightedProgress: Double = 0.0
            var weight: Double = 0.0
            var allPaused = true
            for (context, progress) in sorted {
                let size = context.entry.resourceReference.resource.size ?? 0
                totalSize += size
                downloadedSize += Double(size) * progress
                // Unknown sizes count as 1 GB so they do not vanish from the average.
                let itemWeight = size > 0 ? Double(size) : 1024.0 * 1024.0 * 1024.0
                weightedProgress += itemWeight * progress
                weight += itemWeight
                if !context.entry.isPaused {
                    allPaused = false
                }
            }
            let progress = weight > 0.0 ? (weightedProgress / weight * 100.0).rounded() / 100.0 : 0.0
            result[peerId] = GGDownloadPeerStatus(
                peerId: peerId,
                topMessageId: messageId,
                topFileName: (media as? TelegramMediaFile)?.fileName,
                topKind: GGDownloadStatusService.kind(media),
                count: sorted.count,
                totalSize: totalSize,
                downloadedSize: Int64(downloadedSize),
                progress: progress,
                isPaused: allPaused
            )
        }
        self.publish(result)
    }

    private func publish(_ result: [EnginePeer.Id: GGDownloadPeerStatus]) {
        if result == self.lastPublished {
            return
        }
        self.lastPublished = result
        let _ = self.snapshot.swap(result)
        self.statusesPromise.set(result)
        self.peersPromise.set(Set(result.keys))
    }

    private static func kind(_ media: Media) -> GGDownloadPeerStatus.Kind {
        if let file = media as? TelegramMediaFile {
            if file.isVideo {
                return .video
            }
            if file.isMusic || file.isVoice {
                return .audio
            }
            if file.mimeType.hasPrefix("image/") {
                return .image
            }
            return .file
        }
        if media is TelegramMediaImage {
            return .image
        }
        return .file
    }
}
