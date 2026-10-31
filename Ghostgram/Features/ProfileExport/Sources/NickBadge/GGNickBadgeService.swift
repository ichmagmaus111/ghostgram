import Foundation
import SwiftSignalKit
import TelegramCore
import GGCore
import GGHooks
import GGNickBadgeSlot

// The GCONNECT badge table: who wears which badge. Owner of the network side and of the snapshot
// every slot reads.
//
// - Reading (`badge(forUserId:)`) is one lock-protected load of an immutable table: no disk, no
//   JSON, no `UserDefaults`, from any thread. Until the cache is read (on this class's queue, at
//   launch) there are no badges — the first cells never parse anything on their own thread.
// - The table is fetched through `GGNetwork` (ephemeral session, the user's SOCKS5, nothing about
//   the user in the request) and installed only with a valid server signature. The signed body is
//   kept in the app's caches with its ETag, so a check is a 304 without a body.
// - When: `GGForegroundTaskScheduler` (at most every 5 minutes on returning to the app), when the
//   user turns badges on, and — after the user went to the bot to buy one — at once on returning
//   and again 45 s later (a payment is not always confirmed instantly), only in the foreground.
// - On by default (owner's call, 2026-10-28). Off: no requests, nothing drawn, the table is
//   dropped from memory.
// - A change reaches every place without a settings write: badge views refresh in place
//   (`GGNickBadgeSlot.refreshVisibleSlots`), bubbles through `GGMessageDecorationHooks.redrawAll()`.

enum GGNickBadgeSettings {
    static let isEnabled = GGSetting<Bool>("nickBadge.isEnabled", default: true)

    static func declare() {
        let _ = GGNickBadgeSettings.isEnabled
    }
}

final class GGNickBadgeService {
    static let shared = GGNickBadgeService()

    /// The GCONNECT badge server (allowed by the card: `badges.gconnect.cc`). Every path is relative to it.
    static let baseURL = "https://badges.gconnect.cc/"
    /// The server signs `context + body` (ECDSA P-256 / SHA-256, DER, base64) in this header.
    static let signatureHeader = "X-GTok-Sig"
    static let signatureContext = "GCONNECT-TG-BADGES/1\n"
    /// Public keys (X9.63) the table must be signed with. A new key goes in front; the old one stays
    /// until every client has updated.
    static let signingKeys: [Data] = [
        Data([0x04, 0x98, 0x45, 0x6a, 0x58, 0xf9, 0xd7, 0x7b, 0x7c, 0xd4, 0x39, 0x80, 0x90, 0x48, 0x57, 0x08, 0x57, 0xa8, 0xd1, 0x2a, 0x01, 0xd9, 0x52, 0xe9, 0x0d, 0xf4, 0xa5, 0x82, 0x6e, 0x32, 0xb2, 0x9a, 0x7d, 0xd9, 0xf1, 0xc4, 0x59, 0xad, 0x9e, 0xe4, 0xc7, 0x6d, 0x7f, 0x90, 0x98, 0x4a, 0xfe, 0x0f, 0xdb, 0x88, 0x94, 0xb2, 0x2a, 0xa8, 0x74, 0x90, 0xbb, 0xab, 0x49, 0x3f, 0x96, 0x86, 0x69, 0x10, 0x7a])
    ]
    static let syncInterval: Double = 5.0 * 60.0
    static let purchaseWindow: Double = 30.0 * 60.0
    static let purchaseRecheckDelay: Double = 45.0
    static let defaultBot = "gconnectpay_bot"
    private static let maxTableBytes = 8 * 1024 * 1024

    private struct CacheFile: Codable {
        let version: Int
        let etag: String?
        let body: Data
    }

    private let queue = Queue(name: "org.ghostgram.nickBadge", qos: .utility)
    private let lock = GGProfileExportLock()
    private var table = GGNickBadgeTable.empty

    // Queue only.
    private var etag: String?
    private var didLoadCache = false
    private let syncDisposable = MetaDisposable()

    // Main thread only.
    private var enabledDisposable: Disposable?
    private var purchaseUntil: Double = 0.0
    private var recheckGeneration = 0
    private var cachedServerConfig: (config: GGNickBadgeServerConfig, time: Double)?
    private let changesPipe = ValuePipe<Void>()

