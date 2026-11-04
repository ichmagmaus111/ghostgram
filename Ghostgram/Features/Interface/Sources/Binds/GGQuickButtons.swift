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

/// «Кнопки быстрого доступа» (bind_buttons): round buttons on a chat, one per registered
/// `GGQuickAction` the user did not switch off, where «Расположение и размер» put them
/// (`GGQuickButtonsLayout`; a column on the right until then). While the master switch is off the
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
    /// Covers the whole chat (the host sets its frame to `bounds` on every layout); the buttons are
    /// its subviews at their own frames. Touches between them go through to the chat.
    let node: ASDisplayNode
    let placement: GGChatOverlayPlacement = .aboveHistory

    private let context: AccountContext
    private let peerId: EnginePeer.Id?
    private weak var controller: ChatController?
    private var buttons: [String: GGQuickButtonView] = [:]
    private var actionsById: [String: GGQuickAction] = [:]
    private var layoutKey: String?
    private var settingsDisposable: Disposable?
    private var lastLayout: (CGRect, UIEdgeInsets)?

    init(screen: GGChatScreen) {
        self.context = screen.context
        self.peerId = screen.chatLocation.peerId
        self.controller = screen.controller
        self.node = GGQuickButtonsNode()
        super.init()
        self.node.isHidden = true
        // Turning the buttons on or off, moving and resizing them apply to open chats too.
        self.settingsDisposable = (combineLatest(InterfaceSettings.bindButtons.signal, InterfaceSettings.bindButtonsHidden.signal, InterfaceSettings.bindButtonsPositions.signal, InterfaceSettings.bindButtonsWidth.signal, InterfaceSettings.bindButtonsHeight.signal)
        |> deliverOnMainQueue).start(next: { [weak self] _, _, _, _, _ in
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
        let wasHidden = self.node.isHidden
        self.node.isHidden = false
        let theme = self.context.sharedContext.currentPresentationData.with { $0 }.theme

        let key = actions.map { $0.id }.joined(separator: ",")
        var addedIds = Set<String>()
        if key != self.layoutKey {
            self.layoutKey = key
            let ids = Set(actions.map { $0.id })
            for (id, button) in self.buttons where !ids.contains(id) {
                button.removeFromSuperview()
                self.buttons[id] = nil
            }
            self.actionsById.removeAll()
            for action in actions {
                self.actionsById[action.id] = action
                if self.buttons[action.id] == nil {
                    let button = GGQuickButtonView(actionId: action.id)
                    button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
                    self.node.view.addSubview(button)
                    self.buttons[action.id] = button
                    addedIds.insert(action.id)
                }
            }
        }

        let frames = GGQuickButtonsLayout.frames(ids: actions.map { $0.id }, positions: InterfaceSettings.bindButtonsPositions.value, size: GGQuickButtonsLayout.size(), bounds: bounds.size, insets: insets)
        for action in actions {
            guard let button = self.buttons[action.id], let frame = frames[action.id] else {
                continue
            }
            button.update(action: action, isOn: action.isOn?(actionContext) ?? false, theme: theme)
            // A button that just appeared does not fly in from the corner.
            (wasHidden || addedIds.contains(action.id) ? .immediate : transition).updateFrame(view: button, frame: frame)
        }
    }

    @objc private func buttonPressed(_ sender: GGQuickButtonView) {
        guard let action = self.actionsById[sender.actionId], let peerId = self.peerId else {
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
