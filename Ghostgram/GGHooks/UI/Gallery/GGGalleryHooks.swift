// The media gallery: extra items in the «…» menu of photos and videos (copy photo, «read»
// for view-once, AirPlay, subtitles…), the footer after layout (buttons: photo translation) and
// the video items themselves (overlays over the playing video: subtitles). Call sites:
// ChatImageGalleryItem, UniversalVideoGalleryItem, ChatItemGalleryFooterContentNode (GalleryUI).

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import UniversalMediaPlayer
import GGCore

public enum GGGalleryItemKind {
    case image
    case video
}

public struct GGGalleryMenuContext {
    public let context: AccountContext
    public let message: Message?
    public let kind: GGGalleryItemKind
    /// The viewer keeps the media from being saved or copied (the message's or the chat's copy
    /// protection, paid media) — Telegram's own menu hides «Save» then.
    public let isCopyProtected: Bool
}

public struct GGGalleryFooterLayout {
    public let context: AccountContext
    public let message: Message?
    /// The footer's content node: add feature buttons here; they are laid out on every call.
    public let contentNode: ASDisplayNode
    public let width: CGFloat
    public let panelHeight: CGFloat
    public let transition: ContainedViewLayoutTransition
}

/// A gallery video item that got its player.
public struct GGGalleryVideoItem {
    public let context: AccountContext
    /// nil when the item is not a message (an avatar video, a web video).
    public let message: Message?
    /// The played video of the message (paid media, web page videos included), nil for other items.
    public let file: TelegramMediaFile?
    /// The item node: features add overlays above the video as its subnodes.
    public let itemNode: ASDisplayNode
    /// The player's status (position, rate, playing / paused).
    public let status: Signal<MediaPlayerStatus?, NoError>

    public init(context: AccountContext, message: Message?, file: TelegramMediaFile?, itemNode: ASDisplayNode, status: Signal<MediaPlayerStatus?, NoError>) {
        self.context = context
        self.message = message
        self.file = file
        self.itemNode = itemNode
        self.status = status
    }
}

/// Layout of a gallery video item.
public struct GGGalleryVideoItemLayout {
    public let itemNode: ASDisplayNode
    public let size: CGSize
    /// Bottom space taken by the gallery's own controls (footer, scrubber) plus the safe area;
    /// only the safe area while the controls are hidden.
    public let bottomInset: CGFloat
    public let transition: ContainedViewLayoutTransition

    public init(itemNode: ASDisplayNode, size: CGSize, bottomInset: CGFloat, transition: ContainedViewLayoutTransition) {
        self.itemNode = itemNode
        self.size = size
        self.bottomInset = bottomInset
        self.transition = transition
    }
}

public enum GGGalleryHooks {
    /// Providers of items appended to a gallery item's «…» menu.
    public static let menuItems = GGHookPoint<(GGGalleryMenuContext) -> [ContextMenuItem]>("gallery.menuItems")

    /// Observer after the footer's layout (main thread).
    public static let footerDidLayout = GGHookPoint<(GGGalleryFooterLayout) -> Void>("gallery.footerDidLayout")

    /// Policy (first non-nil wins): `false` = a vertical swipe on a gallery video dismisses it
    /// instead of starting picture-in-picture. nil = upstream.
    public static let swipeToPictureInPicture = GGHookPoint<(AccountContext) -> Bool?>("gallery.swipeToPictureInPicture")

    /// Observer: a video item got its player or was set up again with a new item (`setupItem`).
    /// Main thread. The same node is reused for the same video, so handlers keep their state on it.
    public static let videoItemDidLoad = GGHookPoint<(GGGalleryVideoItem) -> Void>("gallery.videoItemDidLoad")

    /// Observer: the video item was laid out, or its controls were shown / hidden. Main thread.
    public static let videoItemDidLayout = GGHookPoint<(GGGalleryVideoItemLayout) -> Void>("gallery.videoItemDidLayout")

    public static func notifyVideoItemDidLoad(context: AccountContext, message: Message?, file: TelegramMediaFile?, itemNode: ASDisplayNode, status: Signal<MediaPlayerStatus?, NoError>) {
        if GGGalleryHooks.videoItemDidLoad.isEmpty {
            return
        }
        let item = GGGalleryVideoItem(context: context, message: message, file: file, itemNode: itemNode, status: status)
        for handler in GGGalleryHooks.videoItemDidLoad.handlers {
            handler(item)
        }
    }

    public static func notifyVideoItemDidLayout(itemNode: ASDisplayNode, size: CGSize, bottomInset: CGFloat, transition: ContainedViewLayoutTransition) {
        if GGGalleryHooks.videoItemDidLayout.isEmpty {
            return
        }
        let layout = GGGalleryVideoItemLayout(itemNode: itemNode, size: size, bottomInset: bottomInset, transition: transition)
        for handler in GGGalleryHooks.videoItemDidLayout.handlers {
            handler(layout)
        }
    }

    public static func allowsSwipeToPictureInPicture(context: AccountContext) -> Bool {
        for handler in GGGalleryHooks.swipeToPictureInPicture.handlers {
            if let value = handler(context) {
                return value
            }
        }
        return true
    }

    public static func appendMenuItems(_ items: [ContextMenuItem], context: AccountContext, message: Message?, kind: GGGalleryItemKind, isCopyProtected: Bool) -> [ContextMenuItem] {
        if GGGalleryHooks.menuItems.isEmpty {
            return items
        }
        let menuContext = GGGalleryMenuContext(context: context, message: message, kind: kind, isCopyProtected: isCopyProtected)
        var extra: [ContextMenuItem] = []
        for handler in GGGalleryHooks.menuItems.handlers {
            extra.append(contentsOf: handler(menuContext))
        }
        if extra.isEmpty {
            return items
        }
        if items.isEmpty {
            return extra
        }
        return items + [.separator] + extra
    }

    public static func notifyFooterDidLayout(context: AccountContext, message: Message?, contentNode: ASDisplayNode, width: CGFloat, panelHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        if GGGalleryHooks.footerDidLayout.isEmpty {
            return
        }
        let layout = GGGalleryFooterLayout(context: context, message: message, contentNode: contentNode, width: width, panelHeight: panelHeight, transition: transition)
        for handler in GGGalleryHooks.footerDidLayout.handlers {
            handler(layout)
        }
    }
}
