import Foundation
import UIKit
import ObjectiveC
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ComponentFlow
import ChatListUI
import UndoUI
import LocalizedPeerData
import GGCore
import GGHooks
import GGNickBadgeSlot

// Where the badge is drawn. Every place reads the same in-memory table through one provider:
//   - chat header, contacts, peer lists — `GGNickBadgeSlot` lines in those files;
//   - chat list rows — `GGChatListHooks.rowDidLayout`;
//   - profile header — `GGPeerInfoHooks.headerDidLayout`;
//   - the author line of a bubble — `GGMessageDecorationHooks.authorBadge`.
// A tap shows the bulletin "<name> supports GCONNECT development" with "More".

enum GGNickBadgeSlots {
    /// Line heights of the places (points): a badge is a little smaller than the name's capitals.
    static let chatListHeight: CGFloat = 16.0
    static let bubbleHeight: CGFloat = 15.0
    static let bulletinHeight: CGFloat = 32.0

    static func register() {
        GGNickBadgeSlot.provider.register({ request in
            guard GGNickBadgeSettings.isEnabled.value, let badge = GGNickBadgeService.shared.badge(for: request.peerId) else {
                return nil
            }
            let context = request.context
            let peerId = request.peerId
            return GGNickBadgeContent(image: GGNickBadgeArt.image(for: badge, height: request.height), tap: { _ in
                ggPresentNickBadgeBulletin(context: context, peerId: peerId)
            })
        })

        GGChatListHooks.rowDidLayout.register({ layout in
            GGNickBadgeSlots.layoutChatListRow(layout)
        })
        // The row's title leaves room for the badge, so a long name is cut before it.
        GGChatListHooks.titleAccessoryWidth.register({ row in
            guard let peerId = GGNickBadgeSlots.chatListBadgePeerId(row.peer, context: row.context) else {
                return 0.0
            }
            return GGNickBadgeSlot.reservedWidth(peerId: peerId, context: row.context, height: GGNickBadgeSlots.chatListHeight)
        })

        GGPeerInfoHooks.headerDidLayout.register({ header in
            GGNickBadgeSlots.layoutProfileHeader(header)
        })
        // The centered name leaves room for the badge, so the name with the badge stays centered.
        GGPeerInfoHooks.titleTrailingInset.register({ request in
            guard case .user = request.peer else {
                return 0.0
            }
            return GGNickBadgeSlot.reservedWidth(peerId: request.peer.id, context: request.context, height: GGNickBadgeSlots.profileHeight(titleHeight: request.titleHeight))
        })

        GGMessageDecorationHooks.authorBadge.register({ message, context in
            guard GGNickBadgeSettings.isEnabled.value, let author = message.author, author.id.namespace == Namespaces.Peer.CloudUser else {
                return nil
            }
            guard let badge = GGNickBadgeService.shared.badge(for: author.id) else {
                return nil
            }
            let image = GGNickBadgeArt.image(for: badge, height: GGNickBadgeSlots.bubbleHeight)
            let peerId = author.id
            return GGMessageAuthorBadge(image: image, size: image.size, tap: {
                ggPresentNickBadgeBulletin(context: context, peerId: peerId)
            })
        })

        GGLifecycleHooks.applicationDidBecomeActive.register({
            GGNickBadgeService.shared.applicationDidBecomeActive()
        })
        GGLifecycleHooks.applicationWillResignActive.register({
            GGNickBadgeService.shared.applicationWillResignActive()
        })
    }

    // MARK: - Chat list

    private static var chatListBadgeKey: UInt8 = 0

    /// Whose badge a chat list row shows: the user of a private or secret chat. Not on Saved
    /// Messages: that row is titled after the chat, not after a person.
    static func chatListBadgePeerId(_ peer: EnginePeer?, context: AccountContext) -> EnginePeer.Id? {
        switch peer {
        case let .user(user)?:
            return user.id == context.account.peerId ? nil : user.id
        case let .secretChat(secretChat)?:
            return secretChat.regularPeerId
        default:
            return nil
        }
    }

