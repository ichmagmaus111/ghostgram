import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import Display
import AccountContext
import GGCore

/// Registration dates for the profile row — Swiftgram's `SGRegDate` in Ghostgram's architecture:
/// the cache (GGCore: `regDate.evidence`, `regDate.remote`), the evidence from the device,
/// `GGRegDateResolver.resolve`, and readiness — the profiles waiting for a user are laid out again
/// when its evidence changes.
///
/// Main thread. The profile asks on every layout pass: that path reads memory and settings snapshots
/// only, resolves (a binary search) and returns at once, so the estimate by ID shows immediately;
/// the slower evidence is collected once per user and session in the background.
final class GGRegDate {
    static let shared = GGRegDate()

    /// Users kept in memory (collection state, waiting profiles, formatted texts).
    static let memoryLimit = 300

    private struct Key: Hashable {
        let account: GGAccountID
        /// `GGPeerKey.stringValue` of the user: the key of both caches.
        let user: String
    }

    private final class WeakController {
        weak var value: ViewController?

        init(_ value: ViewController) {
            self.value = value
        }
    }

    private final class Entry {
        var collectionStarted = false
        /// Messages the profile was opened from that were already looked at.
        var seenSources = Set<EngineMessage.Id>()
        var lastAccess = 0
        var waiting: [WeakController] = []
        var texts: (snapshot: GGRegDateSnapshot, day: Int32, language: String, texts: GGRegDateRowTexts)?
        let disposables = DisposableSet()

        deinit {
            self.disposables.dispose()
        }

        func addWaiting(_ controller: ViewController) {
            self.waiting.removeAll(where: { $0.value == nil })
            if !self.waiting.contains(where: { $0.value === controller }) {
                self.waiting.append(WeakController(controller))
            }
        }
    }

    private var entries: [Key: Entry] = [:]
    private var accessCounter = 0
    /// Evidence learned during a layout pass, written right after it (a settings write bumps the
    /// store's revision, whose listeners must not run inside the profile's layout).
    private var pendingEvidence: [GGAccountID: [String: GGRegDateStoredEntry]] = [:]
    private var isFlushScheduled = false

    private init() {
    }

    static func now() -> Int32 {
        return Int32(clamping: Int(Date().timeIntervalSince1970))
    }

    // MARK: The profile's question

    /// The row for a user: what is known now, plus its texts. Starts the one-time collection.
    /// Nil when nothing can be said (the resolver has no answer).
    func row(context: AccountContext, peerId: EnginePeer.Id, cachedData: CachedPeerData?, sourceMessageId: EngineMessage.Id?, sourceChatPeerId: EnginePeer.Id?, controller: ViewController?, strings: PresentationStrings) -> (snapshot: GGRegDateSnapshot, texts: GGRegDateRowTexts)? {
        assert(Thread.isMainThread)
        let now = GGRegDate.now()
        let key = Key(account: context.account.id.gg, user: peerId.ggKey.stringValue)
        let entry = self.entry(for: key)

        // What the profile already loaded: Telegram's month and the name / photo change dates.
        var stored = self.storedEntry(key)
        var changed = false
        if let month = GGRegDateEvidenceCollector.telegramMonth(cachedData), stored.noteMonth(month, now: now) {
            changed = true
        }
        for found in GGRegDateEvidenceCollector.statusTraces(cachedData) {
            if stored.noteExistedAt(found.timestamp, trace: found.trace, now: now) {
                changed = true
            }
        }
        if changed {
            self.pendingEvidence[key.account, default: [:]][key.user] = stored
            self.scheduleFlush()
        }

        // Nil only for an account nothing can be said about (a reserved service ID with no month or
        // remote answer): evidence would not change that, so nothing is collected for it.
        guard let snapshot = GGRegDateStore.snapshot(userId: peerId.id._internalGetInt64Value(), stored: stored, remote: GGRegDateSettings.remote.value[key.user], now: now) else {
            return nil
        }
        if let controller {
            entry.addWaiting(controller)
        }
        if !entry.collectionStarted {
            entry.collectionStarted = true
            if let sourceMessageId {
                entry.seenSources.insert(sourceMessageId)
            }
            self.collect(key: key, entry: entry, context: context, peerId: peerId, sourceMessageId: sourceMessageId, sourceChatPeerId: sourceChatPeerId)
        } else if let sourceMessageId, !entry.seenSources.contains(sourceMessageId) {
            // The same person opened from another message or group later in the session.
            entry.seenSources.insert(sourceMessageId)
            self.collectLocal(key: key, entry: entry, context: context, peerId: peerId, sourceMessageId: sourceMessageId, sourceChatPeerId: sourceChatPeerId)
        }
        let day = now / 86400
        let language = strings.primaryComponent.languageCode
        if let cached = entry.texts, cached.snapshot == snapshot, cached.day == day, cached.language == language {
            return (snapshot, cached.texts)
        }
        let texts = GGRegDateText.row(snapshot, now: now, strings: strings)
        entry.texts = (snapshot, day, language, texts)
        return (snapshot, texts)
    }

