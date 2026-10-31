import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatListUI
import ChatListTitleView
import ChatListFilterTabContainerNode
import TelegramUIPreferences
import GGCore
import GGHooks

/// Folders (folders_tweaks, SG-A5…A9). Nothing here is read on layout or scroll: the strip's
/// look comes from the snapshot, «Все чаты» is filtered once per reload of the folders, and the
/// last folder is saved when the app leaves the foreground (per account).
enum GGFoldersFeature {
    static func register() {
        // SG-A6: hide «Все чаты» from the strip (the list's own filters are untouched; a hidden
        // selected tab falls back to the first shown one — GGChatListHooks.filterTabs).
        GGChatListHooks.filterTabs.register({ entries, _ in
            // The setting itself, not the snapshot: the rebuild below runs on the setting's own
            // signal, which can come before the snapshot is published.
            guard InterfaceSettings.hideAllChats.value else {
                return entries
            }
            let filtered = entries.filter { entry in
                if case .all = entry {
                    return false
                }
                return true
            }
            // Never leave the strip with nothing to show.
            return filtered.isEmpty ? entries : filtered
        })
        // Switching it rebuilds the tabs at once (a hidden selected «Все чаты» moves to the first
        // shown tab), not at the next change of the folders' counters.
        GGChatListHooks.filterTabsChanges.register({ _ in
            return InterfaceSettings.hideAllChats.signal
            |> map { _ -> Void in
                return Void()
            }
        })

        // SG-A5/A7/A8 and the strip height (applied in ChatListControllerNode, see requests R3).
        GGChatListStyleHooks.folderStrip.register({ context in
            let snapshot = InterfaceSnapshots.shared.current
            var title: String?
            switch snapshot.folderAllChatsTitle {
            case "short":
                title = context.sharedContext.currentPresentationData.with { $0 }.strings.ChatList_Tabs_All
            case "long":
                title = context.sharedContext.currentPresentationData.with { $0 }.strings.ChatList_Tabs_AllChats
            default:
                title = nil
            }
            let strip = GGChatListFolderStrip(allChatsTitle: title, compactTabs: snapshot.compactFolderTabs, heightOffset: snapshot.folderBarHeightOffset, atBottom: snapshot.foldersAtBottom)
            return strip == .upstream ? nil : strip
        })

        // SG-A9: remember the folder per account.
        GGLifecycleHooks.applicationWillResignActive.register({
            GGFoldersFeature.saveCurrentFolders()
        })
        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGFoldersFeature.restoreFolder(context: context)
            GGFoldersFeature.importFoldersAtBottom(context: context)
        })
    }

    /// SG-A5: the old client kept «Папки внизу» in Telegram's own experimental settings
    /// (`ExperimentalUISettings.foldersTabAtBottom`, shared data of the account manager — not a
    /// `UserDefaults` key a migration could read). Read once, on the first start of the root screens.
    static func importFoldersAtBottom(context: AccountContext) {
        if InterfaceSettings.foldersAtBottomImported.value {
            return
        }
        let _ = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings])
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            if InterfaceSettings.foldersAtBottomImported.value {
                return
            }
            InterfaceSettings.foldersAtBottomImported.set(true)
            if sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self)?.foldersTabAtBottom == true {
                InterfaceSettings.foldersAtBottom.set(true)
            }
        })
    }

    private static func containerNode(of controller: ViewController) -> ChatListContainerNode? {
        guard controller.isNodeLoaded, let subnodes = controller.displayNode.subnodes else {
            return nil
        }
        for subnode in subnodes {
            if let container = subnode as? ChatListContainerNode {
                return container
            }
        }
        return nil
    }

    static func saveCurrentFolders() {
        guard InterfaceSettings.rememberLastFolder.value else {
            return
        }
        for entry in GGRootRegistry.shared.allEntries {
            guard let context = entry.context, let chatList = entry.chatList, let container = GGFoldersFeature.containerNode(of: chatList) else {
                continue
            }
            let value: Int32
            switch container.currentItemFilter {
            case .all:
                value = 0
            case let .filter(id):
                value = id
            }
            if InterfaceSettings.lastFolder.value(for: context.account.id.gg) != value {
                InterfaceSettings.lastFolder.set(value, for: context.account.id.gg)
            }
        }
    }

    static func restoreFolder(context: AccountContext) {
        guard InterfaceSettings.rememberLastFolder.value else {
            return
        }
        let folderId = InterfaceSettings.lastFolder.value(for: context.account.id.gg)
        if folderId == 0 {
            return
        }
        // The root controllers were just built; the chat list resolves its folders right after.
        Queue.mainQueue().after(0.1, {
            GGRootRegistry.shared.rootChatList(context: context)?.navigateToFolder(folderId: folderId, completion: {})
        })
    }
}
