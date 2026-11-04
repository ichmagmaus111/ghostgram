import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import WallpaperBackgroundNode
import AvatarNode
import TextFormat
import LocalizedPeerData
import GGHooks
import ComponentFlow
import GlassBackgroundComponent
import EmojiStatusComponent
import ChatListTitleView

/// Mini chat on the user's real wallpaper with real bubbles
/// (`SharedAccountContext.makeChatMessagePreviewItem`), the same renderer the chat uses.
/// Built on the main queue: the wallpaper node and the message nodes must not be created off main.
final class GGMiniChatPreviewItem: ListViewItem, ItemListItem {
    let context: AccountContext
    let presentationData: PresentationData
    let content: GGMiniChatContent
    let accountPeer: EnginePeer?
    let height: CGFloat
    let sectionId: ItemListSectionId
    /// The context of the preview (its scope set): overlays are updated with it.
    let menuContext: GGMenuContext
    /// The feature's draft state around the bubbles' layout (`GGMiniChatConfiguration.draftScope`).
    let draftScope: (() -> Void) -> Void
    let makeOverlays: ((GGMenuContext) -> [GGMiniChatOverlay])?

    init(context: AccountContext, presentationData: PresentationData, content: GGMiniChatContent, accountPeer: EnginePeer?, height: CGFloat, sectionId: ItemListSectionId, menuContext: GGMenuContext, draftScope: @escaping (() -> Void) -> Void, makeOverlays: ((GGMenuContext) -> [GGMiniChatOverlay])?) {
        self.context = context
        self.presentationData = presentationData
        self.content = content
        self.accountPeer = accountPeer
        self.height = height
        self.sectionId = sectionId
        self.menuContext = menuContext
        self.draftScope = draftScope
        self.makeOverlays = makeOverlays
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = GGMiniChatPreviewItemNode()
            // The message items are built and laid out synchronously here (main queue), so the
            // feature's draft state covers their theme images and layout hooks.
            var result: (ListViewItemNodeLayout, () -> Void)?
            self.draftScope {
                result = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            }
            guard let (layout, apply) = result else {
                return
            }

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            completion(node, {
                return (nil, { _ in apply() })
            })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? GGMiniChatPreviewItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            var result: (ListViewItemNodeLayout, () -> Void)?
            self.draftScope {
                result = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            }
            guard let (layout, apply) = result else {
                return
            }
            completion(layout, { _ in
                apply()
            })
        }
    }
}

private let ggMiniChatVerticalPadding: CGFloat = 11.0
private let ggMiniChatHeaderHeight: CGFloat = 52.0
private let ggMiniChatHeaderPillSize: CGFloat = 40.0
private let ggMiniChatHeaderSideInset: CGFloat = 10.0
/// The avatar sits in its glass circle as in the chat (44 pt glass, 38 pt avatar there).
private let ggMiniChatHeaderAvatarInset: CGFloat = 3.0
private let ggMiniChatHeaderStatusIconSize: CGFloat = 20.0
private let ggMiniChatHeaderStatusIconSpacing: CGFloat = 3.0

/// «Скрыть эмодзи-статусы» of the chat list (its row style); off — the status shows, as in the chat.
private func ggMiniChatHidesEmojiStatus() -> Bool {
    if GGChatListStyleHooks.rowStyle.isEmpty {
        return false
    }
    return GGChatListStyleHooks.rowStyle.handlers[0]().hidesEmojiStatus
}

func ggPreviewTimestamp(ageSeconds: Int32) -> Int32 {
    return Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970) - ageSeconds
}

func ggDemoUser(id: Int64, name: String) -> TelegramUser {
    return TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(id)), accessHash: nil, firstName: name, lastName: "", username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}

/// The chat's glass back arrow (`glassBackArrowImage` of NavigationBarImpl: a 2 pt round-capped
/// chevron in a 44 pt square), drawn into a `side` square in the chat's button color.
func ggMiniChatBackArrowImage(side: CGFloat, color: UIColor) -> UIImage? {
    let scale = side / 44.0
    return generateImage(CGSize(width: side, height: side), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.0)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let topRightPoint = CGPoint(x: 24.6 * scale, y: 14.0 * scale)
        context.move(to: topRightPoint)
        context.addLine(to: CGPoint(x: 17.0 * scale, y: size.height * 0.5))
        context.addLine(to: CGPoint(x: topRightPoint.x, y: size.height - topRightPoint.y))
        context.strokePath()
    })
}

