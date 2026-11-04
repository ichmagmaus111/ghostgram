import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGFeaturesShared

/// «Подглядеть онлайн». Telegram shows someone's "last seen" only to those it shows yours to, so the
/// person is let into the "Last seen" rule for a moment, their profile is refreshed and the rule is
/// put back.
///
/// What changed is written to the account's settings and flushed to disk **before** the rule is
/// touched; the record is removed only after the rule is restored. A process killed in between
/// leaves the record, and the next start undoes exactly that change on top of the rule as it is then
/// (an edit the user made meanwhile survives). The rule is restored right after the profile is
/// fetched, without a fixed pause, so the person sees your status for as short as possible.
enum GGGhostPeekOnline {
    enum Result {
        case presence(EnginePeer.Presence?)
        case failed
    }

    private static func isAllowed(_ settings: SelectivePrivacySettings, peerId: PeerId, isContact: Bool) -> Bool {
        switch settings {
        case let .enableEveryone(disableFor):
            return disableFor[peerId] == nil
        case let .enableContacts(enableFor, disableFor, _, _):
            if disableFor[peerId] != nil {
                return false
            }
            return enableFor[peerId] != nil || isContact
        case let .disableEveryone(enableFor, _, _, _):
            return enableFor[peerId] != nil
        }
    }

    /// The rule with the peer let in, and what was changed.
    private static func opened(_ settings: SelectivePrivacySettings, peer: SelectivePrivacyPeer) -> (SelectivePrivacySettings, addedToAllowed: Bool, removedFromDisallowed: Bool) {
        let peerId = peer.peer.id
        switch settings {
        case let .enableEveryone(disableFor):
            var disableFor = disableFor
            let removed = disableFor.removeValue(forKey: peerId) != nil
            return (.enableEveryone(disableFor: disableFor), false, removed)
        case let .enableContacts(enableFor, disableFor, enableForPremium, enableForBots):
            var enableFor = enableFor
            var disableFor = disableFor
            let removed = disableFor.removeValue(forKey: peerId) != nil
            let added = enableFor[peerId] == nil
            enableFor[peerId] = peer
            return (.enableContacts(enableFor: enableFor, disableFor: disableFor, enableForPremium: enableForPremium, enableForBots: enableForBots), added, removed)
        case let .disableEveryone(enableFor, enableForCloseFriends, enableForPremium, enableForBots):
            var enableFor = enableFor
            let added = enableFor[peerId] == nil
            enableFor[peerId] = peer
            return (.disableEveryone(enableFor: enableFor, enableForCloseFriends: enableForCloseFriends, enableForPremium: enableForPremium, enableForBots: enableForBots), added, false)
        }
    }

    /// The rule with a recorded change undone.
    private static func undone(_ settings: SelectivePrivacySettings, record: GGGhostPeekRestore, peer: SelectivePrivacyPeer?) -> SelectivePrivacySettings {
        let peerId = PeerId(ggKey: record.peer)
        switch settings {
        case let .enableEveryone(disableFor):
            var disableFor = disableFor
            if record.removedFromDisallowed, let peer = peer {
                disableFor[peerId] = peer
            }
            return .enableEveryone(disableFor: disableFor)
        case let .enableContacts(enableFor, disableFor, enableForPremium, enableForBots):
            var enableFor = enableFor
            var disableFor = disableFor
            if record.addedToAllowed {
                enableFor.removeValue(forKey: peerId)
            }
            if record.removedFromDisallowed, let peer = peer {
                disableFor[peerId] = peer
            }
            return .enableContacts(enableFor: enableFor, disableFor: disableFor, enableForPremium: enableForPremium, enableForBots: enableForBots)
        case let .disableEveryone(enableFor, enableForCloseFriends, enableForPremium, enableForBots):
            var enableFor = enableFor
            if record.addedToAllowed {
                enableFor.removeValue(forKey: peerId)
            }
            return .disableEveryone(enableFor: enableFor, enableForCloseFriends: enableForCloseFriends, enableForPremium: enableForPremium, enableForBots: enableForBots)
        }
    }

    /// Sets the "Last seen" rule; one `Void` once the server has it. TelegramCore's update completes
    /// without a value, so anything chained with `mapToSignal` after it never ran: builds up to 199
    /// let the person in and neither fetched the status nor took them back out.
    private static func setPresenceRule(context: AccountContext, settings: SelectivePrivacySettings) -> Signal<Void, NoError> {
        return context.engine.privacy.updateSelectiveAccountPrivacySettings(type: .presence, settings: settings)
        |> then(.single(Void()))
    }

