import Foundation
import Display
import AccountContext
import GGCore
import GGFeaturesShared

/// The zone's buttons of «Кнопки быстрого доступа» in a chat (W2-5's `GGQuickActions`): the deleted
/// and the edited messages of this chat, the same screens as the profile's «…» menu opens.
enum GGAntiDeleteQuickActions {
    static func register() {
        GGQuickActions.actions.register(GGQuickAction(
            id: GGQuickActionIds.deletedMessages,
            order: 200,
            title: { GGStrings.AntiDelete.QuickActions.deleted },
            iconName: "Chat/Context Menu/Delete",
            perform: { context in
                GGAntiDeleteQuickActions.open(.deleted, context: context)
            }
        ))
        GGQuickActions.actions.register(GGQuickAction(
            id: GGQuickActionIds.editedMessages,
            order: 300,
            title: { GGStrings.AntiDelete.QuickActions.edited },
            iconName: "Chat/Context Menu/Edit",
            perform: { context in
                GGAntiDeleteQuickActions.open(.edited, context: context)
            }
        ))
    }

    private static func open(_ kind: GGAntiDeleteLogKind, context: GGQuickActionContext) {
        guard let accountContext = context.accountContext as? AccountContext else {
            return
        }
        let screen = ggMakeAntiDeleteChatHistoryController(context: accountContext, kind: kind, peerId: context.peerId)
        if let navigationController = (context.chatController as? ViewController)?.navigationController as? NavigationController {
            navigationController.pushViewController(screen)
        } else {
            GGAntiDeleteMessageMenu.rootNavigationController(accountContext)?.pushViewController(screen)
        }
    }
}