/// The bubble's status line (date, checks) in `node`'s coordinates. ChatMessageDateAndStatusNode is
/// not a dependency of this module, so it is found by its class name.
///
/// The node is laid out over the whole line and right-aligns what it draws (its `leftOffset`), so
/// the line is what its visible parts cover — its own frame starts at the bubble's left edge.
private func ggStatusLineFrame(in node: ASDisplayNode) -> CGRect? {
    var stack: [ASDisplayNode] = node.subnodes ?? []
    while let current = stack.popLast() {
        if String(describing: type(of: current)) == "ChatMessageDateAndStatusNode" {
            if current.bounds.width <= 0.0 || current.isHidden {
                return nil
            }
            var visibleFrame: CGRect?
            for part in current.subnodes ?? [] {
                let frame = part.frame
                // Backgrounds (media status) span the whole node; they are not the line.
                if part.isHidden || part.alpha <= 0.01 || frame.width <= 0.0 || frame.height <= 0.0 || frame.width >= current.bounds.width - 1.0 {
                    continue
                }
                visibleFrame = visibleFrame.flatMap { $0.union(frame) } ?? frame
            }
            return current.layer.convert(visibleFrame ?? current.bounds, to: node.layer)
        }
        stack.append(contentsOf: current.subnodes ?? [])
    }
    return nil
}

/// The real bubbles of `messages`, in the given order, built as the chat builds them
/// (`makeChatMessagePreviewItem`): a demo peer and the account's side, replies, quotes, «edited»,
/// pending and unread states. Main thread (the wallpaper node and the theme images are main-only).
func ggPreviewMessageItems(context: AccountContext, presentationData: PresentationData, messages: [GGPreviewMessage], backgroundNode: WallpaperBackgroundNode?) -> [ListViewItem] {
    let peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(1))
    let otherPeerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(2))
    var items: [ListViewItem] = []
    for message in messages {
        var peers = EngineSimpleDictionary<EnginePeer.Id, EngineRawPeer>()
        var associatedMessages = EngineSimpleDictionary<EngineMessage.Id, EngineRawMessage>()
        let timestamp = ggPreviewTimestamp(ageSeconds: message.ageSeconds)

        var attributes: [EngineMessage.Attribute] = []
        let replyMessageId = EngineMessage.Id(peerId: peerId, namespace: 0, id: 1000 &+ message.id)
        if let reply = message.reply {
            let replyAuthor = ggDemoUser(id: 1, name: reply.author)
            peers[peerId] = replyAuthor
            associatedMessages[replyMessageId] = EngineRawMessage(stableId: UInt32(truncatingIfNeeded: 1000 &+ message.id), stableVersion: 0, id: replyMessageId, globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: timestamp - 60, flags: [.Incoming], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: replyAuthor, text: reply.text, attributes: [], media: [], peers: peers, associatedMessages: EngineSimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
            attributes.append(ReplyMessageAttribute(messageId: replyMessageId, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil))
        }
        if message.isEdited {
            attributes.append(EditedMessageAttribute(date: timestamp, isHidden: false))
        }
        var messageText = message.text
        if let quote = message.quote, !quote.isEmpty {
            let quoteLength = (quote as NSString).length
            messageText = message.text.isEmpty ? quote : quote + "\n" + message.text
            attributes.append(TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< quoteLength, type: .BlockQuote(isCollapsed: false))]))
        }

        var flags: EngineMessage.Flags = message.isOutgoing ? [] : [.Incoming]
        if message.isOutgoing && message.isPending {
            flags.insert(.Unsent)
        }
        var author: EngineRawPeer?
        if message.isOutgoing {
            author = ggDemoUser(id: 2, name: "")
        }
        // Every preview message carries the menu's id base: the bubble then shows the time
        // only, as in the chat (GGPreviewMessageDecorations.isMenuPreview). A status-line mark
        // goes through the chat's own status prefix, «not read yet» through the preview item's
        // read state (both by this id).
        let isUnread = message.isOutgoing && message.isUnread && !message.isPending
        let globallyUniqueId = GGPreviewMessageDecorations.globallyUniqueIdBase | Int64(UInt32(bitPattern: max(1, message.id)))
        GGPreviewMessageDecorations.setStatusPrefix(message.mark?.statusText, globallyUniqueId: globallyUniqueId)
        GGPreviewMessageDecorations.setUnread(isUnread, globallyUniqueId: globallyUniqueId)
        let rawMessage = EngineRawMessage(stableId: UInt32(truncatingIfNeeded: max(1, message.id)), stableVersion: 0, id: EngineMessage.Id(peerId: message.isOutgoing ? otherPeerId : peerId, namespace: 0, id: max(1, message.id)), globallyUniqueId: globallyUniqueId, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: timestamp, flags: flags, tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: author, text: messageText, attributes: attributes, media: [], peers: peers, associatedMessages: associatedMessages, associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])

        items.append(context.sharedContext.makeChatMessagePreviewItem(context: context, messages: [EngineMessage(rawMessage)], theme: presentationData.theme, strings: presentationData.strings, wallpaper: presentationData.chatWallpaper, fontSize: presentationData.chatFontSize, chatBubbleCorners: presentationData.chatBubbleCorners, dateTimeFormat: presentationData.dateTimeFormat, nameOrder: presentationData.nameDisplayOrder, forcedResourceStatus: nil, tapMessage: nil, clickThroughMessage: nil, backgroundNode: backgroundNode, availableReactions: nil, accountPeer: nil, isCentered: false, isPreview: true, isStandalone: false, rank: nil, rankRole: nil, isGiftMessageComposerPreview: false, activateGiftMessageInput: nil))
    }
    return items
}

