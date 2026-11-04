// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// The account's Stars balance as features show it («Локальные звёзды»: a number shown on this
// device only). TON balances are never touched.

import Foundation
import SwiftSignalKit
import GGCore

public enum GGStarsHooks {
    /// Policy: the Stars balance shown instead of the real one (first non-nil wins; nil = the real
    /// one). Asked on the main queue on every publish of a Stars balance (`StarsContext`) and on
    /// every read of its `currentState`: answer from memory.
    public static let displayedBalance = GGHookPoint<(StarsAmount) -> StarsAmount?>("stars.displayedBalance")

    /// Every live Stars balance publishes its state again through `displayedBalance` — call after
    /// the shown balance changed. Any thread.
    public static func invalidate() {
        ggStarsBalanceInvalidations.putNext(Void())
    }
}

private let ggStarsBalanceInvalidations = ValuePipe<Void>()

/// GHOST hook target: `StarsContextImpl` (publish) and `StarsContext.currentState` — the state as
/// features show it. A TON state passes as it is.
func ggDisplayedStarsState(_ state: StarsContext.State, ton: Bool) -> StarsContext.State {
    if ton || GGStarsHooks.displayedBalance.isEmpty {
        return state
    }
    for handler in GGStarsHooks.displayedBalance.handlers {
        if let balance = handler(state.balance) {
            var state = state
            state.balance = balance
            return state
        }
    }
    return state
}

/// GHOST hook target: `StarsContextImpl.init`. `republish` runs on the main queue after
/// `GGStarsHooks.invalidate()`. Nil — nothing subscribed — for TON and while no feature changes
/// the shown balance.
func ggObserveStarsBalanceInvalidation(ton: Bool, _ republish: @escaping () -> Void) -> Disposable? {
    if ton || GGStarsHooks.displayedBalance.isEmpty {
        return nil
    }
    return ggStarsBalanceInvalidations.signal().start(next: { _ in
        Queue.mainQueue().async {
            republish()
        }
    })
}