    // MARK: Collection

    private func collectLocal(key: Key, entry: Entry, context: AccountContext, peerId: EnginePeer.Id, sourceMessageId: EngineMessage.Id?, sourceChatPeerId: EnginePeer.Id?) {
        entry.disposables.add((GGRegDateEvidenceCollector.localTraces(context: context, peerId: peerId, sourceMessageId: sourceMessageId, sourceChatPeerId: sourceChatPeerId)
        |> deliverOnMainQueue).start(next: { [weak self] traces in
            self?.merge(traces, key: key, checked: nil)
        }))
    }

    private func collect(key: Key, entry: Entry, context: AccountContext, peerId: EnginePeer.Id, sourceMessageId: EngineMessage.Id?, sourceChatPeerId: EnginePeer.Id?) {
        self.collectLocal(key: key, entry: entry, context: context, peerId: peerId, sourceMessageId: sourceMessageId, sourceChatPeerId: sourceChatPeerId)

        entry.disposables.add((GGRegDateEvidenceCollector.profilePhotoTrace(context: context, peerId: peerId)
        |> deliverOnMainQueue).start(next: { [weak self] found in
            if let found {
                self?.merge([found], key: key, checked: nil)
            }
        }))

        // The own account: its oldest session, asked once per account ever.
        if peerId == context.account.peerId && !self.storedEntry(key).hasChecked(.sessions) {
            entry.disposables.add((GGRegDateEvidenceCollector.sessionTrace(context: context)
            |> deliverOnMainQueue).start(next: { [weak self] found in
                if let found {
                    self?.merge([found], key: key, checked: .sessions)
                }
            }))
        }

        // A remote service only when an address is set (none now: no request leaves).
        if GGRegDateAPI.isEnabled {
            let now = GGRegDate.now()
            let current = GGRegDateSettings.remote.value[key.user]
            if current.map({ !$0.isFresh(now: now) }) ?? true {
                entry.disposables.add((GGRegDateAPI.fetch(userId: peerId.id._internalGetInt64Value(), now: now)
                |> deliverOnMainQueue).start(next: { [weak self] answer in
                    if let answer {
                        self?.storeRemote(answer, key: key)
                    }
                }))
            }
        }
    }

    private func merge(_ traces: [GGRegDateTraceFound], key: Key, checked: GGRegDateChecks?) {
        let now = GGRegDate.now()
        var stored = self.storedEntry(key)
        var changed = false
        for found in traces {
            if stored.noteExistedAt(found.timestamp, trace: found.trace, now: now) {
                changed = true
            }
        }
        if let checked, stored.noteChecked(checked, now: now) {
            changed = true
        }
        if !changed {
            return
        }
        self.pendingEvidence[key.account, default: [:]][key.user] = stored
        self.flushEvidence()
        self.notify(key)
    }

    private func storeRemote(_ answer: GGRegDateRemoteEntry, key: Key) {
        var remote = GGRegDateSettings.remote.value
        if remote[key.user] == answer {
            return
        }
        remote[key.user] = answer
        GGRegDateSettings.remote.set(GGRegDateStore.trimmedRemote(remote, now: GGRegDate.now()))
        self.notify(key)
    }

    /// Readiness: the profiles showing this user are laid out again and read the new answer.
    private func notify(_ key: Key) {
        guard let entry = self.entries[key] else {
            return
        }
        let controllers = entry.waiting.compactMap { $0.value }
        entry.waiting.removeAll()
        for controller in controllers {
            controller.requestLayout(transition: .immediate)
        }
    }

    // MARK: Storage

    private func storedEntry(_ key: Key) -> GGRegDateStoredEntry {
        if let pending = self.pendingEvidence[key.account]?[key.user] {
            return pending
        }
        return GGRegDateSettings.evidence.value(for: key.account)[key.user] ?? GGRegDateStoredEntry()
    }

    private func scheduleFlush() {
        if self.isFlushScheduled {
            return
        }
        self.isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushEvidence()
        }
    }

    private func flushEvidence() {
        self.isFlushScheduled = false
        let pending = self.pendingEvidence
        self.pendingEvidence = [:]
        for (account, updates) in pending {
            var entries = GGRegDateSettings.evidence.value(for: account)
            for (user, stored) in updates {
                entries[user] = stored
            }
            GGRegDateSettings.evidence.set(GGRegDateStore.trimmedEvidence(entries), for: account)
        }
    }

    private func entry(for key: Key) -> Entry {
        self.accessCounter += 1
        if let entry = self.entries[key] {
            entry.lastAccess = self.accessCounter
            return entry
        }
        if self.entries.count >= GGRegDate.memoryLimit, let oldest = self.entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            self.entries.removeValue(forKey: oldest)
        }
        let entry = Entry()
        entry.lastAccess = self.accessCounter
        self.entries[key] = entry
        return entry
    }
}
