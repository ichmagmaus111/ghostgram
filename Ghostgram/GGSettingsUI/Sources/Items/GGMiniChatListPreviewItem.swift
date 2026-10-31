import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ChatListUI

/// Mini chat list made of real `ChatListItem` rows (the same cells the chat list draws), so every
/// appearance setting applied through `PresentationData` shows up here for free.
final class GGMiniChatListPreviewItem: ListViewItem, ItemListItem {
    let context: AccountContext
    let presentationData: PresentationData
    let rows: [GGPreviewChatListRow]
    let height: CGFloat
    let sectionId: ItemListSectionId

    init(context: AccountContext, presentationData: PresentationData, rows: [GGPreviewChatListRow], height: CGFloat, sectionId: ItemListSectionId) {
        self.context = context
        self.presentationData = presentationData
        self.rows = rows
        self.height = height
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = GGMiniChatListPreviewItemNode(context: self.context)
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            completion(node, {
                return (nil, { _ in apply() })
            })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? GGMiniChatListPreviewItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            completion(layout, { _ in
                apply()
            })
        }
    }
}

/// Rows of a chat list drawn by Telegram's own `ChatListItem` (the cells the chat list draws), so
/// every appearance setting applied through `PresentationData` shows up in them: the mini list of the
/// menu, and the chat list under the tab bar of «Панели». Main thread; the rows are laid out from the
/// top and clipped by the node.
public final class GGPreviewChatListNode: ASDisplayNode {
    private let containerNode: ASDisplayNode
    private var rowNodes: [ListViewItemNode] = []
    private let interaction: ChatListNodeInteraction

    public init(context: AccountContext) {
        self.containerNode = ASDisplayNode()
        self.containerNode.clipsToBounds = true
        self.interaction = ChatListNodeInteraction(context: context, animationCache: context.animationCache, animationRenderer: context.animationRenderer, activateSearch: {}, peerSelected: { _, _, _, _, _ in }, disabledPeerSelected: { _, _, _ in }, togglePeerSelected: { _, _ in }, togglePeersSelection: { _, _ in }, additionalCategorySelected: { _ in
        }, messageSelected: { _, _, _, _ in }, groupSelected: { _ in }, addContact: { _ in }, setPeerIdWithRevealedOptions: { _, _ in }, setItemPinned: { _, _ in }, setPeerMuted: { _, _ in }, setPeerThreadMuted: { _, _, _ in }, deletePeer: { _, _ in }, deletePeerThread: { _, _ in }, setPeerThreadStopped: { _, _, _ in }, setPeerThreadPinned: { _, _, _ in }, setPeerThreadHidden: { _, _, _ in }, updatePeerGrouping: { _, _ in }, togglePeerMarkedUnread: { _, _ in }, toggleArchivedFolderHiddenByDefault: {}, toggleThreadsSelection: { _, _ in }, hidePsa: { _ in
        }, activateChatPreview: { _, _, _, gesture, _ in
            gesture?.cancel()
        }, present: { _ in }, openForumThread: { _, _ in }, openStorageManagement: {}, openPasswordSetup: {}, openPremiumIntro: {}, openPremiumGift: { _, _ in }, openPremiumManagement: {}, openActiveSessions: {
        }, openBirthdaySetup: {
        }, performActiveSessionAction: { _, _ in
        }, performBotConnectionReviewAction: { _, _ in
        }, openChatFolderUpdates: {}, hideChatFolderUpdates: {
        }, openStories: { _, _ in
        }, openStarsTopup: { _ in
        }, editPeer: { _ in
        }, openWebApp: { _ in
        }, openPhotoSetup: {
        }, openAdInfo: { _, _ in
        }, openAccountFreezeInfo: {
        }, openUrl: { _ in
        })

        super.init()

        self.isUserInteractionEnabled = false
        self.addSubnode(self.containerNode)
    }

