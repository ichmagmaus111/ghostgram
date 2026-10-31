// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// How many accounts can be signed in at once. It is a client-side UI limit only (the server does
// not count the accounts of a device), and upstream spells it in several places: the constants of
// AccountUtils (settings search, the delete-account options), literal 3 / 4 in the three
// "Add account" actions (Settings, logout options, delete-account options) and the Premium limit
// screen. Every one of them asks here, so a feature sets the limit once.
// Callers only need `import TelegramCore`.

import Foundation
import GGCore

extension GGLimitHooks {
    /// Upstream limits: AccountUtils' `maximumNumberOfAccounts` and `maximumPremiumNumberOfAccounts`.
    public static let upstreamAccountLimit: Int = 3
    public static let upstreamPremiumAccountLimit: Int = 4

    /// Policy: how many accounts can be signed in at once. The handler gets the upstream value
    /// (3, or 4 when one of the signed-in accounts has Premium) and returns the limit, or nil to
    /// keep it. The first non-nil answer wins; the point only raises the limit. Asked on the main
    /// thread and in signal maps: answer from memory.
    public static let accountLimit = GGHookPoint<(Int) -> Int?>("limits.accounts")

    /// The limit for an upstream value; `upstream` itself while the point is empty.
    public static func maximumNumberOfAccounts(upstream: Int) -> Int {
        if GGLimitHooks.accountLimit.isEmpty {
            return upstream
        }
        for handler in GGLimitHooks.accountLimit.handlers {
            if let value = handler(upstream) {
                return max(upstream, value)
            }
        }
        return upstream
    }

    /// The limit without / with Premium among the signed-in accounts.
    public static func maximumNumberOfAccounts(isPremium: Bool) -> Int {
        return GGLimitHooks.maximumNumberOfAccounts(upstream: isPremium ? GGLimitHooks.upstreamPremiumAccountLimit : GGLimitHooks.upstreamAccountLimit)
    }

    /// `false` once a feature made the limit the same with and without Premium: then the Premium
    /// offer for accounts and Telegram's "three / four accounts" texts are wrong and are replaced.
    public static var premiumRaisesAccountLimit: Bool {
        return GGLimitHooks.maximumNumberOfAccounts(isPremium: true) > GGLimitHooks.maximumNumberOfAccounts(isPremium: false)
    }
}