    /// Peeks run one at a time (main thread): a second one read while the first had the rule open
    /// would keep that opened rule as its "original" and restore it, letting the first person in for good.
    private static var isRunning = false
    private static let idle = ValuePromise<Bool>(true, ignoreRepeated: true)

    private static func fetchPresence(context: AccountContext, peerId: PeerId) -> Signal<Result, NoError> {
        // Some of its paths complete without a value: the status is read either way.
        return context.engine.peers.fetchAndUpdateCachedPeerData(peerId: peerId)
        |> then(.single(false))
        |> take(1)
        |> mapToSignal { _ -> Signal<Result, NoError> in
            return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Presence(id: peerId))
            |> map { presence -> Result in
                return .presence(presence)
            }
        }
    }

    /// Main thread.
    static func peek(context: AccountContext, peerId: PeerId) -> Signal<Result, NoError> {
        return GGGhostPeekOnline.idle.get()
        |> filter { $0 }
        |> take(1)
        |> deliverOnMainQueue
        |> mapToSignal { _ -> Signal<Result, NoError> in
            if GGGhostPeekOnline.isRunning {
                // Another waiter got here first in the same turn: wait for it too.
                return GGGhostPeekOnline.peek(context: context, peerId: peerId)
            }
            GGGhostPeekOnline.isRunning = true
            GGGhostPeekOnline.idle.set(false)
            let finish: () -> Void = {
                Queue.mainQueue().async {
                    if GGGhostPeekOnline.isRunning {
                        GGGhostPeekOnline.isRunning = false
                        GGGhostPeekOnline.idle.set(true)
                    }
                }
            }
            return GGGhostPeekOnline.performPeek(context: context, peerId: peerId)
            |> afterDisposed {
                finish()
            }
        }
    }

    /// Main thread.
    private static func performPeek(context: AccountContext, peerId: PeerId) -> Signal<Result, NoError> {
        let account = context.account.id.gg
        return combineLatest(
            context.engine.privacy.requestAccountPrivacySettings() |> take(1),
            context.engine.data.get(
                TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
                TelegramEngine.EngineData.Item.Peer.IsContact(id: peerId)
            )
        )
        |> deliverOnMainQueue
        |> mapToSignal { privacy, data -> Signal<Result, NoError> in
            let (peer, isContact) = data
            guard let peer = peer else {
                return .single(.failed)
            }
            let original = privacy.presence
            if GGGhostPeekOnline.isAllowed(original, peerId: peerId, isContact: isContact) {
                return GGGhostPeekOnline.fetchPresence(context: context, peerId: peerId)
            }
            let (opened, added, removed) = GGGhostPeekOnline.opened(original, peer: SelectivePrivacyPeer(peer: peer, participantCount: nil))
            GGGhostSettings.peekRestore.set(GGGhostPeekRestore(peer: peerId.ggKey, addedToAllowed: added, removedFromDisallowed: removed, date: Int32(Date().timeIntervalSince1970)), for: account)
            GGSettingsStore.shared.flush()
            let restore = GGGhostPeekOnline.setPresenceRule(context: context, settings: original)
            |> deliverOnMainQueue
            |> map { _ -> Void in
                GGGhostSettings.peekRestore.set(nil, for: account)
            }
            return GGGhostPeekOnline.setPresenceRule(context: context, settings: opened)
            |> mapToSignal { _ -> Signal<Result, NoError> in
                return GGGhostPeekOnline.fetchPresence(context: context, peerId: peerId)
            }
            |> mapToSignal { result -> Signal<Result, NoError> in
                return restore
                |> map { _ -> Result in
                    return result
                }
            }
        }
    }

    /// A peek that did not finish (the process was killed): undo its change on the current rule.
    static func recoverIfNeeded(context: AccountContext) -> Signal<Never, NoError> {
        let account = context.account.id.gg
        guard let record = GGGhostSettings.peekRestore.value(for: account) else {
            return .complete()
        }
        let peerId = PeerId(ggKey: record.peer)
        return combineLatest(
            context.engine.privacy.requestAccountPrivacySettings() |> take(1),
            context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        )
        |> mapToSignal { privacy, peer -> Signal<Never, NoError> in
            let current = privacy.presence
            let restored = GGGhostPeekOnline.undone(current, record: record, peer: peer.flatMap { SelectivePrivacyPeer(peer: $0, participantCount: nil) })
            let update: Signal<Void, NoError>
            if restored == current {
                update = .single(Void())
            } else {
                update = GGGhostPeekOnline.setPresenceRule(context: context, settings: restored)
            }
            return update
            |> deliverOnMainQueue
            |> mapToSignal { _ -> Signal<Never, NoError> in
                GGGhostSettings.peekRestore.set(nil, for: account)
                return .complete()
            }
        }
    }
}