private final class GGMiniChatPreviewItemNode: ListViewItemNode {
    private var backgroundNode: WallpaperBackgroundNode?
    /// Clips the wallpaper to the block: the item's bounds also cover the section's top inset, and
    /// the wallpaper used to show there as a strip above the rounded block.
    private let wallpaperClipNode: ASDisplayNode
    private let chrome = GGBlockChrome()
    private let belowMessagesNode: ASDisplayNode
    private let containerNode: ASDisplayNode
    private let aboveMessagesNode: ASDisplayNode
    private var messageNodes: [ListViewItemNode] = []
    private var markNodes: [ASImageNode] = []
    private var overlays: [GGMiniChatOverlay]?

    // The chat's own header look (Telegram 13): glass pills over the wallpaper, no bar.
    private let headerBackPillNode: ASDisplayNode
    private let headerBackIconNode: ASImageNode
    private let headerTitlePillNode: ASDisplayNode
    private let headerAvatarPillNode: ASDisplayNode
    private let headerAvatarNode: AvatarNode
    private let headerTitleNode: TextNode
    private let headerStatusNode: TextNode
    /// Emoji status / Premium star after the name, as the chat's title shows it.
    private var headerStatusIconView: ComponentHostView<Empty>?

    private var headerBackIconTheme: PresentationTheme?
    private var item: GGMiniChatPreviewItem?

