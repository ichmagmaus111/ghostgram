import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import LocalizedPeerData
import WallpaperBackgroundNode
import AvatarNode
import ComponentFlow
import GlassBackgroundComponent

/// The input bar of `GGFullChatPreviewNode`, in points, as the user's input-bar editor set it.
public struct GGFullChatInputBar: Equatable {
    /// Extra insets of the bar from the left / right edge.
    public var leftMargin: CGFloat
    public var rightMargin: CGFloat
    /// Lift of the whole bar above the bottom edge.
    public var lift: CGFloat
    /// Extra height of the text field.
    public var extraHeight: CGFloat

    public init(leftMargin: CGFloat = 0.0, rightMargin: CGFloat = 0.0, lift: CGFloat = 0.0, extraHeight: CGFloat = 0.0) {
        self.leftMargin = leftMargin
        self.rightMargin = rightMargin
        self.lift = lift
        self.extraHeight = extraHeight
    }
}

/// A whole chat screen for editors that place something on the chat (the quick buttons): the
/// user's wallpaper, the chat's glass header at Telegram 13's own measures (44 pt pills 16 pt from
/// the edges in a 60 pt bar under the status bar), real bubbles (`ggPreviewMessageItems`) resting on
/// an empty input bar (attachment, the field with its placeholder and the sticker button, the
/// microphone). Only the back pill takes touches (`backPressed`); the rest is a picture.
/// Main thread only, like the bubbles it builds.
public final class GGFullChatPreviewNode: ASDisplayNode {
    /// Telegram 13's glass navigation bar (`ViewController.navigationLayout`, NavigationBarImpl).
    private static let navigationHeight: CGFloat = 60.0
    private static let pillSize: CGFloat = 44.0
    private static let pillSideInset: CGFloat = 16.0
    private static let avatarInset: CGFloat = 3.0
    /// The text input panel: 40 pt controls, 7 pt above and below them (`minimalHeight` = 14 + 40),
    /// 8 pt from the edges, the microphone 6 pt right of the field.
    private static let controlSize: CGFloat = 40.0
    private static let panelPadding: CGFloat = 7.0
    private static let panelSideInset: CGFloat = 8.0
    private static let controlSpacing: CGFloat = 6.0
    /// Room between the newest bubble and the input bar.
    private static let historyBottomPadding: CGFloat = 8.0

    public var backPressed: (() -> Void)?

    private struct MessagesKey: Equatable {
        var theme: ObjectIdentifier
        var strings: ObjectIdentifier
        var wallpaper: TelegramWallpaper
        var fontSize: PresentationFontSize
        var width: CGFloat
        var leftInset: CGFloat
        var rightInset: CGFloat
        var content: GGMiniChatContent
    }

    private let context: AccountContext
    private let wallpaperNode: WallpaperBackgroundNode
    private let containerNode: ASDisplayNode
    private var messageNodes: [ListViewItemNode] = []
    private var messagesKey: MessagesKey?
    private var wallpaper: TelegramWallpaper?
    private var wallpaperTheme: PresentationTheme?
    private var iconsTheme: PresentationTheme?

