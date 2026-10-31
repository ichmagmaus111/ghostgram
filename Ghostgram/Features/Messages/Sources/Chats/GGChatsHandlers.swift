import Foundation
import TelegramCore
import GGCore
import GGFeaturesShared

/// The «Чаты» section. Most of it is read directly by upstream forks through `GGMessagesPolicy`
/// (greeting sticker, channel button, pull to the next channel / topic, «Send as»); here are the
/// parts that go through hook points. «Безлимитные закрепы» — `GGPinnedChats`.
enum GGChatsHandlers {
    /// «История поиска без лимита» keeps up to this many recent chats (upstream: 20). Every entry is
    /// observed when the search opens, so the list is long but never unbounded.
    static let recentSearchCeiling = 200

    static func register() {
        GGLimitHooks.recentSearchLimit.register({ limit in
            if GGMessagesSettings.unlimitedSearchHistory.value {
                return max(limit, GGChatsHandlers.recentSearchCeiling)
            }
            return nil
        })
    }
}