    init() {
        self.wallpaperClipNode = ASDisplayNode()
        self.wallpaperClipNode.clipsToBounds = true
        self.wallpaperClipNode.isUserInteractionEnabled = false

        self.belowMessagesNode = ASDisplayNode()
        self.belowMessagesNode.isUserInteractionEnabled = false
        self.belowMessagesNode.clipsToBounds = true
        self.aboveMessagesNode = ASDisplayNode()
        self.aboveMessagesNode.isUserInteractionEnabled = false
        self.aboveMessagesNode.clipsToBounds = true

        self.containerNode = ASDisplayNode()
        self.containerNode.subnodeTransform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        self.headerBackPillNode = ASDisplayNode(viewBlock: {
            return GlassBackgroundView()
        })
        self.headerBackIconNode = ASImageNode()
        self.headerBackIconNode.isLayerBacked = true
        self.headerBackIconNode.displaysAsynchronously = false
        self.headerTitlePillNode = ASDisplayNode(viewBlock: {
            return GlassBackgroundView()
        })
        self.headerAvatarPillNode = ASDisplayNode(viewBlock: {
            return GlassBackgroundView()
        })
        self.headerAvatarNode = AvatarNode(font: avatarPlaceholderFont(size: 15.0))
        self.headerTitleNode = TextNode()
        self.headerTitleNode.displaysAsynchronously = false
        self.headerStatusNode = TextNode()
        self.headerStatusNode.displaysAsynchronously = false

        super.init(layerBacked: false)

        self.clipsToBounds = true
        self.isUserInteractionEnabled = false

        // Wallpaper (in its clip node) → overlays under the bubbles → bubbles → overlays above
        // them → the top bar → the block chrome.
        self.addSubnode(self.wallpaperClipNode)
        self.addSubnode(self.belowMessagesNode)
        self.addSubnode(self.containerNode)
        self.addSubnode(self.aboveMessagesNode)
        self.addSubnode(self.headerBackPillNode)
        self.addSubnode(self.headerBackIconNode)
        self.addSubnode(self.headerTitlePillNode)
        self.addSubnode(self.headerAvatarPillNode)
        self.addSubnode(self.headerAvatarNode)
        self.addSubnode(self.headerTitleNode)
        self.addSubnode(self.headerStatusNode)
    }

