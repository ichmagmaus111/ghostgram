import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore

/// What anti-delete knows about one running account (app process only): its Postbox for the
/// index work after a transaction, and the summaries in memory, so menus and the capture gate
/// answer «does this chat have kept messages» without Postbox.
final class GGAntiDeleteAccountState {
    let id: AccountRecordId
    let peerId: PeerId
    let basePath: String
    weak var postbox: Postbox?
    var summaries: [GGAntiDeleteLogKind: GGAntiDeleteSummary] = [:]
    var summariesLoaded = false
    /// Chats with kept messages that may not be in the summary yet (marked in a transaction whose
    /// index batch has not been flushed).
    var pendingKeptPeers = Set<PeerId>()
    var bookmarkPeers = Set<PeerId>()

    init(id: AccountRecordId, peerId: PeerId, basePath: String, postbox: Postbox) {
        self.id = id
        self.peerId = peerId
        self.basePath = basePath
        self.postbox = postbox
    }
}

public final class GGAntiDeleteAccounts {
    public static let shared = GGAntiDeleteAccounts()

    /// Serial queue of all anti-delete work outside Postbox transactions.
    public let queue = Queue(name: "org.ghostgram.antiDelete", qos: .utility)

    private let lock = NSLock()
    private var states: [AccountRecordId: GGAntiDeleteAccountState] = [:]

    private init() {
    }

    /// `GGAccountHooks.accountWillStart`, app process.
    func accountDidStart(_ context: GGAccountStartContext) {
        if context.isSupplementary {
            return
        }
        let state = GGAntiDeleteAccountState(id: context.id, peerId: context.peerId, basePath: context.basePath, postbox: context.postbox)
        self.lock.lock()
        self.states[context.id] = state
        self.lock.unlock()

        let postbox = context.postbox
        let accountId = context.id
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            let _ = (postbox.transaction { transaction -> ([GGAntiDeleteLogKind: GGAntiDeleteSummary], Set<PeerId>) in
                var summaries: [GGAntiDeleteLogKind: GGAntiDeleteSummary] = [:]
                for kind in GGAntiDeleteLogKind.allCases {
                    summaries[kind] = GGAntiDeleteIndexStore.readSummary(transaction, kind: kind)
                }
                let bookmarkPeers = Set(GGAntiDeleteIndexStore.readBookmarks(transaction).entries.map { PeerId(ggKey: $0.message.peer) })
                return (summaries, bookmarkPeers)
            }
            |> deliverOn(self.queue)).start(next: { [weak self] summaries, bookmarkPeers in
                guard let self else {
                    return
                }
                self.lock.lock()
                if let state = self.states[accountId] {
                    for (kind, summary) in summaries {
                        state.summaries[kind] = summary
                    }
                    state.summariesLoaded = true
                    state.bookmarkPeers = bookmarkPeers
                }
                self.lock.unlock()
                // What the notification service kept while the app was not running.
                GGAntiDeleteIndexQueue.shared.drainInbox(completion: {})
            })
        }
    }

    /// `GGAccountHooks.accountWillBeRemoved`: the account directory (Postbox, archive of media)
    /// goes away with the account; only the memory is ours to drop.
    func accountWillBeRemoved(_ id: AccountRecordId) {
        self.lock.lock()
        self.states.removeValue(forKey: id)
        self.lock.unlock()
    }

    func state(_ id: AccountRecordId) -> GGAntiDeleteAccountState? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.states[id]
    }

    func allStates() -> [GGAntiDeleteAccountState] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.states.values.sorted(by: { $0.id.int64 < $1.id.int64 })
    }

    public func postbox(for id: AccountRecordId) -> Postbox? {
        return self.state(id)?.postbox
    }

    public func basePath(for id: AccountRecordId) -> String? {
        return self.state(id)?.basePath
    }

    func basePath(forPostbox postbox: Postbox) -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        for (_, state) in self.states where state.postbox === postbox {
            return state.basePath
        }
        return nil
    }

    /// The account a Postbox belongs to (menus and screens only know the account context).
    func accountId(forPostbox postbox: Postbox) -> AccountRecordId? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        for (id, state) in self.states where state.postbox === postbox {
            return id
        }
        return nil
    }

    // MARK: Summaries in memory

    public func summary(account id: AccountRecordId, kind: GGAntiDeleteLogKind) -> GGAntiDeleteSummary {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.states[id]?.summaries[kind] ?? GGAntiDeleteSummary()
    }

    /// The number of kept entries of a chat, from memory (0 before the account loaded its index).
    public func count(account id: AccountRecordId, kind: GGAntiDeleteLogKind, peerId: PeerId) -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.states[id]?.summaries[kind]?.count(for: peerId.ggKey) ?? 0
    }

    /// True when the chat has messages kept as deleted (or marked in a not yet flushed batch).
    /// Unknown accounts (extensions, accounts still loading) answer true: the caller then looks at
    /// the messages themselves, which is always correct, only slower.
    func mayHaveKeptMessages(account id: AccountRecordId?, peerId: PeerId) -> Bool {
        guard let id else {
            return true
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let state = self.states[id], state.summariesLoaded else {
            return true
        }
        if state.pendingKeptPeers.contains(peerId) {
            return true
        }
        return (state.summaries[.deleted]?.count(for: peerId.ggKey) ?? 0) > 0
    }

    func noteKept(account id: AccountRecordId, peerId: PeerId) {
        self.lock.lock()
        self.states[id]?.pendingKeptPeers.insert(peerId)
        self.lock.unlock()
    }

    func updateSummaries(account id: AccountRecordId, _ summaries: [GGAntiDeleteLogKind: GGAntiDeleteSummary], flushedPeers: Set<PeerId>) {
        self.lock.lock()
        if let state = self.states[id] {
            for (kind, summary) in summaries {
                state.summaries[kind] = summary
            }
            state.pendingKeptPeers.subtract(flushedPeers)
        }
        self.lock.unlock()
    }

    public func hasBookmarks(account id: AccountRecordId, peerId: PeerId) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.states[id]?.bookmarkPeers.contains(peerId) ?? false
    }

    func updateBookmarkPeers(account id: AccountRecordId, peers: Set<PeerId>) {
        self.lock.lock()
        self.states[id]?.bookmarkPeers = peers
        self.lock.unlock()
    }
}
