// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// Account lifecycle points. Called from Account.swift / AccountManager.swift.

import Foundation
import Postbox
import SwiftSignalKit
import GGCore

/// What a feature learns when an account starts in this process (app or extension).
public struct GGAccountStartContext {
    public let id: AccountRecordId
    public let peerId: PeerId
    public let basePath: String
    /// True for accounts started only to finish a logout or for a short extension task.
    public let isSupplementary: Bool
    public let postbox: Postbox
    public let network: Network
}

public enum GGAccountHooks {
    /// Observer. An account's state machinery is about to start; its Ghostgram settings
    /// (`GGAccountSetting`) are already loaded. Runs on the thread that creates the account.
    public static let accountWillStart = GGHookPoint<(GGAccountStartContext) -> Void>("account.willStart")

    /// Observer. The account is being removed (logged out); its directory is deleted afterwards.
    public static let accountWillBeRemoved = GGHookPoint<(AccountRecordId) -> Void>("account.willBeRemoved")

    /// The record id of the account whose own peer is `accountPeerId`, once it started in this
    /// process. Lets handlers that only get an account peer id (Core points) reach
    /// account-scoped settings: `GGAccountSetting.value(for: id.gg)`.
    public static func accountId(forAccountPeerId accountPeerId: PeerId) -> AccountRecordId? {
        return ggAccountIdsByPeerId.with { $0[accountPeerId] }
    }
}

private let ggAccountIdsByPeerId = Atomic<[PeerId: AccountRecordId]>(value: [:])

/// GHOST hook target: first statement of `Account.init`, before the account's managers start.
func ggAccountWillStart(id: AccountRecordId, basePath: String, peerId: PeerId, supplementary: Bool, postbox: Postbox, network: Network) {
    // GGCore bridge (W1-1): loads <basePath>/ghostgram/settings.json and runs account migrations.
    ggCoreAccountDidLoad(id: id, basePath: basePath)
    // Then the migrations of old data keyed by the account's peer: before the handlers below, which
    // may already read what they moved (fake gifts).
    ggCoreAccountPeerDidLoad(id: id, peerId: peerId)
    let _ = ggAccountIdsByPeerId.modify { current in
        var current = current
        current[peerId] = id
        return current
    }
    if GGAccountHooks.accountWillStart.isEmpty {
        return
    }
    let context = GGAccountStartContext(id: id, peerId: peerId, basePath: basePath, isSupplementary: supplementary, postbox: postbox, network: network)
    for handler in GGAccountHooks.accountWillStart.handlers {
        handler(context)
    }
}

/// GHOST hook target: `standaloneStateManager` (notification service) — no `Account` object
/// exists there, so the account's settings are loaded here, before its network starts.
func ggStandaloneAccountWillStart(id: AccountRecordId, basePath: String, peerId: PeerId) {
    ggCoreAccountDidLoad(id: id, basePath: basePath)
    ggCoreAccountPeerDidLoad(id: id, peerId: peerId)
    let _ = ggAccountIdsByPeerId.modify { current in
        var current = current
        current[peerId] = id
        return current
    }
}

/// GHOST hook target: an account record is about to be removed for good (logout).
func ggAccountWillBeRemoved(id: AccountRecordId) {
    for handler in GGAccountHooks.accountWillBeRemoved.handlers {
        handler(id)
    }
    let _ = ggAccountIdsByPeerId.modify { current in
        return current.filter { $0.value != id }
    }
    ggCoreAccountWillBeRemoved(id: id)
}

/// The account peer id stored in the account's own Postbox state, for points that are called
/// without one (autoremove timers, interactive deletions without a state manager).
func ggAccountPeerId(transaction: Transaction) -> PeerId? {
    return (transaction.getState() as? AuthorizedAccountState)?.peerId
}
