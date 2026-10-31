import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGFeaturesShared

/// Per-account machinery of the zone, started the first time the UI meets an account (its root
/// screens, a chat, a menu) and kept while the account lives. Each piece runs only while its
/// setting asks for it:
///
/// - folder exceptions → the folder definitions and contacts follow `updatedChatListFilters` and
///   the contact list (no stored peer snapshots that go stale);
/// - «Скрыть сообщения заблокированных» → the blocked list of this account, all pages;
/// - an unfinished «Подглядеть онлайн» is undone; old exception ids are resolved once.
///
/// Main thread only.
final class GGGhostAccounts {
    static let shared = GGGhostAccounts()

    private final class Services {
        weak var context: AccountContext?
        let settingsDisposable = DisposableSet()
        let foldersDisposable = MetaDisposable()
        let recoveryDisposable = MetaDisposable()
        let offlineDisposable = MetaDisposable()

        init(context: AccountContext) {
            self.context = context
        }

        deinit {
            self.settingsDisposable.dispose()
            self.foldersDisposable.dispose()
            self.recoveryDisposable.dispose()
            self.offlineDisposable.dispose()
        }
    }

    private var services: [GGAccountID: Services] = [:]

    private init() {
    }

    func accountWillBeRemoved(_ account: GGAccountID) {
        self.services.removeValue(forKey: account)
    }

    func context(for account: GGAccountID) -> AccountContext? {
        return self.services[account]?.context
    }

    var contexts: [AccountContext] {
        return self.services.values.compactMap { $0.context }
    }

    /// Main thread.
    func note(_ context: AccountContext) {
        let account = context.account.id.gg
        if let existing = self.services[account] {
            if existing.context == nil {
                existing.context = context
            }
            return
        }
        let services = Services(context: context)
        self.services[account] = services

        services.settingsDisposable.add((GGGhostSettings.exceptFolders.signal(for: account)
        |> map { !$0.isEmpty }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak services] needed in
            guard let services = services else {
                return
            }
            if needed, let context = services.context {
                services.foldersDisposable.set(combineLatest(
                    context.engine.peers.updatedChatListFilters(),
                    context.engine.data.subscribe(TelegramEngine.EngineData.Item.Contacts.List(includePresences: false))
                ).start(next: { filters, contacts in
                    var folders: [Int32: ChatListFilterData] = [:]
                    for filter in filters {
                        if case let .filter(id, _, _, data) = filter {
                            folders[id] = data
                        }
                    }
                    GGGhostPeerTraits.shared.updateFolders(folders, account: account)
                    GGGhostPeerTraits.shared.updateContacts(Set(contacts.peers.map { $0.id }), account: account)
                    GGGhostPresence.shared.exceptionsDidChange()
                }))
            } else {
                services.foldersDisposable.set(nil)
                GGGhostPeerTraits.shared.updateFolders([:], account: account)
                GGGhostPeerTraits.shared.updateContacts([], account: account)
            }
        }))

        services.settingsDisposable.add((GGGhostSettings.hideBlockedMessages.signal(for: account)
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak services] enabled in
            if enabled, let context = services?.context {
                GGGhostBlockedPeers.shared.reload(context: context)
            } else if !enabled {
                GGGhostBlockedPeers.shared.clear(account: account)
            }
        }))

        services.recoveryDisposable.set(GGGhostPeekOnline.recoverIfNeeded(context: context).start())
        GGGhostAccounts.resolveLegacyExceptions(context: context)
    }

    /// One "offline" a few seconds after a send that ghost mode lets out while it hides online:
    /// the server counts the send as activity. Re-armed by every send, so a burst ends with one request.
    func scheduleOfflineAfterSend(context: AccountContext) {
        let account = context.account.id.gg
        guard let services = self.services[account] else {
            return
        }
        let accountObject = context.account
        services.offlineDisposable.set((Signal<Never, NoError>.complete()
        |> delay(3.0, queue: Queue.mainQueue())
        |> then(Signal<Never, NoError> { subscriber in
            // Only if "online" is still kept off when the time comes.
            if GGGhostPresence.shared.resolvedOnline(true, account: account) {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            return GGGhostExplicitReads.sendOffline(account: accountObject).start(completed: {
                subscriber.putCompletion()
            })
        })).start())
    }

    /// Old exceptions stored a bare id without its namespace; the migration filed them as users.
    /// Once, against the account's database: if no such user exists but a group or channel with that
    /// id does, the entry moves there (the old code tried the three namespaces on every check).
    private static func resolveLegacyExceptions(context: AccountContext) {
        let account = context.account.id.gg
        let unresolved = GGGhostSettings.legacyUnresolvedPeers.value(for: account)
        if unresolved.isEmpty {
            return
        }
        let _ = (context.account.postbox.transaction { transaction -> [(PeerId, PeerId)] in
            var moves: [(PeerId, PeerId)] = []
            for rawId in unresolved {
                let id = PeerId.Id._internalFromInt64Value(rawId)
                let userId = PeerId(namespace: Namespaces.Peer.CloudUser, id: id)
                if transaction.getPeer(userId) != nil {
                    continue
                }
                for namespace in [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel] {
                    let peerId = PeerId(namespace: namespace, id: id)
                    if transaction.getPeer(peerId) != nil {
                        moves.append((userId, peerId))
                        break
                    }
                }
            }
            return moves
        }
        |> deliverOnMainQueue).start(next: { moves in
            if !moves.isEmpty {
                ggGhostUpdateExceptions(account: account) { exceptions in
                    for (from, to) in moves {
                        if let exception = exceptions.removeValue(forKey: from.ggGhostKey), exceptions[to.ggGhostKey] == nil {
                            exceptions[to.ggGhostKey] = exception
                        }
                    }
                }
            }
            GGGhostSettings.legacyUnresolvedPeers.set([], for: account)
        })
    }

    /// Re-applies «Прочитать локально» after the server reset a chat's read state (holes, state
    /// reset), so a chat read locally does not come back unread. Runs from the foreground scheduler.
    static func reapplyLocalReads(context: AccountContext) -> Signal<Never, NoError> {
        let account = context.account.id.gg
        let local = GGGhostReadLedger.shared.pendingKeys(account: account).local
        if local.isEmpty {
            return .complete()
        }
        return context.account.postbox.transaction { transaction -> [MessageIndex] in
            var result: [MessageIndex] = []
            for (key, maxId) in local {
                guard let peerKey = GGPeerKey(string: key) else {
                    continue
                }
                let peerId = PeerId(ggKey: peerKey)
                guard let state = transaction.getCombinedPeerReadState(peerId), state.count > 0 else {
                    continue
                }
                if let message = transaction.getMessage(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: maxId)) {
                    result.append(message.index)
                }
            }
            return result
        }
        |> mapToSignal { indices -> Signal<Never, NoError> in
            var signal: Signal<Never, NoError> = .complete()
            for index in indices {
                signal = signal |> then(context.engine.messages.applyMaxReadIndexInteractively(index: index) |> ignoreValues)
            }
            return signal
        }
    }
}