    func asyncLayout() -> (_ item: GGMiniChatPreviewItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let currentNodes = self.messageNodes
        var currentBackgroundNode = self.backgroundNode
        let makeTitleLayout = TextNode.asyncLayout(self.headerTitleNode)
        let makeStatusLayout = TextNode.asyncLayout(self.headerStatusNode)

        return { [weak self] item, params, neighbors in
            let presentationData = item.presentationData
            if currentBackgroundNode == nil {
                currentBackgroundNode = createWallpaperBackgroundNode(context: item.context, forChatDisplay: false)
            }
            currentBackgroundNode?.update(wallpaper: presentationData.chatWallpaper, animated: false)
            currentBackgroundNode?.updateBubbleTheme(bubbleTheme: presentationData.theme, bubbleCorners: presentationData.chatBubbleCorners)

            // The list is drawn bottom-up (the container is rotated), so messages go in reversed.
            let orderedMessages = Array(item.content.messages.reversed())
            let items = ggPreviewMessageItems(context: item.context, presentationData: presentationData, messages: orderedMessages, backgroundNode: currentBackgroundNode)

            // Reuse the nodes while the number of messages is the same; a modifier that adds or
            // removes a message gets a fresh set (updateNode cannot change the node count).
            var nodes: [ListViewItemNode] = []
            if currentNodes.count == items.count && !currentNodes.isEmpty {
                nodes = currentNodes
                for i in 0 ..< items.count {
                    let itemNode = currentNodes[i]
                    items[i].updateNode(async: { $0() }, node: {
                        return itemNode
                    }, params: params, neighbors: ListViewItemNeighbors(previous: i == 0 ? nil : items[i - 1].neighborDescriptor, next: i == (items.count - 1) ? nil : items[i + 1].neighborDescriptor), animation: .None, completion: { layout, apply in
                        itemNode.contentSize = layout.contentSize
                        itemNode.insets = layout.insets
                        itemNode.frame = CGRect(origin: itemNode.frame.origin, size: CGSize(width: layout.size.width, height: layout.size.height))
                        itemNode.isUserInteractionEnabled = false
                        apply(ListViewItemApply())
                    })
                }
            } else {
                for i in 0 ..< items.count {
                    var itemNode: ListViewItemNode?
                    items[i].nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: false, neighbors: ListViewItemNeighbors(previous: i == 0 ? nil : items[i - 1].neighborDescriptor, next: i == (items.count - 1) ? nil : items[i + 1].neighborDescriptor), completion: { node, apply in
                        itemNode = node
                        apply().1(ListViewItemApply())
                    })
                    if let itemNode {
                        itemNode.isUserInteractionEnabled = false
                        nodes.append(itemNode)
                    }
                }
            }

            var headerTitleLayout: (TextNodeLayout, () -> TextNode)?
            var headerStatusLayout: (TextNodeLayout, () -> TextNode)?
            var headerPeer: EnginePeer?
            var headerStatusIcon: (content: EmojiStatusComponent.Content, particleColor: UIColor?)?
            let header = item.content.header
            if let header, !header.hidesTitle {
                let title: String
                switch header.peer {
                case .account:
                    headerPeer = item.accountPeer
                    title = item.accountPeer?.compactDisplayTitle ?? ""
                case let .demo(name):
                    headerPeer = .user(ggDemoUser(id: 1, name: name))
                    title = name
                }
                let theme = presentationData.theme
                // The account's own emoji status (or the Premium star) after the name, as the chat's
                // title shows it — unless «Скрыть эмодзи-статусы» is on.
                if case .account = header.peer, let peer = item.accountPeer, !ggMiniChatHidesEmojiStatus() {
                    if let emojiStatus = peer.emojiStatus {
                        headerStatusIcon = (.animation(content: .customEmoji(fileId: emojiStatus.fileId), size: CGSize(width: 32.0, height: 32.0), placeholderColor: theme.list.mediaPlaceholderColor, themeColor: theme.list.itemAccentColor, loopMode: .count(2)), emojiStatus.color.flatMap { UIColor(rgb: UInt32(bitPattern: $0)) })
                    } else if peer.isPremium && !PremiumConfiguration.with(appConfiguration: item.context.currentAppConfiguration.with { $0 }).isPremiumDisabled {
                        headerStatusIcon = (.premium(color: theme.list.itemAccentColor), nil)
                    }
                }
                let statusIconWidth: CGFloat = headerStatusIcon == nil ? 0.0 : ggMiniChatHeaderStatusIconSize + ggMiniChatHeaderStatusIconSpacing
                // Between the back pill and the avatar, minus the title pill's own padding.
                let constrainedWidth = max(1.0, params.width - params.leftInset - params.rightInset - 2.0 * (ggMiniChatHeaderSideInset + ggMiniChatHeaderPillSize + 8.0) - 28.0)
                headerTitleLayout = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: title, font: Font.semibold(15.0), textColor: theme.rootController.navigationBar.primaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(1.0, constrainedWidth - statusIconWidth), height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
                headerStatusLayout = makeStatusLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: header.status, font: Font.regular(12.0), textColor: header.statusIsAccent ? theme.rootController.navigationBar.accentTextColor : theme.rootController.navigationBar.secondaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
            } else if let header {
                switch header.peer {
                case .account:
                    headerPeer = item.accountPeer
                case let .demo(name):
                    headerPeer = .user(ggDemoUser(id: 1, name: name))
                }
            }

            let contentSize = CGSize(width: params.width, height: item.height)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item

                if strongSelf.messageNodes.count != nodes.count || zip(strongSelf.messageNodes, nodes).contains(where: { $0 !== $1 }) {
                    for node in strongSelf.messageNodes where !nodes.contains(where: { $0 === node }) {
                        node.removeFromSupernode()
                    }
                }
                strongSelf.messageNodes = nodes

                strongSelf.containerNode.frame = CGRect(origin: CGPoint(), size: contentSize)
                // The container is rotated by π: laying out from its top rests the bubbles on the bottom edge.
                var topOffset: CGFloat = ggMiniChatVerticalPadding
                for node in nodes {
                    if node.supernode == nil {
                        strongSelf.containerNode.addSubnode(node)
                    }
                    node.updateFrame(CGRect(origin: CGPoint(x: 0.0, y: topOffset), size: node.frame.size), within: contentSize)
                    topOffset += node.frame.size.height
                }

                strongSelf.applyMessageDecorations(item: item, orderedMessages: orderedMessages, nodes: nodes)

                if let currentBackgroundNode, strongSelf.backgroundNode !== currentBackgroundNode {
                    strongSelf.backgroundNode?.removeFromSupernode()
                    strongSelf.backgroundNode = currentBackgroundNode
                    strongSelf.wallpaperClipNode.addSubnode(currentBackgroundNode)
                }

                strongSelf.chrome.apply(to: strongSelf, theme: presentationData.theme, params: params, neighbors: neighbors, contentSize: contentSize, insets: insets, drawsBackground: false)

                // The block itself: the wallpaper never leaves it (no strip above the rounded top).
                let backgroundFrame = strongSelf.chrome.backgroundFrame
                let blockFrame = CGRect(x: params.leftInset, y: 0.0, width: max(0.0, params.width - params.leftInset - params.rightInset), height: contentSize.height)
                strongSelf.wallpaperClipNode.frame = blockFrame
                if let backgroundNode = strongSelf.backgroundNode {
                    // Laid out over the whole list width, as in the chat, then clipped to the block.
                    let wallpaperFrame = CGRect(x: -params.leftInset, y: backgroundFrame.minY - 100.0, width: params.width, height: backgroundFrame.height + 200.0)
                    backgroundNode.frame = wallpaperFrame
                    backgroundNode.updateLayout(size: wallpaperFrame.size, displayMode: .aspectFill, transition: .immediate)
                }

                if let header {
                    let theme = presentationData.theme
                    let pillSize = ggMiniChatHeaderPillSize
                    let pillY = floor((ggMiniChatHeaderHeight - pillSize) / 2.0)

                    let backFrame = CGRect(x: blockFrame.minX + ggMiniChatHeaderSideInset, y: pillY, width: pillSize, height: pillSize)
                    strongSelf.headerBackPillNode.isHidden = false
                    strongSelf.headerBackPillNode.frame = backFrame
                    (strongSelf.headerBackPillNode.view as? GlassBackgroundView)?.update(size: backFrame.size, cornerRadius: pillSize * 0.5, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
                    if strongSelf.headerBackIconTheme !== theme {
                        strongSelf.headerBackIconTheme = theme
                        // As the chat draws it (glass navigation bar: `chat.inputPanel.panelControlColor`).
                        // A tinted SF Symbol lost its tint in the layer-backed image node and came out black.
                        strongSelf.headerBackIconNode.image = ggMiniChatBackArrowImage(side: pillSize, color: theme.chat.inputPanel.panelControlColor)
                    }
                    strongSelf.headerBackIconNode.isHidden = false
                    strongSelf.headerBackIconNode.frame = backFrame

                    if header.hidesAvatar {
                        strongSelf.headerAvatarNode.isHidden = true
                        strongSelf.headerAvatarPillNode.isHidden = true
                    } else {
                        // As the chat draws it: the avatar inside its own glass, a thin ring around
                        // it (concentric with square avatars).
                        let glassFrame = CGRect(origin: CGPoint(x: blockFrame.maxX - ggMiniChatHeaderSideInset - pillSize, y: pillY), size: CGSize(width: pillSize, height: pillSize))
                        let avatarFrame = glassFrame.insetBy(dx: ggMiniChatHeaderAvatarInset, dy: ggMiniChatHeaderAvatarInset)
                        let avatarCornerRadius = ggAvatarCornerRadius(side: avatarFrame.width, isForum: false, upstream: avatarFrame.width * 0.5)
                        strongSelf.headerAvatarPillNode.isHidden = false
                        strongSelf.headerAvatarPillNode.frame = glassFrame
                        (strongSelf.headerAvatarPillNode.view as? GlassBackgroundView)?.update(size: glassFrame.size, cornerRadius: min(pillSize * 0.5, avatarCornerRadius + ggMiniChatHeaderAvatarInset), isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
                        strongSelf.headerAvatarNode.isHidden = false
                        strongSelf.headerAvatarNode.frame = avatarFrame
                        strongSelf.headerAvatarNode.updateSize(size: avatarFrame.size)
                        strongSelf.headerAvatarNode.setPeer(context: item.context, theme: theme, peer: headerPeer, displayDimensions: avatarFrame.size)
                    }

                    if let (titleLayout, titleApply) = headerTitleLayout, let (statusLayout, statusApply) = headerStatusLayout {
                        let _ = titleApply()
                        let _ = statusApply()
                        strongSelf.headerTitleNode.isHidden = false
                        strongSelf.headerStatusNode.isHidden = false
                        strongSelf.headerTitlePillNode.isHidden = false
                        let statusIconWidth: CGFloat = headerStatusIcon == nil ? 0.0 : ggMiniChatHeaderStatusIconSize + ggMiniChatHeaderStatusIconSpacing
                        let titleRowWidth = titleLayout.size.width + statusIconWidth
                        let textWidth = max(titleRowWidth, statusLayout.size.width)
                        let pillWidth = textWidth + 28.0
                        let pillFrame = CGRect(x: floorToScreenPixels(blockFrame.midX - pillWidth / 2.0), y: pillY, width: pillWidth, height: pillSize)
                        strongSelf.headerTitlePillNode.frame = pillFrame
                        (strongSelf.headerTitlePillNode.view as? GlassBackgroundView)?.update(size: pillFrame.size, cornerRadius: pillSize * 0.5, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
                        let textHeight = titleLayout.size.height + statusLayout.size.height
                        let textY = floor(pillFrame.midY - textHeight / 2.0)
                        let titleFrame = CGRect(origin: CGPoint(x: floorToScreenPixels(pillFrame.midX - titleRowWidth / 2.0), y: textY), size: titleLayout.size)
                        strongSelf.headerTitleNode.frame = titleFrame
                        strongSelf.headerStatusNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels(pillFrame.midX - statusLayout.size.width / 2.0), y: textY + titleLayout.size.height), size: statusLayout.size)
                        strongSelf.updateHeaderStatusIcon(item: item, icon: headerStatusIcon, titleFrame: titleFrame)
                    } else {
                        strongSelf.headerTitlePillNode.isHidden = true
                        strongSelf.headerTitleNode.isHidden = true
                        strongSelf.headerStatusNode.isHidden = true
                        strongSelf.updateHeaderStatusIcon(item: item, icon: nil, titleFrame: CGRect())
                    }
                } else {
                    strongSelf.headerBackPillNode.isHidden = true
                    strongSelf.headerBackIconNode.isHidden = true
                    strongSelf.headerTitlePillNode.isHidden = true
                    strongSelf.headerAvatarPillNode.isHidden = true
                    strongSelf.headerAvatarNode.isHidden = true
                    strongSelf.headerTitleNode.isHidden = true
                    strongSelf.headerStatusNode.isHidden = true
                    strongSelf.updateHeaderStatusIcon(item: item, icon: nil, titleFrame: CGRect())
                }

                strongSelf.applyOverlays(item: item, params: params, contentSize: contentSize, hasHeader: header != nil)
            })
        }
    }

    private func updateHeaderStatusIcon(item: GGMiniChatPreviewItem, icon: (content: EmojiStatusComponent.Content, particleColor: UIColor?)?, titleFrame: CGRect) {
        guard let icon else {
            self.headerStatusIconView?.isHidden = true
            return
        }
        let iconView: ComponentHostView<Empty>
        if let current = self.headerStatusIconView {
            iconView = current
        } else {
            iconView = ComponentHostView<Empty>()
            iconView.isUserInteractionEnabled = false
            self.view.addSubview(iconView)
            self.headerStatusIconView = iconView
        }
        iconView.isHidden = false
        let iconSize = iconView.update(
            transition: .immediate,
            component: AnyComponent(EmojiStatusComponent(
                context: item.context,
                animationCache: item.context.animationCache,
                animationRenderer: item.context.animationRenderer,
                content: icon.content,
                particleColor: icon.particleColor,
                isVisibleForAnimations: item.context.sharedContext.energyUsageSettings.loopEmoji,
                action: nil
            )),
            environment: {},
            containerSize: CGSize(width: ggMiniChatHeaderStatusIconSize, height: ggMiniChatHeaderStatusIconSize)
        )
        iconView.frame = CGRect(origin: CGPoint(x: titleFrame.maxX + ggMiniChatHeaderStatusIconSpacing, y: floorToScreenPixels(titleFrame.midY - iconSize.height / 2.0)), size: iconSize)
    }

    /// Feature layers of the chat screen (animated background, snow, edge bands), made once per node.
    private func applyOverlays(item: GGMiniChatPreviewItem, params: ListViewItemLayoutParams, contentSize: CGSize, hasHeader: Bool) {
        if self.overlays == nil, let makeOverlays = item.makeOverlays {
            let overlays = makeOverlays(item.menuContext)
            for overlay in overlays {
                overlay.view.isUserInteractionEnabled = false
                switch overlay.placement {
                case .belowMessages:
                    self.belowMessagesNode.view.addSubview(overlay.view)
                case .aboveMessages:
                    self.aboveMessagesNode.view.addSubview(overlay.view)
                }
            }
            self.overlays = overlays
        }
        let blockFrame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: max(0.0, params.width - params.leftInset - params.rightInset), height: contentSize.height))
        self.belowMessagesNode.frame = blockFrame
        self.aboveMessagesNode.frame = blockFrame
        guard let overlays = self.overlays else {
            return
        }
        let insets = UIEdgeInsets(top: hasHeader ? ggMiniChatHeaderHeight : 0.0, left: 0.0, bottom: 0.0, right: 0.0)
        for overlay in overlays {
            overlay.view.frame = CGRect(origin: CGPoint(), size: blockFrame.size)
            overlay.update(context: item.menuContext, size: blockFrame.size, insets: insets)
        }
    }

    /// Alpha and the small mark before the time. The mark lives inside the message node so it
    /// shares the bubble's coordinate space (`contentFrame()`) and its alpha.
    private func applyMessageDecorations(item: GGMiniChatPreviewItem, orderedMessages: [GGPreviewMessage], nodes: [ListViewItemNode]) {
        while self.markNodes.count < nodes.count {
            let markNode = ASImageNode()
            markNode.isLayerBacked = true
            markNode.displaysAsynchronously = false
            markNode.displayWithoutProcessing = true
            self.markNodes.append(markNode)
        }
        let presentationData = item.presentationData
        let dateFont = Font.regular(floor(presentationData.chatFontSize.baseDisplaySize * 11.0 / 17.0))
        for i in 0 ..< self.markNodes.count {
            let markNode = self.markNodes[i]
            guard i < nodes.count, i < orderedMessages.count else {
                markNode.removeFromSupernode()
                continue
            }
            let node = nodes[i]
            let message = orderedMessages[i]
            node.alpha = message.alpha

            guard let mark = message.mark, let icon = mark.icon, let bubbleNode = node as? ChatMessageItemNodeProtocol else {
                markNode.removeFromSupernode()
                continue
            }
            let color: UIColor
            if let markColor = mark.color {
                color = markColor
            } else if message.isOutgoing {
                color = presentationData.theme.chat.message.outgoing.secondaryTextColor
            } else {
                color = presentationData.theme.chat.message.incoming.secondaryTextColor
            }
            guard let image = ggMenuIcon(icon, color: color) else {
                markNode.removeFromSupernode()
                continue
            }
            let markSize = CGSize(width: 12.0, height: 12.0)
            markNode.image = image
            if let statusFrame = ggStatusLineFrame(in: node) {
                // Left of the bubble's real status line: its width depends on the date format
                // (seconds, date) and on what other features put there.
                markNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels(statusFrame.minX - 2.0 - markSize.width), y: floorToScreenPixels(statusFrame.midY - markSize.height / 2.0)), size: markSize)
            } else {
                let timeText = stringForMessageTimestamp(timestamp: ggPreviewTimestamp(ageSeconds: message.ageSeconds), dateTimeFormat: presentationData.dateTimeFormat)
                let timeAttributes: [NSAttributedString.Key: Any] = [.font: dateFont]
                let timeSize = (timeText as NSString).size(withAttributes: timeAttributes)
                let statusWidth: CGFloat = message.isOutgoing ? 18.0 : 0.0
                let bubbleFrame = bubbleNode.contentFrame()
                markNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels(bubbleFrame.maxX - 11.0 - statusWidth - timeSize.width - 3.0 - markSize.width), y: floorToScreenPixels(bubbleFrame.maxY - 6.0 - timeSize.height + (timeSize.height - markSize.height) / 2.0)), size: markSize)
            }
            if markNode.supernode !== node {
                markNode.removeFromSupernode()
            }
            node.addSubnode(markNode)
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