    private let backGlass = GlassBackgroundView()
    private let backIcon = UIImageView()
    private let backButton = UIButton(type: .custom)
    private let titleGlass = GlassBackgroundView()
    private let titleNode = ImmediateTextNode()
    private let statusNode = ImmediateTextNode()
    private let avatarGlass = GlassBackgroundView()
    private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 16.0))

    private let attachGlass = GlassBackgroundView()
    private let attachIcon = UIImageView()
    private let fieldGlass = GlassBackgroundView()
    private let placeholderNode = ImmediateTextNode()
    private let stickersIcon = UIImageView()
    private let micGlass = GlassBackgroundView()
    private let micIcon = UIImageView()

    public init(context: AccountContext) {
        self.context = context
        self.wallpaperNode = createWallpaperBackgroundNode(context: context, forChatDisplay: false)
        self.wallpaperNode.isUserInteractionEnabled = false
        self.containerNode = ASDisplayNode()
        self.containerNode.isUserInteractionEnabled = false
        // The bubbles are made for the chat's rotated list: laying them out from the container's
        // top rests the newest one on the input bar.
        self.containerNode.subnodeTransform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        super.init()

        self.clipsToBounds = true
        self.addSubnode(self.wallpaperNode)
        self.addSubnode(self.containerNode)

        for view in [self.backGlass, self.titleGlass, self.avatarGlass, self.attachGlass, self.fieldGlass, self.micGlass] {
            view.isUserInteractionEnabled = false
        }
        for view in [self.backIcon, self.attachIcon, self.stickersIcon, self.micIcon] {
            view.contentMode = .center
            view.isUserInteractionEnabled = false
        }
        for node in [self.titleNode, self.statusNode, self.placeholderNode] {
            node.maximumNumberOfLines = 1
            node.truncationType = .end
            node.isUserInteractionEnabled = false
        }
        self.titleNode.textAlignment = .center
        self.statusNode.textAlignment = .center
        self.avatarNode.isUserInteractionEnabled = false
    }

    override public func didLoad() {
        super.didLoad()

        self.view.addSubview(self.backGlass)
        self.view.addSubview(self.backIcon)
        self.backButton.addTarget(self, action: #selector(self.backButtonPressed), for: .touchUpInside)
        self.backButton.addTarget(self, action: #selector(self.backButtonHighlight), for: [.touchDown, .touchDragEnter])
        self.backButton.addTarget(self, action: #selector(self.backButtonUnhighlight), for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        self.view.addSubview(self.backButton)
        self.view.addSubview(self.titleGlass)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.statusNode)
        self.view.addSubview(self.avatarGlass)
        self.addSubnode(self.avatarNode)

        self.view.addSubview(self.attachGlass)
        self.view.addSubview(self.attachIcon)
        self.view.addSubview(self.fieldGlass)
        self.addSubnode(self.placeholderNode)
        self.view.addSubview(self.stickersIcon)
        self.view.addSubview(self.micGlass)
        self.view.addSubview(self.micIcon)
    }

    @objc private func backButtonPressed() {
        self.backPressed?()
    }

    @objc private func backButtonHighlight() {
        self.backIcon.alpha = 0.4
    }

    @objc private func backButtonUnhighlight() {
        self.backIcon.alpha = 1.0
    }

    /// Lays the screen out and returns the history's insets: the chat's navigation bar on top, the
    /// input panel at the bottom — what `GGChatOverlay.updateLayout` gets in the chat.
    /// `safeInsets.bottom` is the home indicator's room (the layout's intrinsic bottom inset).
    @discardableResult
    public func update(presentationData: PresentationData, content: GGMiniChatContent, accountPeer: EnginePeer?, size: CGSize, safeInsets: UIEdgeInsets, statusBarHeight: CGFloat, inputBar: GGFullChatInputBar = GGFullChatInputBar()) -> UIEdgeInsets {
        let theme = presentationData.theme
        let isLoaded = self.isNodeLoaded

        // Wallpaper over the whole screen, as in the chat.
        if self.wallpaper != presentationData.chatWallpaper {
            self.wallpaper = presentationData.chatWallpaper
            self.wallpaperNode.update(wallpaper: presentationData.chatWallpaper, animated: false)
        }
        if self.wallpaperTheme !== theme {
            self.wallpaperTheme = theme
            self.wallpaperNode.updateBubbleTheme(bubbleTheme: theme, bubbleCorners: presentationData.chatBubbleCorners)
        }
        let wallpaperFrame = CGRect(origin: CGPoint(), size: size)
        if self.wallpaperNode.frame != wallpaperFrame {
            self.wallpaperNode.frame = wallpaperFrame
            self.wallpaperNode.updateLayout(size: size, displayMode: .aspectFill, transition: .immediate)
        }

        // The input bar decides where the history ends.
        let controlSize = GGFullChatPreviewNode.controlSize
        let leftEdge = safeInsets.left + inputBar.leftMargin + GGFullChatPreviewNode.panelSideInset
        let rightEdge = size.width - safeInsets.right - inputBar.rightMargin - GGFullChatPreviewNode.panelSideInset
        let fieldHeight = controlSize + max(0.0, inputBar.extraHeight)
        let fieldMaxY = size.height - safeInsets.bottom - max(0.0, inputBar.lift) - GGFullChatPreviewNode.panelPadding
        let fieldMinX = leftEdge + controlSize + GGFullChatPreviewNode.controlSpacing
        let fieldMaxX = max(fieldMinX + controlSize, rightEdge - controlSize - GGFullChatPreviewNode.controlSpacing)
        let fieldFrame = CGRect(x: fieldMinX, y: fieldMaxY - fieldHeight, width: fieldMaxX - fieldMinX, height: fieldHeight)
        let historyInsets = UIEdgeInsets(
            top: statusBarHeight + GGFullChatPreviewNode.navigationHeight,
            left: safeInsets.left,
            bottom: size.height - fieldFrame.minY + GGFullChatPreviewNode.panelPadding,
            right: safeInsets.right
        )

        self.updateMessages(presentationData: presentationData, content: content, size: size, safeInsets: safeInsets, historyBottom: historyInsets.bottom)

        guard isLoaded else {
            return historyInsets
        }

        if self.iconsTheme !== theme {
            self.iconsTheme = theme
            self.backIcon.image = ggMiniChatBackArrowImage(side: GGFullChatPreviewNode.pillSize, color: theme.chat.inputPanel.panelControlColor)
            self.attachIcon.image = PresentationResourcesChat.chatInputPanelAttachmentButtonImage(theme)
            self.attachIcon.tintColor = theme.chat.inputPanel.panelControlColor
            self.stickersIcon.image = PresentationResourcesChat.chatInputTextFieldStickersImage(theme)
            self.stickersIcon.tintColor = theme.chat.inputPanel.inputControlColor
            self.micIcon.image = PresentationResourcesChat.chatInputPanelVoiceButtonImage(theme)
        }

        // The header: back, the title pill, the avatar — as the chat's glass navigation bar lays them.
        let pillSize = GGFullChatPreviewNode.pillSize
        let pillY = statusBarHeight + 2.0 + floor((GGFullChatPreviewNode.navigationHeight - pillSize) * 0.5)
        let backFrame = CGRect(x: safeInsets.left + GGFullChatPreviewNode.pillSideInset, y: pillY, width: pillSize, height: pillSize)
        self.updateGlass(self.backGlass, frame: backFrame, cornerRadius: pillSize * 0.5, theme: theme)
        self.backIcon.frame = backFrame
        self.backButton.frame = backFrame.insetBy(dx: -6.0, dy: -6.0)

        let header = content.header
        let avatarGlassFrame = CGRect(x: size.width - safeInsets.right - GGFullChatPreviewNode.pillSideInset - pillSize, y: pillY, width: pillSize, height: pillSize)
        var headerPeer: EnginePeer?
        var title = ""
        if let header {
            switch header.peer {
            case .account:
                headerPeer = accountPeer
                title = accountPeer?.compactDisplayTitle ?? ""
            case let .demo(name):
                headerPeer = .user(ggDemoUser(id: 1, name: name))
                title = name
            }
        }
        let showsAvatar = header.map { !$0.hidesAvatar } ?? false
        self.avatarGlass.isHidden = !showsAvatar
        self.avatarNode.isHidden = !showsAvatar
        if showsAvatar {
            let avatarFrame = avatarGlassFrame.insetBy(dx: GGFullChatPreviewNode.avatarInset, dy: GGFullChatPreviewNode.avatarInset)
            let avatarCornerRadius = ggAvatarCornerRadius(side: avatarFrame.width, isForum: false, upstream: avatarFrame.width * 0.5)
            self.updateGlass(self.avatarGlass, frame: avatarGlassFrame, cornerRadius: min(pillSize * 0.5, avatarCornerRadius + GGFullChatPreviewNode.avatarInset), theme: theme)
            self.avatarNode.frame = avatarFrame
            self.avatarNode.updateSize(size: avatarFrame.size)
            self.avatarNode.setPeer(context: self.context, theme: theme, peer: headerPeer, displayDimensions: avatarFrame.size)
        }

        let showsTitle = header.map { !$0.hidesTitle } ?? false
        self.titleGlass.isHidden = !showsTitle
        self.titleNode.isHidden = !showsTitle
        self.statusNode.isHidden = !showsTitle
        if let header, showsTitle {
            let navigationBar = theme.rootController.navigationBar
            self.titleNode.attributedText = NSAttributedString(string: title, font: Font.semibold(16.0), textColor: navigationBar.primaryTextColor)
            self.statusNode.attributedText = NSAttributedString(string: header.status, font: Font.regular(13.0), textColor: header.statusIsAccent ? navigationBar.accentTextColor : navigationBar.secondaryTextColor)
            let maxTextWidth = max(1.0, size.width - 2.0 * (max(safeInsets.left, safeInsets.right) + GGFullChatPreviewNode.pillSideInset + pillSize + 8.0) - 28.0)
            let titleSize = self.titleNode.updateLayout(CGSize(width: maxTextWidth, height: 100.0))
            let statusSize = self.statusNode.updateLayout(CGSize(width: maxTextWidth, height: 100.0))
            let pillWidth = max(titleSize.width, statusSize.width) + 28.0
            let titleFrame = CGRect(x: floorToScreenPixels((size.width - pillWidth) * 0.5), y: pillY, width: pillWidth, height: pillSize)
            self.updateGlass(self.titleGlass, frame: titleFrame, cornerRadius: pillSize * 0.5, theme: theme)
            let textY = floorToScreenPixels(titleFrame.midY - (titleSize.height + statusSize.height) * 0.5)
            self.titleNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels(titleFrame.midX - titleSize.width * 0.5), y: textY), size: titleSize)
            self.statusNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels(titleFrame.midX - statusSize.width * 0.5), y: textY + titleSize.height), size: statusSize)
        }

        // The empty input bar: attachment, the field with the placeholder and the sticker button,
        // the microphone outside the field (it gives way to Send only while there is text).
        let attachFrame = CGRect(x: leftEdge, y: fieldFrame.maxY - controlSize, width: controlSize, height: controlSize)
        self.updateGlass(self.attachGlass, frame: attachFrame, cornerRadius: controlSize * 0.5, theme: theme)
        self.attachIcon.frame = attachFrame
        self.updateGlass(self.fieldGlass, frame: fieldFrame, cornerRadius: controlSize * 0.5, theme: theme)
        let stickersFrame = CGRect(x: fieldFrame.maxX - 8.0 - 32.0, y: fieldFrame.maxY - controlSize, width: 32.0, height: controlSize)
        self.stickersIcon.frame = stickersFrame
        self.placeholderNode.attributedText = NSAttributedString(string: presentationData.strings.Conversation_InputTextPlaceholder, font: Font.regular(17.0), textColor: theme.chat.inputPanel.inputPlaceholderColor)
        let placeholderSize = self.placeholderNode.updateLayout(CGSize(width: max(1.0, stickersFrame.minX - fieldFrame.minX - 18.0), height: 100.0))
        self.placeholderNode.frame = CGRect(origin: CGPoint(x: fieldFrame.minX + 14.0, y: floorToScreenPixels(fieldFrame.maxY - controlSize * 0.5 - placeholderSize.height * 0.5)), size: placeholderSize)
        let micFrame = CGRect(x: fieldFrame.maxX + GGFullChatPreviewNode.controlSpacing, y: fieldFrame.maxY - controlSize, width: controlSize, height: controlSize)
        self.updateGlass(self.micGlass, frame: micFrame, cornerRadius: controlSize * 0.5, theme: theme)
        self.micIcon.frame = micFrame

        return historyInsets
    }

    /// Real bubbles from the newest one up, rebuilt only when what they depend on changed.
    private func updateMessages(presentationData: PresentationData, content: GGMiniChatContent, size: CGSize, safeInsets: UIEdgeInsets, historyBottom: CGFloat) {
        let key = MessagesKey(theme: ObjectIdentifier(presentationData.theme), strings: ObjectIdentifier(presentationData.strings), wallpaper: presentationData.chatWallpaper, fontSize: presentationData.chatFontSize, width: size.width, leftInset: safeInsets.left, rightInset: safeInsets.right, content: content)
        if self.messagesKey != key {
            self.messagesKey = key
            for node in self.messageNodes {
                node.removeFromSupernode()
            }
            let params = ListViewItemLayoutParams(width: size.width, leftInset: safeInsets.left, rightInset: safeInsets.right, availableHeight: size.height)
            let items = ggPreviewMessageItems(context: self.context, presentationData: presentationData, messages: Array(content.messages.reversed()), backgroundNode: self.wallpaperNode)
            var nodes: [ListViewItemNode] = []
            for i in 0 ..< items.count {
                var itemNode: ListViewItemNode?
                items[i].nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: false, neighbors: ListViewItemNeighbors(previous: i == 0 ? nil : items[i - 1].neighborDescriptor, next: i == items.count - 1 ? nil : items[i + 1].neighborDescriptor), completion: { node, apply in
                    itemNode = node
                    apply().1(ListViewItemApply())
                })
                if let itemNode {
                    itemNode.isUserInteractionEnabled = false
                    nodes.append(itemNode)
                    self.containerNode.addSubnode(itemNode)
                }
            }
            self.messageNodes = nodes
        }

        let containerSize = CGSize(width: size.width, height: max(0.0, size.height - historyBottom))
        self.containerNode.frame = CGRect(origin: CGPoint(), size: containerSize)
        var offset = GGFullChatPreviewNode.historyBottomPadding
        for node in self.messageNodes {
            node.updateFrame(CGRect(origin: CGPoint(x: 0.0, y: offset), size: node.frame.size), within: containerSize)
            offset += node.frame.height
        }
    }

    private func updateGlass(_ view: GlassBackgroundView, frame: CGRect, cornerRadius: CGFloat, theme: PresentationTheme) {
        view.frame = frame
        view.update(size: frame.size, cornerRadius: cornerRadius, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
    }
}
