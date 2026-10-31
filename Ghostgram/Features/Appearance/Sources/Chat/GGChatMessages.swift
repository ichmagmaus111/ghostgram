import Foundation
import UIKit
import ObjectiveC
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGAppearanceSettings

/// Message-level appearance that needs no edit of the frozen bubble code:
/// - «Не отображать форматирование» (in / out) as a message decoration: computed once per message
///   version by the decoration cache, the bubble draws the text without bold/italic/code/quote/strike/
///   underline entities. Links, mentions, custom emoji and spoilers stay (spoilers belong to the
///   anti-spoiler feature).
/// - opening the profile by a swipe from the right edge when the chat header has neither title nor avatar.
enum GGChatMessages {
    static func register() {
        GGMessageDecorationHooks.decorations.register({ decoration, context in
            GGChatMessages.decorate(&decoration, message: context.message)
        }, order: 900)

        GGChatScreenHooks.lifecycle.register({ event, screen in
            if case .didAppear = event {
                GGChatProfileSwipe.attach(screen: screen)
            }
        }, order: 100)
    }

    private static func decorate(_ decoration: inout GGMessageDecoration, message: Message) {
        let snapshot = GGAppearanceSnapshot.current
        let isIncoming = message.flags.contains(.Incoming)
        if isIncoming ? !snapshot.hideIncomingFormatting : !snapshot.hideOutgoingFormatting {
            return
        }
        let text: String
        let entities: [MessageTextEntity]
        if let current = decoration.textOverride {
            text = current.text
            entities = current.entities
        } else {
            guard let attribute = message.textEntitiesAttribute else {
                return
            }
            text = message.text
            entities = attribute.entities
        }
        let filtered = entities.filter { entity in
            switch entity.type {
            case .Bold, .Italic, .Code, .Pre, .Strikethrough, .Underline, .BlockQuote:
                return false
            default:
                return true
            }
        }
        if filtered.count != entities.count {
            decoration.textOverride = GGMessageTextOverride(text: text, entities: filtered)
        }
    }
}

/// Swipe from the right edge opens the peer's profile while the chat header shows neither the title
/// nor the avatar (chat_top_bar): without them there is no other way into the profile.
private final class GGChatProfileSwipe: NSObject, UIGestureRecognizerDelegate {
    private static var key: UInt8 = 0

    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private weak var controller: ChatController?
    private let disposable = MetaDisposable()

    private init(context: AccountContext, peerId: EnginePeer.Id, controller: ChatController) {
        self.context = context
        self.peerId = peerId
        self.controller = controller
        super.init()
    }

    deinit {
        self.disposable.dispose()
    }

    static func attach(screen: GGChatScreen) {
        guard let controller = screen.controller, let peerId = screen.chatLocation.peerId else {
            return
        }
        if objc_getAssociatedObject(controller, &GGChatProfileSwipe.key) != nil {
            return
        }
        let snapshot = GGAppearanceSnapshot.current
        guard snapshot.hideTitlePanel && snapshot.hideAvatar else {
            return
        }
        let handler = GGChatProfileSwipe(context: screen.context, peerId: peerId, controller: controller)
        let recognizer = UIScreenEdgePanGestureRecognizer(target: handler, action: #selector(GGChatProfileSwipe.handle(_:)))
        recognizer.edges = .right
        recognizer.delegate = handler
        controller.view.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(controller, &GGChatProfileSwipe.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Settings may change while the chat is open: the swipe only works while both are hidden.
        let snapshot = GGAppearanceSnapshot.current
        return snapshot.hideTitlePanel && snapshot.hideAvatar
    }

    @objc private func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard case .began = recognizer.state else {
            return
        }
        let context = self.context
        self.disposable.set((context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, let peer, let controller = self.controller, let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            guard let infoController = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: true, requestsContext: nil) else {
                return
            }
            navigationController.pushViewController(infoController)
        }))
    }
}
