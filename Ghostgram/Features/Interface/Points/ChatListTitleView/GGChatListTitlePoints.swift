// Compiled into ChatListTitleView (filegroup //Ghostgram/Features/Interface:ChatListTitleViewPointSources).
// Owner: W2-5. The lowest module of the chat list chrome W2-5 owns, so the points here serve the
// title (connection text), the header component and the chat list search
// (ChatListUI, ChatListHeaderComponent and StoryPeerListComponent all depend on this module).

import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import GGCore

/// How the chat list title looks. `.upstream` = Telegram's.
public struct GGChatListTitleStyle: Equatable {
    /// While connecting / updating only the spinner is shown, no «Соединение…» text.
    public var hidesConnectionText: Bool

    public init(hidesConnectionText: Bool) {
        self.hidesConnectionText = hidesConnectionText
    }

    public static let upstream = GGChatListTitleStyle(hidesConnectionText: false)
}

public enum GGChatListTitleHooks {
    /// Provider of the title style (first registered wins). Main thread, on title updates and layout.
    public static let style = GGHookPoint<() -> GGChatListTitleStyle>("chatListTitle.style")
}

public func ggChatListTitleStyle() -> GGChatListTitleStyle {
    if GGChatListTitleHooks.style.isEmpty {
        return .upstream
    }
    return GGChatListTitleHooks.style.handlers[0]()
}

/// The text the title shows for a network status.
public func ggChatListTitleText(_ title: NetworkStatusTitle) -> String {
    if GGChatListTitleHooks.style.isEmpty {
        return title.text
    }
    if title.activity && ggChatListTitleStyle().hidesConnectionText {
        return ""
    }
    return title.text
}

public enum GGChatListSearchHooks {
    /// Transformer of the local peers the chat list search shows for a query (search by numeric
    /// id). Called once per query, off the main thread is fine: return signals, do not block.
    public static let localPeers = GGHookPoint<(Signal<[EngineRenderedPeer], NoError>, String, AccountContext) -> Signal<[EngineRenderedPeer], NoError>>("chatListSearch.localPeers")
}

/// Call site helper for ChatListSearchListPaneNode.
public func ggChatListSearchLocalPeers(_ signal: Signal<[EngineRenderedPeer], NoError>, query: String, context: AccountContext) -> Signal<[EngineRenderedPeer], NoError> {
    if GGChatListSearchHooks.localPeers.isEmpty {
        return signal
    }
    var result = signal
    for handler in GGChatListSearchHooks.localPeers.handlers {
        result = handler(result, query, context)
    }
    return result
}