    /// After the title and the icons that follow it (emoji status, verification, muted, hidden), in
    /// the title's own container. The row reserves room for it (`titleAccessoryWidth`); a badge that
    /// arrives after the row was laid out and does not fit before the date hides instead of
    /// covering it, until the row is laid out again.
    private static func layoutChatListRow(_ layout: GGChatListRowLayout) {
        guard let node = layout.node as? ChatListItemNode else {
            return
        }
        var badgeView = objc_getAssociatedObject(node, &GGNickBadgeSlots.chatListBadgeKey) as? GGNickBadgeView
        let titleNode = node.titleNode
        let peerId = GGNickBadgeSlots.chatListBadgePeerId(layout.peer, context: layout.context)
        guard let container = titleNode.supernode?.view, peerId != nil || badgeView != nil else {
            return
        }
        let titleFrame = titleNode.frame
        var originX = titleFrame.maxX
        var limitX = container.bounds.width
        for sublayer in container.layer.sublayers ?? [] {
            if sublayer === titleNode.layer || sublayer === badgeView?.layer || sublayer.isHidden || sublayer.opacity <= 0.0 {
                continue
            }
            let frame = sublayer.frame
            if frame.minX < titleFrame.maxX - 1.0 || frame.midY < titleFrame.minY || frame.midY > titleFrame.maxY {
                continue
            }
            if sublayer.asyncdisplaykit_node is TextNode {
                // The date (or a label) on the same line: the badge must end before it.
                limitX = min(limitX, frame.minX)
                continue
            }
            let isTitleIcon = sublayer.delegate is ComponentHostView<Empty> || sublayer.asyncdisplaykit_node is ASImageNode || sublayer.delegate is UIImageView
            if isTitleIcon && frame.minX <= titleFrame.maxX + 96.0 && frame.height <= titleFrame.height + 12.0 {
                originX = max(originX, frame.maxX)
            }
        }
        // The limit stays with the view: a badge drawn later (the table read after this layout,
        // `refreshVisibleSlots`) hides instead of covering the date too.
        GGNickBadgeSlot.update(&badgeView, peerId: peerId, context: layout.context, container: container, originX: originX, centerY: titleFrame.midY, height: GGNickBadgeSlots.chatListHeight, maxX: limitX - 4.0)
        objc_setAssociatedObject(node, &GGNickBadgeSlots.chatListBadgeKey, badgeView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - Profile header

    private static var headerBadgeKey: UInt8 = 0

    /// Badge height in the profile header for a name line of `titleHeight`.
    static func profileHeight(titleHeight: CGFloat) -> CGFloat {
        return max(14.0, floor(titleHeight * 0.72))
    }

    /// The header draws the name twice (the regular and the expanded state, `titleStateViews`); each
    /// state's view carries the name's icons (emoji status, premium / verification). The badge goes
    /// after them in both, so it scales and fades with the name; the header keeps the regular name
    /// centered with the badge (`titleTrailingInset`).
    private static func layoutProfileHeader(_ header: GGPeerInfoHeader) {
        var peerId: EnginePeer.Id?
        if let peer = header.peer, case .user = peer {
            peerId = peer.id
        }
        for titleView in header.titleStateViews {
            var badgeView = objc_getAssociatedObject(titleView, &GGNickBadgeSlots.headerBadgeKey) as? GGNickBadgeView
            if peerId == nil && badgeView == nil {
                continue
            }
            var originX = titleView.bounds.width
            for subview in titleView.subviews where subview is ComponentHostView<Empty> {
                if subview.isHidden || subview.alpha <= 0.0 || subview.frame.width <= 0.0 || subview.frame.maxX <= 0.0 {
                    continue
                }
                originX = max(originX, subview.frame.maxX)
            }
            let height = GGNickBadgeSlots.profileHeight(titleHeight: titleView.bounds.height)
            GGNickBadgeSlot.update(&badgeView, peerId: peerId, context: header.context, container: titleView, originX: originX, centerY: titleView.bounds.midY, height: height)
            objc_setAssociatedObject(titleView, &GGNickBadgeSlots.headerBadgeKey, badgeView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

// MARK: - Bulletin

/// What a tap on a badge says. The owner's own line wins; `{name}` in it is the wearer's name.
func ggNickBadgeCaption(badge: GGNickBadge, name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName = trimmed.isEmpty ? GGStrings.NickBadge.Bulletin.someone : trimmed
    if let text = badge.text {
        return text.replacingOccurrences(of: "{name}", with: resolvedName)
    }
    switch badge.kind {
    case .team:
        return GGStrings.NickBadge.Bulletin.team(name: resolvedName)
    case .supporter, .custom:
        return GGStrings.NickBadge.Bulletin.supporter(name: resolvedName)
    }
}

/// The bulletin parses markdown; names and the owner's line are user text and must stay plain. A
/// word joiner between markup characters keeps them from forming `**`, `__` or `](`.
func ggNickBadgePlainMarkdown(_ text: String) -> String {
    let markup: Set<Character> = ["*", "_", "[", "]", "(", ")", "`", "~", "|"]
    var result = ""
    result.reserveCapacity(text.count)
    var previousWasMarkup = false
    for character in text {
        let isMarkup = markup.contains(character)
        if isMarkup && previousWasMarkup {
            result.append("\u{2060}")
        }
        result.append(character)
        previousWasMarkup = isMarkup
    }
    return result
}

func ggPresentNickBadgeBulletin(context: AccountContext, peerId: EnginePeer.Id) {
    guard let badge = GGNickBadgeService.shared.badge(for: peerId) else {
        return
    }
    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
    |> deliverOnMainQueue).start(next: { peer in
        guard let (navigationController, topController) = ggProfileExportTopController(context: context) else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let name = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? ""
        let text = ggNickBadgePlainMarkdown(ggNickBadgeCaption(badge: badge, name: name))
        let image = GGNickBadgeArt.image(for: badge, height: GGNickBadgeSlots.bulletinHeight)
        topController.present(UndoOverlayController(
            presentationData: presentationData,
            content: .image(image: image, title: nil, text: text, round: false, undoText: GGStrings.NickBadge.Bulletin.more),
            elevatedLayout: false,
            action: { [weak navigationController] action in
                if case .undo = action, let navigationController = navigationController {
                    navigationController.pushViewController(ggMakeNickBadgeScreen(context: context))
                }
                return true
            }
        ), in: .current)
    })
}
