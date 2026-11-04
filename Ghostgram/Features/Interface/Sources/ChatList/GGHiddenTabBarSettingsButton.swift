import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramCore
import AccountContext
import ChatListUI
import NavigationBarComponent
import PeerInfoScreen
import GGHooks

/// With the tab bar hidden («Скрыть панель вкладок») the root chat list gets a Settings button in
/// its header, otherwise Settings would be unreachable.
enum GGHiddenTabBarSettingsButton {
    static func register() {
        GGChatListHooks.headerRightButtons.register({ buttons, header in
            guard case .chatList(groupId: .root) = header.location, InterfaceSnapshots.shared.current.tabBarStyle.hidesBar else {
                return buttons
            }
            let context = header.context
            var result = buttons
            result.append(NavigationBarComponent.Button(
                id: "gg.settings",
                content: .icon(imageName: "Chat List/Tabs/IconSettings"),
                action: { _ in
                    GGHiddenTabBarSettingsButton.openSettings(context: context)
                }
            ))
            return result
        })
    }

    /// The Settings tab, or — when the tab bar is hidden — a Settings screen pushed on top
    /// (swipe back returns to the chats).
    static func openSettings(context: AccountContext) {
        guard let entry = GGRootRegistry.shared.allEntries.first(where: { $0.context === context }) else {
            return
        }
        if !InterfaceSnapshots.shared.current.tabBarStyle.hidesBar, let tabBarController = entry.tabBarController, let settings = entry.settings, let index = tabBarController.controllers.firstIndex(where: { $0 === settings }) {
            tabBarController.selectedIndex = index
            return
        }
        guard let navigationController = entry.navigationController else {
            return
        }
        let controller = PeerInfoScreenImpl(context: context, updatedPresentationData: nil, peerId: context.account.peerId, avatarInitiallyExpanded: false, isOpenedFromChat: false, reactionSourceMessageId: nil, callMessages: [], isSettings: true)
        navigationController.pushViewController(controller)
    }
}
