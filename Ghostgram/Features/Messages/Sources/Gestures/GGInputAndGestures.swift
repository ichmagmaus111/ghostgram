import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatMessageItemCommon
import GGCore
import GGHooks
import GGFeaturesShared

/// Input field and gestures:
/// - SG-F8 «Отправка по Return» — `GGInputPanelHooks.sendOnReturn` (chat and attachment composers);
/// - SG-G6 «Скрыть кнопку записи» — `GGInputPanelHooks.hidesRecordButton`;
/// - SG-G7 «Без эффекта удаления» — `GGChatScreenHooks.deleteEffect`;
/// - SG-G2 double tap on an own message → edit (`GGMessageGestureHooks.tap`), SG-G10 no
///   picture-in-picture swipe (`GGGalleryHooks.swipeToPictureInPicture`);
/// - SG-E2 the quick translate button beside a bubble (`GGMessageDecorationHooks.translateButtonLanguage`).
enum GGInputAndGestures {
    static func register() {
        GGInputPanelHooks.sendOnReturn.register({ request in
            if GGMessagesSettings.sendOnReturn.value {
                // Shift+Return still makes a new line on hardware keyboards.
                return !request.modifierFlags.contains(.shift)
            }
            return nil
        })
        GGInputPanelHooks.hidesRecordButton.register({ _ in
            return GGMessagesSettings.hideRecordButton.value
        })
        GGChatScreenHooks.deleteEffect.register({ _ in
            return GGMessagesSettings.disableDeleteEffect.value ? false : nil
        })
        GGMessageGestureHooks.tap.register({ request in
            guard request.tapCount == 2, let action = GGInputAndGestures.doubleTapAction(message: request.message, context: request.context) else {
                return false
            }
            switch action {
            case .edit:
                return request.startEditing()
            }
        })
        GGGalleryHooks.swipeToPictureInPicture.register({ context in
            return GGInputAndGestures.allowsSwipeToPictureInPicture(context: context)
        })
        GGMessageDecorationHooks.translateButtonLanguage.register({ message, context in
            return GGQuickTranslateButton.sourceLanguage(message: message, context: context)
        })
    }

    enum DoubleTapAction {
        case edit
    }

    /// SG-G2: what a double tap on `message` does instead of the quick reaction; nil = upstream.
    static func doubleTapAction(message: Message, context: AccountContext) -> DoubleTapAction? {
        guard GGMessagesSettings.doubleTapToEdit.value else {
            return nil
        }
        if message.effectivelyIncoming(context.account.peerId) {
            return nil
        }
        if message.id.namespace != Namespaces.Message.Cloud {
            return nil
        }
        if message.text.isEmpty && !message.media.contains(where: { $0 is TelegramMediaImage || $0 is TelegramMediaFile }) {
            return nil
        }
        // The rule behind Telegram's own «Edit» (time limit, forwards, stickers, round videos, rights
        // in channels and gigagroups): what cannot be edited keeps the double-tap reaction.
        let limits = EngineConfiguration.Limits(context.currentLimitsConfiguration.with { $0 })
        if !canEditMessage(accountPeerId: context.account.peerId, limitsConfiguration: limits, message: message) {
            return nil
        }
        return .edit
    }

    /// SG-G10: false = a vertical swipe on a gallery video dismisses it instead of starting
    /// picture-in-picture; nil = upstream.
    static func allowsSwipeToPictureInPicture(context: AccountContext) -> Bool? {
        return GGMessagesSettings.disableVideoPipSwipe.value ? false : nil
    }
}