    /// Builds the rows (or updates the ones already built, same count) at `width` and lays them out
    /// from the top of the node; the insets are the list's side insets the cells keep. Returns the
    /// rows' total height.
    @discardableResult
    public func update(context: AccountContext, presentationData: PresentationData, rows: [GGPreviewChatListRow], width: CGFloat, leftInset: CGFloat = 0.0, rightInset: CGFloat = 0.0) -> CGFloat {
        let currentNodes = self.rowNodes
        let interaction = self.interaction
        let params = ListViewItemLayoutParams(width: width, leftInset: leftInset, rightInset: rightInset, availableHeight: 1000.0)
        let chatListPresentationData = ChatListPresentationData(theme: presentationData.theme, fontSize: presentationData.listsFontSize, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameSortOrder: presentationData.nameSortOrder, nameDisplayOrder: presentationData.nameDisplayOrder, disableAnimations: true)
        let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        let selfPeer: EnginePeer = .user(TelegramUser(id: context.account.peerId, accessHash: nil, firstName: nil, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))

        var items: [ChatListItem] = []
        for row in rows {
            let peer = ggPreviewPeer(row: row)
            let author: EnginePeer
            if row.isOutgoing {
                author = selfPeer
            } else if let authorName = row.authorName {
                author = .user(TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(1000 + row.id)), accessHash: nil, firstName: authorName, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))
            } else {
                author = peer
            }
            let timestamp = now - row.ageSeconds
            let messageId = EngineMessage.Id(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: 1)
            items.append(ChatListItem(
                presentationData: chatListPresentationData,
                context: context,
                chatListLocation: .chatList(groupId: .root),
                filterData: nil,
                index: .chatList(EngineChatListIndex(pinningIndex: row.isPinned ? 0 : nil, messageIndex: EngineMessage.Index(id: messageId, timestamp: timestamp))),
                content: .peer(ChatListItemContent.PeerData(
                    messages: [
                        EngineMessage(
                            stableId: UInt32(truncatingIfNeeded: row.id),
                            stableVersion: 0,
                            id: messageId,
                            globallyUniqueId: nil,
                            groupingKey: nil,
                            groupInfo: nil,
                            threadId: nil,
                            timestamp: timestamp,
                            flags: row.isOutgoing ? [] : [.Incoming],
                            tags: [],
                            globalTags: [],
                            localTags: [],
                            customTags: [],
                            forwardInfo: nil,
                            author: author,
                            text: row.text,
                            attributes: [],
                            media: [],
                            peers: [:],
                            associatedMessages: [:],
                            associatedMessageIds: [],
                            associatedMedia: [:],
                            associatedThreadInfo: nil,
                            associatedStories: [:]
                        )
                    ],
                    peer: EngineRenderedPeer(peer: peer),
                    threadInfo: nil,
                    combinedReadState: EnginePeerReadCounters(incomingReadId: 1000, outgoingReadId: 1000, count: row.unreadCount, markedUnread: false),
                    isRemovedFromTotalUnreadCount: false,
                    presence: row.isOnline ? EnginePeer.Presence(status: .present(until: now + 1000), lastActivity: now) : nil,
                    hasUnseenMentions: false,
                    hasUnseenReactions: false,
                    hasUnseenPollVotes: false,
                    draftState: nil,
                    mediaDraftContentType: nil,
                    inputActivities: row.isTyping ? [(author, .typingText)] : [],
                    promoInfo: nil,
                    ignoreUnreadBadge: false,
                    displayAsMessage: false,
                    hasFailedMessages: false,
                    forumTopicData: nil,
                    topForumTopicItems: [],
                    autoremoveTimeout: nil,
                    storyState: nil,
                    requiresPremiumForMessaging: false,
                    displayAsTopicList: false,
                    tags: []
                )),
                editing: false,
                hasActiveRevealControls: false,
                selected: false,
                header: nil,
                enabledContextActions: nil,
                hiddenOffset: false,
                interaction: interaction
            ))
        }

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
                    itemNode.frame = CGRect(origin: itemNode.frame.origin, size: CGSize(width: params.width, height: layout.size.height))
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

        for node in self.rowNodes where !nodes.contains(where: { $0 === node }) {
            node.removeFromSupernode()
        }
        self.rowNodes = nodes
        self.containerNode.frame = CGRect(origin: CGPoint(), size: self.bounds.size)

        var topOffset: CGFloat = 0.0
        for node in nodes {
            if node.supernode == nil {
                self.containerNode.addSubnode(node)
            }
            node.frame = CGRect(origin: CGPoint(x: 0.0, y: topOffset), size: CGSize(width: width, height: node.frame.height))
            topOffset += node.frame.height
        }
        return topOffset
    }

    override public func layout() {
        super.layout()
        self.containerNode.frame = CGRect(origin: CGPoint(), size: self.bounds.size)
    }
}

private final class GGMiniChatListPreviewItemNode: ListViewItemNode {
    private let chrome = GGBlockChrome()
    private let listNode: GGPreviewChatListNode

    init(context: AccountContext) {
        self.listNode = GGPreviewChatListNode(context: context)

        super.init(layerBacked: false)

        self.isUserInteractionEnabled = false
        self.addSubnode(self.listNode)
    }

    func asyncLayout() -> (_ item: GGMiniChatListPreviewItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: item.height)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.chrome.apply(to: strongSelf, theme: item.presentationData.theme, params: params, neighbors: neighbors, contentSize: contentSize, insets: insets, drawsBackground: true)
                strongSelf.listNode.frame = CGRect(origin: CGPoint(), size: contentSize)
                strongSelf.listNode.update(context: item.context, presentationData: item.presentationData, rows: item.rows, width: params.width, leftInset: params.leftInset, rightInset: params.rightInset)
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}

private func ggPreviewPeer(row: GGPreviewChatListRow) -> EnginePeer {
    switch row.kind {
    case .user:
        return .user(TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(row.id)), accessHash: nil, firstName: row.title, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))
    case .group:
        return .channel(TelegramChannel(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(row.id)), accessHash: nil, title: row.title, username: nil, photo: [], creationDate: 0, version: 0, participationStatus: .member, info: .group(.init(flags: [])), flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil))
    case .channel:
        return .channel(TelegramChannel(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(row.id)), accessHash: nil, title: row.title, username: nil, photo: [], creationDate: 0, version: 0, participationStatus: .member, info: .broadcast(.init(flags: [])), flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil))
    }
}
