// Compiled into ChatMessageBubbleItemNode (filegroup //Ghostgram/GGHooks:ChatMessageBubbleItemNodeHookSources):
// call-site helpers of the bubble that need the chat item types (ChatMessageItem,
// ChatControllerInteraction): multi-tap gestures (GGMessageGestureHooks), the quick translate
// button beside the bubble (GGMessageDecorationHooks.translateButtonLanguage) and the badge after
// the author's name (GGMessageDecorationHooks.authorBadge). No feature logic.

import Foundation
import UIKit
import ObjectiveC
import AsyncDisplayKit
import Display
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import AppBundle
import TextSelectionNode
import ChatControllerInteraction
import ChatMessageItem
import ChatMessageItemView
import GGHooks

// MARK: - Taps

/// The triple-tap branch: `true` = a feature handled it.
func ggBubbleHandleTap(_ item: ChatMessageItem, message: Message, tapCount: Int) -> Bool {
    if !ggBubbleIsInteractive(item) {
        return false
    }
    return GGMessageGestureHooks.handleTap(message: message, context: item.context, tapCount: tapCount, chatNode: item.controllerInteraction.chatControllerNode())
}

/// GHOST hook target: the double-tap branches of the bubble's tap recognizer. `true` = handled, the
/// bubble does nothing else now. `upstream` is the bubble's own double-tap action (the quick
/// reaction or the message menu). While a feature acts on triple taps on this message, the double
/// tap — the features' and `upstream` — is held back until the bubble's triple-tap recognizer failed,
/// and dropped when it recognized: the second tap of a triple tap must not send a reaction.
func ggBubbleHandleDoubleTap(_ node: ChatMessageItemView, item: ChatMessageItem, message: Message, upstream: @escaping () -> Void) -> Bool {
    if !ggBubbleIsInteractive(item) {
        return false
    }
    let context = item.context
    if GGMessageGestureHooks.isTripleTapWanted(message: message) {
        weak let chatNode = item.controllerInteraction.chatControllerNode()
        let stableId = item.message.stableId
        let deferred = GGMessageGestureHooks.deferDoubleTap(on: node.view, { [weak node] in
            // The cell may show another message by now.
            guard let node, node.item?.message.stableId == stableId else {
                return
            }
            if GGMessageGestureHooks.handleTap(message: message, context: context, tapCount: 2, chatNode: chatNode) {
                return
            }
            upstream()
        })
        if deferred {
            return true
        }
    }
    return GGMessageGestureHooks.handleTap(message: message, context: context, tapCount: 2, chatNode: item.controllerInteraction.chatControllerNode())
}

/// GHOST hook target: `didLoad` of the bubble. Adds a triple-tap recognizer only when a feature
/// handles taps.
func ggInstallBubbleTripleTap(_ node: ChatMessageItemView) {
    guard let recognizer = GGMessageGestureHooks.makeTripleTapRecognizer({ [weak node] in
        guard let node, let item = node.item else {
            return false
        }
        return ggBubbleHandleTap(item, message: item.message, tapCount: 3)
    }) else {
        return
    }
    node.view.addGestureRecognizer(recognizer)
}

/// Not a preview and not the message shown inside its own context menu.
private func ggBubbleIsInteractive(_ item: ChatMessageItem) -> Bool {
    if item.presentationData.isPreview {
        return false
    }
    if let subject = item.associatedData.subject, case .messageOptions = subject {
        return false
    }
    return true
}

// MARK: - Quick translate button

private var ggTranslateButtonKey: UInt8 = 0

private final class GGBubbleTranslateButtonNode: HighlightTrackingButtonNode {
    let iconNode: ASImageNode
    private var backgroundBlurView: PortalView?
    private var theme: PresentationTheme?
    var action: (() -> Void)?

    init() {
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.isUserInteractionEnabled = false
        super.init()
        self.addSubnode(self.iconNode)
        self.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            self.iconNode.alpha = highlighted ? 0.4 : 1.0
        }
    }

    @objc private func pressed() {
        self.action?()
    }

    func update(item: ChatMessageItem, size: CGSize) {
        let theme = item.presentationData.theme
        if self.theme !== theme.theme {
            self.theme = theme.theme
            let color = bubbleVariableColor(variableColor: theme.theme.chat.message.shareButtonForegroundColor, wallpaper: theme.wallpaper)
            self.iconNode.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: color)
        }
        if self.backgroundBlurView == nil, let backgroundBlurView = item.controllerInteraction.presentationContext.backgroundNode?.makeFreeBackground() {
            self.backgroundBlurView = backgroundBlurView
            backgroundBlurView.view.clipsToBounds = true
            backgroundBlurView.view.isUserInteractionEnabled = false
            self.view.insertSubview(backgroundBlurView.view, at: 0)
        }
        if let backgroundBlurView = self.backgroundBlurView {
            backgroundBlurView.view.frame = CGRect(origin: CGPoint(), size: size)
            backgroundBlurView.view.layer.cornerRadius = size.width / 2.0
        }
        if let image = self.iconNode.image {
            let iconSize = CGSize(width: min(22.0, image.size.width), height: min(22.0, image.size.height))
            self.iconNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((size.width - iconSize.width) / 2.0), y: floorToScreenPixels((size.height - iconSize.height) / 2.0)), size: iconSize)
        }
    }
}

