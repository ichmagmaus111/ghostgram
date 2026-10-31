import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AppBundle
import GGCore
import GGHooks
import GGFeaturesShared

/// «Кнопки быстрого доступа» (bind_buttons): a column of round buttons on the right of a chat, one
/// per registered `GGQuickAction` the user did not switch off. While the master switch is off the
/// overlay is an empty hidden node whose layout returns at once: no buttons, no images, no reads
/// beyond one setting. Glyphs are tinted once per (glyph, color); backgrounds are solid (no blur).
enum GGQuickButtonsFeature {
    static func register() {
        // The one action this zone owns.
        GGQuickActions.actions.register(GGQuickAction(
            id: GGQuickActionIds.scrollToTop,
            order: 500,
            title: { GGStrings.Interface.Binds.scrollToTop },
            iconName: "Chat/Context Menu/AlignTop",
            perform: { context in
                // `performScrollToTop` is the status-bar tap: it goes to the NEWEST message.
                if let chatController = context.chatController as? ChatController {
                    GGChatScreenHooks.scrollToStartOfHistory?(chatController)
                }
            }
        ))

        GGChatScreenHooks.overlays.register({ screen in
            if screen.isPreview {
                return []
            }
            return [GGQuickButtonsOverlay(screen: screen)]
        })
    }
}

private final class GGQuickButtonsOverlay: NSObject, GGChatOverlay {
    /// Covers the whole chat (the host sets its frame to `bounds` on every layout); the buttons sit in
    /// `columnNode`. Giving this node the column frame fought the host's frame within one layout pass,
    /// and with an animated transition the buttons flew in from the corner on every input change.
    let node: ASDisplayNode
    private let columnNode: ASDisplayNode
    let placement: GGChatOverlayPlacement = .aboveHistory

    private let context: AccountContext
    private let peerId: EnginePeer.Id?
    private weak var controller: ChatController?
    private var buttons: [String: UIButton] = [:]
    private var actionsById: [String: GGQuickAction] = [:]
    private var layoutKey: String?
    private var settingsDisposable: Disposable?
    private var lastLayout: (CGRect, UIEdgeInsets)?

    init(screen: GGChatScreen) {
        self.context = screen.context
        self.peerId = screen.chatLocation.peerId
        self.controller = screen.controller
        self.node = GGQuickButtonsNode()
        self.columnNode = GGQuickButtonsNode()
        super.init()
        self.node.addSubnode(self.columnNode)
        self.node.isHidden = true
        // Turning the buttons on or off applies to open chats too.
        self.settingsDisposable = (combineLatest(InterfaceSettings.bindButtons.signal, InterfaceSettings.bindButtonsHidden.signal)
        |> deliverOnMainQueue).start(next: { [weak self] _, _ in
            guard let self, let (bounds, insets) = self.lastLayout else {
                return
            }
            self.updateLayout(bounds: bounds, insets: insets, transition: .animated(duration: 0.2, curve: .easeInOut))
        })
    }

    deinit {
        self.settingsDisposable?.dispose()
    }

    func updateLayout(bounds: CGRect, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        self.lastLayout = (bounds, insets)
        guard InterfaceSettings.bindButtons.value, let peerId = self.peerId else {
            self.node.isHidden = true
            return
        }
        let actionContext = GGQuickActionContext(account: self.context.account, peerId: peerId, chatController: self.controller, accountContext: self.context)
        let hidden = Set(InterfaceSettings.bindButtonsHidden.value)
        let actions = GGQuickActions.all.filter { action in
            if hidden.contains(action.id) {
                return false
            }
            return action.isAvailable?(actionContext) ?? true
        }
        if actions.isEmpty {
            self.node.isHidden = true
            return
        }
        self.node.isHidden = false
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let theme = presentationData.theme

        let key = actions.map { $0.id }.joined(separator: ",")
        if key != self.layoutKey {
            self.layoutKey = key
            for (_, button) in self.buttons {
                button.removeFromSuperview()
            }
            self.buttons.removeAll()
            self.actionsById.removeAll()
            for action in actions {
                let button = UIButton(type: .custom)
                button.accessibilityLabel = action.title()
                button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
                button.accessibilityIdentifier = action.id
                self.columnNode.view.addSubview(button)
                self.buttons[action.id] = button
                self.actionsById[action.id] = action
            }
        }

        let diameter: CGFloat = 40.0
        let spacing: CGFloat = 8.0
        let totalHeight = CGFloat(actions.count) * diameter + CGFloat(actions.count - 1) * spacing
        // In the node's own coordinates (the node is at `bounds`).
        let availableTop = insets.top
        let availableBottom = bounds.height - insets.bottom
        let originY = max(availableTop + spacing, floor((availableTop + availableBottom - totalHeight) * 0.5))
        let originX = bounds.width - insets.right - diameter - 10.0
        let columnFrame = CGRect(x: originX, y: originY, width: diameter, height: totalHeight)
        let wasHidden = self.columnNode.bounds.isEmpty
        (wasHidden ? .immediate : transition).updateFrame(node: self.columnNode, frame: columnFrame)

        for (index, action) in actions.enumerated() {
            guard let button = self.buttons[action.id] else {
                continue
            }
            let isOn = action.isOn?(actionContext) ?? false
            let background = isOn ? theme.list.itemAccentColor : theme.chat.inputPanel.panelBackgroundColor.withAlphaComponent(1.0)
            let foreground = isOn ? theme.list.itemCheckColors.foregroundColor : theme.chat.inputPanel.panelControlColor
            button.setBackgroundImage(GGQuickButtonImages.circle(diameter: diameter, color: background, stroke: theme.chat.inputPanel.panelSeparatorColor), for: .normal)
            button.setImage(GGQuickButtonImages.glyph(action.iconName, color: foreground), for: .normal)
            button.frame = CGRect(x: 0.0, y: CGFloat(index) * (diameter + spacing), width: diameter, height: diameter)
        }
    }

    @objc private func buttonPressed(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier, let action = self.actionsById[id], let peerId = self.peerId else {
            return
        }
        action.perform(GGQuickActionContext(account: self.context.account, peerId: peerId, chatController: self.controller, accountContext: self.context))
        if let (bounds, insets) = self.lastLayout {
            self.updateLayout(bounds: bounds, insets: insets, transition: .immediate)
        }
    }
}

/// Lets touches between the buttons through to the chat.
private final class GGQuickButtonsNode: ASDisplayNode {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result === self.view {
            return nil
        }
        return result
    }
}

/// Tinted glyphs and circles, generated once per (name, color) and reused by every chat.
private enum GGQuickButtonImages {
    private static var glyphs: [String: UIImage] = [:]
    private static var circles: [String: UIImage] = [:]

    static func glyph(_ name: String, color: UIColor) -> UIImage? {
        let key = "\(name)|\(color.hashValue)"
        if let image = GGQuickButtonImages.glyphs[key] {
            return image
        }
        guard let image = generateTintedImage(image: UIImage(bundleImageName: name), color: color) else {
            return nil
        }
        GGQuickButtonImages.glyphs[key] = image
        return image
    }

    static func circle(diameter: CGFloat, color: UIColor, stroke: UIColor) -> UIImage? {
        let key = "\(diameter)|\(color.hashValue)|\(stroke.hashValue)"
        if let image = GGQuickButtonImages.circles[key] {
            return image
        }
        guard let image = generateFilledCircleImage(diameter: diameter, color: color, strokeColor: stroke, strokeWidth: UIScreenPixel) else {
            return nil
        }
        GGQuickButtonImages.circles[key] = image
        return image
    }
}