    private init() {
    }

    private var cacheURL: URL? {
        return GGProfileExportPaths.cachesDirectory("nickBadge")?.appendingPathComponent("table.json")
    }

    // MARK: - Reading

    /// The badge of a Telegram user (raw user id). Any thread.
    func badge(forUserId userId: Int64) -> GGNickBadge? {
        return self.lock.withLock {
            return self.table.badges[userId]
        }
    }

    func badge(for peerId: EnginePeer.Id) -> GGNickBadge? {
        guard peerId.namespace == Namespaces.Peer.CloudUser else {
            return nil
        }
        return self.badge(forUserId: peerId.id._internalGetInt64Value())
    }

    // MARK: - Lifecycle

    /// From the module's `register()`, main thread.
    func start() {
        assert(Thread.isMainThread)
        GGNickBadgeImages.shared.onPictureLoaded = {
            GGNickBadgeService.shared.badgesDidChange()
        }
        GGForegroundTaskScheduler.shared.register(id: "nickBadge.sync", minimumInterval: GGNickBadgeService.syncInterval, delay: 2.0, task: { done in
            return GGNickBadgeService.shared.sync(completion: done)
        })
        var previous: Bool?
        self.enabledDisposable = (GGNickBadgeSettings.isEnabled.signal
        |> deliverOnMainQueue).start(next: { [weak self] enabled in
            guard let self = self else {
                return
            }
            let wasEnabled = previous
            previous = enabled
            GGNickBadgeSlot.isActive = enabled
            if enabled {
                self.loadCache()
                if wasEnabled == false {
                    // Turned on by the user: fetch now instead of waiting for the next return.
                    let _ = self.sync(completion: {})
                }
            } else if wasEnabled == true {
                self.dropTable()
            }
        })
    }

    /// The user is leaving for the bot to buy a badge.
    func noteWentToBot() {
        assert(Thread.isMainThread)
        self.purchaseUntil = CFAbsoluteTimeGetCurrent() + GGNickBadgeService.purchaseWindow
    }

    /// `GGLifecycleHooks.applicationDidBecomeActive`.
    func applicationDidBecomeActive() {
        guard GGNickBadgeSettings.isEnabled.value, CFAbsoluteTimeGetCurrent() < self.purchaseUntil else {
            return
        }
        self.recheckGeneration += 1
        let generation = self.recheckGeneration
        let _ = self.sync(completion: {})
        Queue.mainQueue().after(GGNickBadgeService.purchaseRecheckDelay, { [weak self] in
            guard let self = self, self.recheckGeneration == generation else {
                return
            }
            let _ = self.sync(completion: {})
        })
    }

    /// `GGLifecycleHooks.applicationWillResignActive`: the delayed re-check never runs in the background.
    func applicationWillResignActive() {
        self.recheckGeneration += 1
    }

    // MARK: - Cache

    private func loadCache() {
        self.queue.async {
            if self.didLoadCache {
                return
            }
            self.didLoadCache = true
            guard let url = self.cacheURL, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(CacheFile.self, from: data), file.version == 1 else {
                return
            }
            guard let table = GGNickBadgeParser.parse(file.body) else {
                return
            }
            self.etag = file.etag
            self.install(table)
        }
    }

