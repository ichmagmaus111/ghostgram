import Foundation
import UIKit
import ObjectiveC
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ContextUI
import AvatarNode
import ChatListUI
import ChatListTitleView
import ChatListHeaderComponent
import GGCore
import GGHooks

/// Chat list (chatlist_tweaks, SG-B1…B5, square_avatars): every handler answers
/// from `InterfaceSnapshots` or one setting read; nothing observes anything per cell.
enum GGChatListFeature {
    /// Row size choices (percent of Telegram's).
    static let rowScaleOptions = ["80", "90", "100", "110", "120", "130"]
    static let avatarScaleOptions = ["70", "80", "90", "100", "110", "120"]

    /// Key of the «Delete» swipe action (ChatListItem's private `RevealOptionKey.delete`).
    private static let deleteRevealOptionKey: Int32 = 4

    static func register() {
        GGChatListStyleHooks.rowStyle.register({
            return InterfaceSnapshots.shared.current.rowStyle
        })
        // The proxy sponsor's channel leaves the list (asked where the promoted chat is added).
        GGChatListHooks.hidesPromoChat.register({ _, isProxy in
            return isProxy && InterfaceSettings.hideProxySponsor.value
        })
        GGAvatarHooks.shape.register({
            return InterfaceSnapshots.shared.current.avatarShape
        })
        GGChatListTitleHooks.style.register({
            return InterfaceSnapshots.shared.current.titleStyle
        })
        GGThemeHooks.presentationData.register({ presentationData, _ in
            return InterfaceTheme.transform(presentationData)
        }, order: 100)

        // Hidden message previews: all chats or the chosen ones of this account.
        GGChatListHooks.previewText.register({ row in
            guard InterfaceSettings.hidePreview.value, let peer = row.peer else {
                return nil
            }
            if InterfaceSettings.hidePreviewScope.value == "selected" {
                let selected = InterfaceSettings.hidePreviewPeers.value(for: row.context.account.id.gg)
                if !selected.contains(peer.id.ggKey) {
                    return nil
                }
            }
            return NSAttributedString(string: "")
        })

        // SG-B3: one honest choice instead of two inverted switches.
        GGChatListHooks.revealOptions.register({ options, _ in
            switch InterfaceSettings.swipeActions.value {
            case "none":
                return []
            case "noDelete":
                return options.filter { $0.key != GGChatListFeature.deleteRevealOptionKey }
            default:
                return options
            }
        })

        // SG-B4.
        GGChatListChromeHooks.storyCameraSwipe.register({ _ in
            return InterfaceSettings.disableStoryCameraSwipe.value ? false : nil
        })

        // SG-B5: the strip follows the setting live (the source is combined with its signal).
        GGChatListHooks.storySubscriptions.register({ signal, _ in
            return combineLatest(signal, InterfaceSettings.hideStories.signal)
            |> map { subscriptions, hideStories -> EngineStorySubscriptions in
                if hideStories {
                    return EngineStorySubscriptions(accountItem: nil, items: [], hasMoreToken: nil)
                }
                return subscriptions
            }
        })

        GGChatListStyleHooks.hidesSearchField.register({ _ in
            return InterfaceSnapshots.shared.current.hideSearchField
        })

        GGChatListSearchHooks.localPeers.register({ signal, query, context in
            return GGChatListFeature.searchById(signal, query: query, context: context)
        })

        GGChatListStyleHooks.decorateRow.register({ decoration in
            GGSenderAvatarDecoration.apply(decoration)
        })

        GGHiddenTabBarSettingsButton.register()
    }

    /// A numeric query also finds peers this device already knows by their public id:
    /// `123456789` → user, `-1001234567890` → channel / supergroup, `-123456789` → legacy group.
    /// Server lookup by a bare id is not possible (it needs an access hash).
    private static func searchById(_ signal: Signal<[EngineRenderedPeer], NoError>, query: String, context: AccountContext) -> Signal<[EngineRenderedPeer], NoError> {
        if !InterfaceSettings.searchById.value {
            return signal
        }
        let candidates = GGChatListFeature.peerIdCandidates(query)
        if candidates.isEmpty {
            return signal
        }
        let byId = context.engine.data.get(EngineDataMap(candidates.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
        |> map { peers -> [EngineRenderedPeer] in
            return candidates.compactMap { peerId -> EngineRenderedPeer? in
                guard let maybePeer = peers[peerId], let peer = maybePeer else {
                    return nil
                }
                return EngineRenderedPeer(peer: peer)
            }
        }
        return combineLatest(signal, byId)
        |> map { found, byId -> [EngineRenderedPeer] in
            var result = byId
            let known = Set(byId.map { $0.peerId })
            for peer in found where !known.contains(peer.peerId) {
                result.append(peer)
            }
            return result
        }
    }

    static func peerIdCandidates(_ query: String) -> [EnginePeer.Id] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Int64(trimmed), raw != 0 else {
            return []
        }
        if raw > 0 {
            return [EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(raw))]
        }
        if raw <= -1_000_000_000_000 {
            let channelId = -raw - 1_000_000_000_000
            return [EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(channelId))]
        }
        return [EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(-raw))]
    }
}

/// The sender's avatar before the author line of a group row (exteraGram's mini avatars). One
/// AvatarNode per row node, created on first use; the row reserved the space (`senderAvatarSize`).
private var ggSenderAvatarKey: UInt8 = 0

enum GGSenderAvatarDecoration {
    static func apply(_ decoration: GGChatListRowDecoration) {
        let existing = objc_getAssociatedObject(decoration.node, &ggSenderAvatarKey) as? AvatarNode
        guard decoration.style.senderAvatarSize > 0.0, let author = decoration.author, let authorFrame = decoration.authorFrame else {
            existing?.isHidden = true
            return
        }
        let avatarNode: AvatarNode
        if let existing {
            avatarNode = existing
        } else {
            avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 8.0))
            avatarNode.isUserInteractionEnabled = false
            decoration.node.addSubnode(avatarNode)
            objc_setAssociatedObject(decoration.node, &ggSenderAvatarKey, avatarNode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let size = decoration.style.senderAvatarSize
        avatarNode.isHidden = false
        avatarNode.frame = CGRect(x: authorFrame.minX - size - 4.0, y: floor(authorFrame.midY - size * 0.5), width: size, height: size)
        // The shape is the layer's corners, from the same snapshot as every other avatar: the
        // AvatarNode draws an unclipped square. Mapped through its own clip style the 18 pt avatars
        // still came out as circles next to rounded-square rows (build 188).
        let cornerRadius = GGSenderAvatarDecoration.cornerRadius(side: size)
        if avatarNode.layer.cornerRadius != cornerRadius || !avatarNode.clipsToBounds {
            avatarNode.clipsToBounds = true
            avatarNode.layer.cornerRadius = cornerRadius
        }
        avatarNode.setPeer(context: decoration.context, theme: decoration.theme, peer: author, clipStyle: .none, displayDimensions: CGSize(width: size, height: size))
    }

    /// Telegram's circle, or the rounded square of «Скругление углов» (`ggAvatarRoundedRectRadius`).
    static func cornerRadius(side: CGFloat) -> CGFloat {
        let shape = InterfaceSnapshots.shared.current.avatarShape
        if !shape.squareAvatars {
            return side * 0.5
        }
        return min(floor(side * 0.5), ceil(side * shape.cornerFraction))
    }
}
