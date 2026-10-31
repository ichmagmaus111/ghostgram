import Foundation
import UIKit
import Display
import AppBundle
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import PromptUI
import Pasteboard
import GGCore
import GGHooks
import GGFeaturesShared

/// Items of the message context menu (`GGMessageMenuHooks`): «История правок», «Изменить локально»
/// / «Сбросить», «Закладка» / «Убрать закладку», «Удалить у себя» for kept deleted messages, and
/// «Копировать» that copies the local edit when there is one. All strings are localized, prompts
/// are Telegram's own alert with a text field.
enum GGAntiDeleteMessageMenu {
    private static func icon(_ name: String) -> (PresentationTheme) -> UIImage? {
        return { theme in
            return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
        }
    }

    static func rootNavigationController(_ context: AccountContext) -> NavigationController? {
        return context.sharedContext.mainWindow?.viewController as? NavigationController
    }

    static func present(_ controller: ViewController, context: AccountContext) {
        context.sharedContext.mainWindow?.present(controller, on: .root)
    }

    /// The message a single-message action applies to: the long-pressed one, or the album item with text.
    private static func primaryMessage(_ messages: [Message]) -> Message? {
        if messages.count == 1 {
            return messages[0]
        }
        return messages.first(where: { !$0.text.isEmpty }) ?? messages.first
    }

    static func items(_ menu: GGMessageMenuContext) -> [GGMessageMenuEntry] {
        guard let message = GGAntiDeleteMessageMenu.primaryMessage(menu.messages) else {
            return []
        }
        let context = menu.context
        let state = GGAntiDeleteMessageState(attributes: message.attributes)
        var result: [GGMessageMenuEntry] = []

        if state.deleted != nil {
            GGAntiDeleteReplyQuote.remember(message, context: context)
        }

        if let history = state.history {
            result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.AntiDelete.MessageMenu.history(count: history.versions.count), icon: GGAntiDeleteMessageMenu.icon("Chat/Context Menu/Time"), action: { _, f in
                f(.dismissWithoutContent)
                GGAntiDeleteMessageMenu.rootNavigationController(context)?.pushViewController(ggMakeEditVersionsController(context: context, messageId: message.id))
            }))))
        }

        if GGAntiDeleteSettings.localEdit.value && (!message.text.isEmpty || state.localEdit != nil) {
            result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.AntiDelete.MessageMenu.localEdit, icon: GGAntiDeleteMessageMenu.icon("Chat/Context Menu/Pencil"), action: { _, f in
                f(.dismissWithoutContent)
                GGAntiDeleteMessageMenu.promptLocalEdit(context: context, message: message)
            }))))
        }
        if state.localEdit != nil {
            result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.AntiDelete.MessageMenu.resetLocalEdit, icon: GGAntiDeleteMessageMenu.icon("Chat/Context Menu/Reload"), action: { _, f in
                f(.dismissWithoutContent)
                let _ = GGAntiDeleteOperations.setLocalEdit(postbox: context.account.postbox, messageId: message.id, text: nil, entities: []).start()
            }))))
        }

        if GGBookmarkSettings.enabled.value {
            if state.bookmark != nil {
                result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.Bookmarks.MessageMenu.remove, icon: GGAntiDeleteMessageMenu.icon("Chat/Context Menu/TagRemove"), action: { _, f in
                    f(.dismissWithoutContent)
                    GGAntiDeleteMessageMenu.setBookmark(context: context, messageId: message.id, title: nil)
                }))))
            } else {
                result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.Bookmarks.MessageMenu.add, icon: GGAntiDeleteMessageMenu.icon("Chat/Context Menu/Tag"), action: { _, f in
                    f(.dismissWithoutContent)
                    GGAntiDeleteMessageMenu.promptBookmark(context: context, message: message)
                }))))
            }
        }

        let keptIds = menu.messages.filter { $0.ggIsDeleted }.map(\.id)
        if !keptIds.isEmpty {
            result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.AntiDelete.MessageMenu.deleteForMe, textColor: .destructive, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
            }, action: { _, f in
                f(.dismissWithoutContent)
                let _ = GGAntiDeleteOperations.deleteKept(postbox: context.account.postbox, accountId: context.account.id, messageIds: keptIds).start()
            }))))
        }
        return result
    }

    /// «Копировать» copies what the bubble shows: the local edit when there is one.
    static func filter(_ items: [ContextMenuItem], _ menu: GGMessageMenuContext) -> [ContextMenuItem] {
        guard menu.messages.count == 1, let localEdit = GGAntiDeleteMessageState(attributes: menu.messages[0].attributes).localEdit else {
            return items
        }
        let copyTitle = menu.presentationData.strings.Conversation_ContextMenuCopy
        return items.map { item -> ContextMenuItem in
            guard case let .action(action) = item, action.text == copyTitle else {
                return item
            }
            return .action(ContextMenuActionItem(text: action.text, icon: action.icon, action: { _, f in
                storeMessageTextInPasteboard(localEdit.text, entities: localEdit.entities)
                f(.default)
            }))
        }
    }

    private static func promptLocalEdit(context: AccountContext, message: Message) {
        let current = message.ggEffectiveText.text
        let controller = promptController(context: context, text: GGStrings.AntiDelete.MessageMenu.localEditTitle, subtitle: GGStrings.AntiDelete.MessageMenu.localEditText, value: current, placeholder: GGStrings.AntiDelete.MessageMenu.localEditPlaceholder, characterLimit: 4096, apply: { value in
            guard let value else {
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || value == message.text {
                // Empty or back to the original: the local edit goes away.
                let _ = GGAntiDeleteOperations.setLocalEdit(postbox: context.account.postbox, messageId: message.id, text: nil, entities: []).start()
                return
            }
            if value == current {
                return
            }
            let _ = GGAntiDeleteOperations.setLocalEdit(postbox: context.account.postbox, messageId: message.id, text: value, entities: []).start()
        })
        GGAntiDeleteMessageMenu.present(controller, context: context)
    }

    private static func promptBookmark(context: AccountContext, message: Message) {
        var suggested = message.ggEffectiveText.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if suggested.count > 32 {
            suggested = String(suggested.prefix(32))
        }
        if suggested.isEmpty {
            suggested = GGStrings.Bookmarks.MessageMenu.defaultTitle
        }
        let controller = promptController(context: context, text: GGStrings.Bookmarks.MessageMenu.titlePrompt, subtitle: GGStrings.Bookmarks.MessageMenu.titlePromptText, value: suggested, placeholder: GGStrings.Bookmarks.MessageMenu.titlePlaceholder, characterLimit: 64, apply: { value in
            guard let value else {
                return
            }
            var title = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                title = GGStrings.Bookmarks.MessageMenu.defaultTitle
            }
            GGAntiDeleteMessageMenu.setBookmark(context: context, messageId: message.id, title: title)
        })
        GGAntiDeleteMessageMenu.present(controller, context: context)
    }

    static func setBookmark(context: AccountContext, messageId: MessageId, title: String?) {
        let _ = (GGAntiDeleteOperations.setBookmark(postbox: context.account.postbox, accountId: context.account.id, messageId: messageId, title: title)
        |> deliverOnMainQueue).start(completed: {
            // The bubble redraws with the message update; the search row and lists follow the index.
            GGMessageDecorationHooks.redraw(messageIds: [messageId])
        })
    }
}