    private func saveCache(body: Data, etag: String?) {
        guard let url = self.cacheURL else {
            return
        }
        GGProfileExportPaths.ensureDirectory(url.deletingLastPathComponent(), excludeFromBackup: true)
        if let data = try? JSONEncoder().encode(CacheFile(version: 1, etag: etag, body: body)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func dropTable() {
        self.syncDisposable.set(nil)
        GGNickBadgeImages.shared.cancelAll()
        self.lock.withLock {
            self.table = .empty
        }
        self.queue.async {
            // The cache stays on disk; it is read again when badges are turned back on.
            self.didLoadCache = false
        }
        self.badgesDidChange()
    }

    // MARK: - Sync

    /// One conditional GET of the table. `completion` is called exactly once (the scheduler counts
    /// a failure as a finished run, so a failure backs off by the same interval).
    func sync(completion: @escaping () -> Void) -> Disposable {
        guard GGNickBadgeSettings.isEnabled.value, let url = URL(string: GGNickBadgeService.baseURL + "v1/tg/badges") else {
            completion()
            return EmptyDisposable
        }
        let disposable = MetaDisposable()
        self.queue.async { [self] in
            var request = GGNetworkRequest(url: url, etag: self.etag, signingKeys: GGNickBadgeService.signingKeys, maxBytes: GGNickBadgeService.maxTableBytes)
            request.signatureHeader = GGNickBadgeService.signatureHeader
            request.signatureContext = Data(GGNickBadgeService.signatureContext.utf8)
            let fetch = (GGNetwork.shared.fetch(request)
            |> deliverOn(self.queue)).start(next: { [weak self] response in
                if let self = self, !response.notModified, let body = response.data {
                    self.receive(body: body, etag: response.etag)
                }
            }, error: { error in
                GGLog.info("nickBadge", "table sync failed: \(error)")
                completion()
            }, completed: {
                completion()
            })
            disposable.set(fetch)
            self.syncDisposable.set(disposable)
        }
        return disposable
    }

    private func receive(body: Data, etag: String?) {
        guard let table = GGNickBadgeParser.parse(body) else {
            GGLog.warning("nickBadge", "signed table is not a Telegram table")
            return
        }
        let current = self.lock.withLock { self.table }
        if table.timestamp < current.timestamp {
            // A replayed older table never replaces a newer one.
            return
        }
        self.etag = etag
        self.saveCache(body: body, etag: etag)
        self.install(table)
    }

    private func install(_ table: GGNickBadgeTable) {
        guard GGNickBadgeSettings.isEnabled.value else {
            return
        }
        self.lock.withLock {
            self.table = table
        }
        var imageIds = Set<String>()
        for (_, badge) in table.badges {
            if let imageId = badge.imageId {
                imageIds.insert(imageId)
            }
        }
        GGNickBadgeImages.shared.retain(only: imageIds)
        Queue.mainQueue().async {
            self.badgesDidChange()
        }
    }

    /// Main thread: every visible slot redraws in place, open chats re-lay out their bubbles once
    /// (`redrawAll()` is debounced), the badge screen updates its status.
    func badgesDidChange() {
        assert(Thread.isMainThread)
        GGNickBadgeSlot.refreshVisibleSlots()
        GGMessageDecorationHooks.redrawAll()
        self.changesPipe.putNext(Void())
    }

    /// Fires on the main thread whenever the table or a picture changed.
    var changes: Signal<Void, NoError> {
        return self.changesPipe.signal()
    }

    // MARK: - Server config (the badge screen)

    /// Bot and prices, at most every 5 minutes; only when the badge screen is open.
    func serverConfig() -> Signal<GGNickBadgeServerConfig?, NoError> {
        return Signal { [self] subscriber in
            assert(Thread.isMainThread)
            if let cached = self.cachedServerConfig, CFAbsoluteTimeGetCurrent() - cached.time < GGNickBadgeService.syncInterval {
                subscriber.putNext(cached.config)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            subscriber.putNext(self.cachedServerConfig?.config)
            guard let url = URL(string: GGNickBadgeService.baseURL + "v1/config") else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let request = GGNetworkRequest(url: url, etag: nil, signingKeys: [], maxBytes: 64 * 1024)
            return (GGNetwork.shared.fetch(request)
            |> map { response -> GGNickBadgeServerConfig? in
                guard let data = response.data else {
                    return nil
                }
                return GGNickBadgeServerConfig.parse(data)
            }
            |> deliverOnMainQueue).start(next: { [weak self] config in
                if let config = config {
                    self?.cachedServerConfig = (config, CFAbsoluteTimeGetCurrent())
                    subscriber.putNext(config)
                }
            }, error: { _ in
                subscriber.putCompletion()
            }, completed: {
                subscriber.putCompletion()
            })
        }
        |> runOn(Queue.mainQueue())
    }

    var botUsername: String {
        return self.cachedServerConfig?.config.bot ?? GGNickBadgeService.defaultBot
    }
}
