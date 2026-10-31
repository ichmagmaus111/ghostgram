// Compiled into TopMessageReactions (filegroup //Ghostgram/Features/Interface:TopMessageReactionsPointSources).
// Owner: W2-5 («Свои недавние реакции»).

import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import GGCore

public enum GGRecentReactionsHooks {
    /// Transformer of the "top" reactions a message's reaction panel starts with (Telegram's
    /// cloud list). Called once per panel: return signals, keep resolved files cached.
    public static let topReactions = GGHookPoint<(Signal<[RecentReactionItem], NoError>, AccountContext, EngineRawMessage) -> Signal<[RecentReactionItem], NoError>>("reactions.top")
}

func ggTopReactions(_ signal: Signal<[RecentReactionItem], NoError>, context: AccountContext, message: EngineRawMessage) -> Signal<[RecentReactionItem], NoError> {
    if GGRecentReactionsHooks.topReactions.isEmpty {
        return signal
    }
    var result = signal
    for handler in GGRecentReactionsHooks.topReactions.handlers {
        result = handler(result, context, message)
    }
    return result
}
