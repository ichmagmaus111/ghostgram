// The chat list screen's chrome: its container node after layout (search field, folder panel,
// Android-style buttons) and the navigation bar component after layout (gradient, snow, folder
// tabs placement). Here, not in ChatListUI, because ChatListNavigationBar lives in
// ChatListHeaderComponent, below ChatListUI. Row-level points: `GGChatListHooks` (ChatListUI).

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import AccountContext
import GGCore

public struct GGChatListContainerLayout {
    public let context: AccountContext
    /// ChatListControllerNode.
    public let node: ASDisplayNode
    public let layout: ContainerViewLayout
    public let navigationBarHeight: CGFloat
    public let transition: ContainedViewLayoutTransition
    /// Height Ghostgram's own bottom chrome takes above `layout.intrinsicInsets.bottom` (the
    /// «Папки внизу» strip with its gaps); 0 = none. Floating buttons go above it.
    public let bottomAccessoryHeight: CGFloat
    /// The list itself (the container of the chat list pages), a subview of `node.view`. Decorations
    /// of the list's content belong right above it — under the folder strip, search and the rest.
    public let contentView: UIView?
}

public struct GGChatListNavigationBarLayout {
    /// ChatListNavigationBar.View.
    public let view: UIView
    public let size: CGSize
    public let isAnimated: Bool
}

public enum GGChatListChromeHooks {
    /// Observer after the chat list container's layout (main thread).
    public static let containerDidLayout = GGHookPoint<(GGChatListContainerLayout) -> Void>("chatListChrome.containerDidLayout")

    /// Observer after the chat list navigation bar's layout (main thread, scroll path).
    public static let navigationBarDidLayout = GGHookPoint<(GGChatListNavigationBarLayout) -> Void>("chatListChrome.navigationBarDidLayout")

    /// Policy: `false` turns off "swipe right to record a story" on the chat list.
    public static let storyCameraSwipe = GGHookPoint<(AccountContext) -> Bool?>("chatListChrome.storyCameraSwipe")

    public static func notifyContainerDidLayout(context: AccountContext, node: ASDisplayNode, layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition, bottomAccessoryHeight: CGFloat = 0.0, contentView: UIView? = nil) {
        if GGChatListChromeHooks.containerDidLayout.isEmpty {
            return
        }
        let value = GGChatListContainerLayout(context: context, node: node, layout: layout, navigationBarHeight: navigationBarHeight, transition: transition, bottomAccessoryHeight: bottomAccessoryHeight, contentView: contentView)
        for handler in GGChatListChromeHooks.containerDidLayout.handlers {
            handler(value)
        }
    }

    public static func notifyNavigationBarDidLayout(view: UIView, size: CGSize, isAnimated: Bool) {
        if GGChatListChromeHooks.navigationBarDidLayout.isEmpty {
            return
        }
        let value = GGChatListNavigationBarLayout(view: view, size: size, isAnimated: isAnimated)
        for handler in GGChatListChromeHooks.navigationBarDidLayout.handlers {
            handler(value)
        }
    }

    public static func allowsStoryCameraSwipe(context: AccountContext) -> Bool {
        for handler in GGChatListChromeHooks.storyCameraSwipe.handlers {
            if let value = handler(context) {
                return value
            }
        }
        return true
    }
}