/// GHOST hook target: the bubble's apply, after the share buttons are placed. Shows the button
/// beside the bubble (above the share button when there is one) when a feature gives a source
/// language and there is room at the side of the screen; removes it otherwise.
func ggLayoutBubbleTranslateButton(_ node: ChatMessageItemView, item: ChatMessageItem, backgroundFrame: CGRect, incoming: Bool, shareButtonFrame: CGRect?, isHidden: Bool, width: CGFloat) {
    var language: String?
    // The menu's «Перевод» preview shows the button too (it stays inert there: previews take no taps).
    if ggBubbleIsInteractive(item) || (item.presentationData.isPreview && GGPreviewMessageDecorations.isMenuPreview(item.message)) {
        language = GGMessageDecorationHooks.translateButtonLanguage(for: item.message, context: item.context)
    }
    let current = objc_getAssociatedObject(node, &ggTranslateButtonKey) as? GGBubbleTranslateButtonNode
    let size = CGSize(width: 30.0, height: 30.0)
    var frame = CGRect(origin: CGPoint(x: incoming ? backgroundFrame.maxX + 8.0 : backgroundFrame.minX - size.width - 8.0, y: backgroundFrame.maxY - size.height - 1.0), size: size)
    if let shareButtonFrame {
        frame.origin.y = shareButtonFrame.minY - size.height - 8.0
    }
    let fits = frame.minX >= 4.0 && frame.maxX <= width - 4.0 && frame.minY >= backgroundFrame.minY - 8.0
    guard language != nil, fits else {
        if let current {
            current.removeFromSupernode()
            objc_setAssociatedObject(node, &ggTranslateButtonKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return
    }
    let button: GGBubbleTranslateButtonNode
    if let current {
        button = current
    } else {
        button = GGBubbleTranslateButtonNode()
        node.addSubnode(button)
        objc_setAssociatedObject(node, &ggTranslateButtonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    button.action = { [weak node] in
        guard let item = node?.item else {
            return
        }
        let message = item.message
        item.controllerInteraction.performTextSelectionAction(message, !message.isCopyProtected(), NSAttributedString(string: message.text), message.textEntitiesAttribute?.entities, .translate)
    }
    button.update(item: item, size: size)
    button.frame = frame
    button.alpha = isHidden ? 0.0 : 1.0
}

/// GHOST hook target: the bubble's `hitTest`, before the share button.
func ggBubbleTranslateButtonHitTest(_ node: ASDisplayNode, point: CGPoint, event: UIEvent?) -> UIView? {
    guard let button = objc_getAssociatedObject(node, &ggTranslateButtonKey) as? GGBubbleTranslateButtonNode, button.alpha > 0.0, button.frame.contains(point) else {
        return nil
    }
    return button.view.hitTest(node.view.convert(point, to: button.view), with: event)
}

/// GHOST hook target: the bubble's tap recognizer must not take taps on the button.
func ggBubbleTranslateButtonContains(_ node: ASDisplayNode, point: CGPoint) -> Bool {
    guard let button = objc_getAssociatedObject(node, &ggTranslateButtonKey) as? GGBubbleTranslateButtonNode else {
        return false
    }
    return button.alpha > 0.0 && button.frame.contains(point)
}

// MARK: - Author badge

/// GHOST hook target: the bubble's layout, at the two places where the header picks whose name it
/// shows (`authorId`). Handlers are asked only when that is `message.author` of the first message,
/// so they can trust `message.author`. nil when nobody draws badges (one load).
func ggBubbleAuthorBadge(item: ChatMessageItem, authorId: PeerId) -> GGMessageAuthorBadge? {
    if GGMessageDecorationHooks.authorBadge.isEmpty {
        return nil
    }
    let message = item.content.firstMessage
    guard message.author?.id == authorId else {
        return nil
    }
    for handler in GGMessageDecorationHooks.authorBadge.handlers {
        if let badge = handler(message, item.context) {
            return badge
        }
    }
    return nil
}

/// GHOST hook target: the room the badge takes after the name and its star (added to the star's
/// width, so the name is truncated for it and the header grows by it). 0 without a badge.
func ggBubbleAuthorBadgeWidth(_ badge: GGMessageAuthorBadge?) -> CGFloat {
    guard let badge else {
        return 0.0
    }
    return ceil(badge.size.width) + 4.0
}

private var ggAuthorBadgeKey: UInt8 = 0

private final class GGBubbleAuthorBadgeNode: HighlightTrackingButtonNode {
    let badgeImageNode: ASImageNode
    var tap: (() -> Void)?

    init() {
        self.badgeImageNode = ASImageNode()
        self.badgeImageNode.displaysAsynchronously = false
        self.badgeImageNode.isUserInteractionEnabled = false
        super.init()
        self.addSubnode(self.badgeImageNode)
        self.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            self.badgeImageNode.alpha = highlighted ? 0.4 : 1.0
        }
    }

    @objc private func pressed() {
        self.tap?()
    }
}

/// GHOST hook target: the bubble's apply, after the header (name, star) is placed or removed.
/// The badge goes right after the star (or the name when there is no star), centred on the name
/// line, in the name's container; it is removed when there is no badge or no name.
func ggLayoutBubbleAuthorBadge(_ node: ASDisplayNode, container: ASDisplayNode, badge: GGMessageAuthorBadge?, nameFrame: CGRect?, iconFrame: CGRect?, animation: ListViewItemUpdateAnimation) {
    let current = objc_getAssociatedObject(node, &ggAuthorBadgeKey) as? GGBubbleAuthorBadgeNode
    guard let badge, let nameFrame else {
        if let current {
            objc_setAssociatedObject(node, &ggAuthorBadgeKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            current.tap = nil
            if animation.isAnimated {
                current.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.1, removeOnCompletion: false, completion: { [weak current] _ in
                    current?.removeFromSupernode()
                })
            } else {
                current.removeFromSupernode()
            }
        }
        return
    }
    var leading = nameFrame.maxX
    if let iconFrame {
        leading = max(leading, iconFrame.maxX)
    }
    let frame = CGRect(origin: CGPoint(x: leading + 3.0, y: nameFrame.minY + floorToScreenPixels((nameFrame.height - badge.size.height) / 2.0)), size: badge.size)
    let badgeNode: GGBubbleAuthorBadgeNode
    if let current {
        badgeNode = current
        animation.animator.updateFrame(layer: badgeNode.layer, frame: frame, completion: nil)
    } else {
        badgeNode = GGBubbleAuthorBadgeNode()
        container.addSubnode(badgeNode)
        objc_setAssociatedObject(node, &ggAuthorBadgeKey, badgeNode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        badgeNode.frame = frame
        if animation.isAnimated {
            badgeNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        }
    }
    if badgeNode.badgeImageNode.image !== badge.image {
        badgeNode.badgeImageNode.image = badge.image
    }
    badgeNode.badgeImageNode.frame = CGRect(origin: CGPoint(), size: frame.size)
    badgeNode.tap = badge.tap
    badgeNode.isUserInteractionEnabled = badge.tap != nil
}

private func ggBubbleTappableAuthorBadge(_ node: ASDisplayNode, point: CGPoint) -> GGBubbleAuthorBadgeNode? {
    guard let badgeNode = objc_getAssociatedObject(node, &ggAuthorBadgeKey) as? GGBubbleAuthorBadgeNode, badgeNode.tap != nil, badgeNode.supernode != nil else {
        return nil
    }
    let localPoint = node.view.convert(point, to: badgeNode.view)
    if badgeNode.bounds.insetBy(dx: -4.0, dy: -4.0).contains(localPoint) {
        return badgeNode
    }
    return nil
}

/// GHOST hook target: the bubble's `hitTest`, next to the name and star buttons. A badge without
/// `tap` takes no touches (the bubble handles them as upstream).
func ggBubbleAuthorBadgeHitTest(_ node: ASDisplayNode, point: CGPoint) -> UIView? {
    return ggBubbleTappableAuthorBadge(node, point: point)?.view
}

/// GHOST hook target: the bubble's tap recognizer must not take taps on a tappable badge.
func ggBubbleAuthorBadgeContains(_ node: ASDisplayNode, point: CGPoint) -> Bool {
    return ggBubbleTappableAuthorBadge(node, point: point) != nil
}
