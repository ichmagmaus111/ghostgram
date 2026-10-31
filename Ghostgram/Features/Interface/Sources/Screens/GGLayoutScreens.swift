import Foundation
import PresentationDataUtils
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import TelegramUIPreferences
import GGCore

// MARK: - Tab bar organizer (tabbar_tweaks)

enum GGTabBarScreens {
    /// Telegram's own title of a tab.
    static func defaultTitle(_ id: String, strings: PresentationStrings) -> String {
        switch id {
        case GGTabBarLayout.contacts:
            return strings.Contacts_Title
        case GGTabBarLayout.calls:
            return strings.Calls_TabTitle
        case GGTabBarLayout.chats:
            return strings.DialogList_Title
        default:
            return strings.Settings_Title
        }
    }

    static func title(_ id: String, strings: PresentationStrings) -> String {
        if let custom = InterfaceSettings.tabTitles.value[id], !custom.isEmpty {
            return custom
        }
        return GGTabBarScreens.defaultTitle(id, strings: strings)
    }

    /// Telegram's own «Calls» tab switch (Recent Calls › Show Calls Tab). The organizer hides
    /// Calls through it, so there is one setting for it, not two.
    static func showsCallsTab(context: AccountContext) -> Signal<Bool, NoError> {
        return context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings])
        |> map { sharedData -> Bool in
            return sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self)?.showTab ?? CallListSettings.defaultSettings.showTab
        }
        |> distinctUntilChanged
    }

    /// One place for the order, the names and the hidden tabs. Applies at once (the tab bar is
    /// re-arranged from the settings snapshot), no restart.
    static func makeOrganizer(context: AccountContext) -> ViewController {
        weak var controllerRef: ViewController?
        let box = GGTabOrganizerBox()
        let update = GGTabBarScreens.showsCallsTab(context: context)
        |> deliverOnMainQueue
        |> map { value -> Void in
            box.showsCallsTab = value
            return Void()
        }
        let actions = GGListActions(select: { id in
            if id == "reset" {
                ggConfirmDestructive(context: context, from: controllerRef, title: GGStrings.Interface.Common.resetTitle, text: GGStrings.Interface.TabBar.resetText, confirm: GGStrings.Interface.Common.reset, action: {
                    InterfaceSettings.tabOrder.reset()
                    InterfaceSettings.tabTitles.reset()
                    InterfaceSettings.hiddenTabs.reset()
                    GGTabBarScreens.setShowsCallsTab(true, context: context)
                })
                return
            }
            GGTabBarScreens.presentTabActions(id: id, context: context, controller: controllerRef, showsCallsTab: box.showsCallsTab)
        }, reorder: { ids in
            InterfaceSettings.tabOrder.set(GGTabBarLayout.normalizedOrder(ids))
        })
        let controller = ggMakeInterfaceList(context: context, title: { GGStrings.Interface.TabBar.organizerTitle }, update: update, sections: { presentationData in
            let order = GGTabBarLayout.normalizedOrder(InterfaceSettings.tabOrder.value)
            var rows: [GGListRow] = [.header(GGStrings.Interface.TabBar.tabsHeader)]
            for id in order {
                let label = GGTabBarScreens.isHidden(id, showsCallsTab: box.showsCallsTab) ? GGStrings.Interface.Common.hiddenLabel : ""
                rows.append(.reorderable(id: id, title: GGTabBarScreens.title(id, strings: presentationData.strings), label: label))
            }
            rows.append(.footer(GGStrings.Interface.TabBar.tabsFooter))
            var sections = [GGListSection(rows)]
            if !InterfaceSettings.tabOrder.isDefault || !InterfaceSettings.tabTitles.isDefault || !InterfaceSettings.hiddenTabs.isDefault || !box.showsCallsTab {
                sections.append(GGListSection([.action(id: "reset", title: GGStrings.Interface.Common.reset, isDestructive: true)]))
            }
            return sections
        }, actions: actions)
        controllerRef = controller
        return controller
    }

    private static func isHidden(_ id: String, showsCallsTab: Bool) -> Bool {
        if id == GGTabBarLayout.calls && !showsCallsTab {
            return true
        }
        return InterfaceSettings.hiddenTabs.value.contains(id)
    }

    private static func setShowsCallsTab(_ value: Bool, context: AccountContext) {
        let _ = updateCallListSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            return settings.withUpdatedShowTab(value)
        }).start()
    }

    private static func presentTabActions(id: String, context: AccountContext, controller: ViewController?, showsCallsTab: Bool) {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        guard GGTabBarLayout.normalizedOrder(InterfaceSettings.tabOrder.value).contains(id) else {
            return
        }
        var buttons: [(title: String, isDestructive: Bool, action: () -> Void)] = []
        buttons.append((GGStrings.Interface.Common.rename, false, {
            ggPresentTextPrompt(from: controller, title: GGStrings.Interface.TabBar.renameTitle, text: InterfaceSettings.tabTitles.value[id] ?? "", placeholder: GGTabBarScreens.defaultTitle(id, strings: strings), cancel: strings.Common_Cancel, done: strings.Common_Done, completion: { text in
                let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
                var titles = InterfaceSettings.tabTitles.value
                titles[id] = trimmed.isEmpty ? nil : trimmed
                InterfaceSettings.tabTitles.set(titles)
            })
        }))
        if InterfaceSettings.tabTitles.value[id] != nil {
            buttons.append((GGStrings.Interface.Common.restoreName, false, {
                var titles = InterfaceSettings.tabTitles.value
                titles.removeValue(forKey: id)
                InterfaceSettings.tabTitles.set(titles)
            }))
        }
        if GGTabBarLayout.hideableIds.contains(id) {
            let hidden = InterfaceSettings.hiddenTabs.value
            if GGTabBarScreens.isHidden(id, showsCallsTab: showsCallsTab) {
                buttons.append((GGStrings.Interface.Common.show, false, {
                    InterfaceSettings.hiddenTabs.set(hidden.filter { $0 != id })
                    if id == GGTabBarLayout.calls {
                        GGTabBarScreens.setShowsCallsTab(true, context: context)
                    }
                }))
            } else {
                buttons.append((GGStrings.Interface.Common.hide, true, {
                    if id == GGTabBarLayout.calls {
                        GGTabBarScreens.setShowsCallsTab(false, context: context)
                    } else {
                        InterfaceSettings.hiddenTabs.set(hidden + [id])
                    }
                }))
            }
        }
        ggPresentActionSheet(context: context, from: controller, title: GGTabBarScreens.title(id, strings: strings), buttons: buttons)
    }
}

private final class GGTabOrganizerBox {
    var showsCallsTab = true
}

// MARK: - Settings tab rows (settings_structure: hide and order)

enum GGSettingsTabScreens {
    private static let sectionOrder = ["edit", "myProfile", "wallet", "proxy", "apps", "shortcuts", "advanced", "payment", "extra", "support"]

    /// A section's items in display order: the user's order first, then Telegram's.
    static func items(section: String) -> [GGSettingsTabItem] {
        let ordered = GGSettingsTabLayout.orderedItems(section: section, order: InterfaceSettings.settingsItemsOrder.value)
        var result = ordered
        for item in GGSettingsTabItem.allCases where item.section == section && !result.contains(item) {
            result.append(item)
        }
        return result
    }

    static func makeScreen(context: AccountContext) -> ViewController {
        weak var controllerRef: ViewController?
        let actions = GGListActions(select: { id in
            if id == "reset" {
                ggConfirmDestructive(context: context, from: controllerRef, title: GGStrings.Interface.Common.resetTitle, text: GGStrings.Interface.SettingsTab.resetText, confirm: GGStrings.Interface.Common.reset, action: {
                    InterfaceSettings.hiddenSettingsItems.reset()
                    InterfaceSettings.settingsItemsOrder.reset()
                })
                return
            }
            guard let item = GGSettingsTabItem(rawValue: id) else {
                return
            }
            GGSettingsTabScreens.presentItemActions(item, context: context, controller: controllerRef)
        }, reorder: { ids in
            let items = ids.compactMap(GGSettingsTabItem.init(rawValue:))
            if let section = items.first?.section {
                GGSettingsTabScreens.storeOrder(section: section, items: items)
            }
        })
        let controller = ggMakeInterfaceList(context: context, title: { GGStrings.Interface.SettingsTab.itemsTitle }, sections: { presentationData in
            let hidden = Set(InterfaceSettings.hiddenSettingsItems.value)
            var sections: [GGListSection] = []
            for section in GGSettingsTabScreens.sectionOrder {
                let items = GGSettingsTabScreens.items(section: section)
                if items.isEmpty {
                    continue
                }
                // A row is dragged only among the movable rows of its own block, so a block with one
                // of them has no grip.
                let movable = items.filter { $0.itemId != nil }.count > 1
                var rows: [GGListRow] = []
                for item in items {
                    let title = item.title(strings: presentationData.strings)
                    let label = hidden.contains(item.rawValue) ? GGStrings.Interface.Common.hiddenLabel : ""
                    if movable && item.itemId != nil {
                        rows.append(.reorderable(id: item.rawValue, title: title, label: label))
                    } else {
                        rows.append(.disclosure(id: item.rawValue, title: title, label: label, icon: nil))
                    }
                }
                sections.append(GGListSection(rows))
            }
            if var first = sections.first {
                first.rows.insert(.header(GGStrings.Interface.SettingsTab.itemsHeader), at: 0)
                sections[0] = first
            }
            sections.append(GGListSection([.footer(GGStrings.Interface.SettingsTab.itemsFooter)]))
            if !InterfaceSettings.hiddenSettingsItems.isDefault || !InterfaceSettings.settingsItemsOrder.isDefault {
                sections.append(GGListSection([.action(id: "reset", title: GGStrings.Interface.Common.reset, isDestructive: true)]))
            }
            return sections
        }, actions: actions)
        controllerRef = controller
        return controller
    }

    private static func presentItemActions(_ item: GGSettingsTabItem, context: AccountContext, controller: ViewController?) {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        var buttons: [(title: String, isDestructive: Bool, action: () -> Void)] = []
        var hidden = InterfaceSettings.hiddenSettingsItems.value
        if let hiddenIndex = hidden.firstIndex(of: item.rawValue) {
            buttons.append((GGStrings.Interface.Common.show, false, {
                hidden.remove(at: hiddenIndex)
                InterfaceSettings.hiddenSettingsItems.set(hidden)
            }))
        } else {
            buttons.append((GGStrings.Interface.Common.hide, true, {
                hidden.append(item.rawValue)
                InterfaceSettings.hiddenSettingsItems.set(hidden)
            }))
        }
        ggPresentActionSheet(context: context, from: controller, title: item.title(strings: strings), buttons: buttons)
    }

    /// Replaces one section's part of the stored order.
    private static func storeOrder(section: String, items: [GGSettingsTabItem]) {
        var order = GGSettingsTabLayout.normalizedOrder(InterfaceSettings.settingsItemsOrder.value).filter { GGSettingsTabItem(rawValue: $0)?.section != section }
        order.append(contentsOf: items.map { $0.rawValue })
        InterfaceSettings.settingsItemsOrder.set(order)
    }
}

// MARK: - Shortcuts (settings_structure: «Добавить в настройки»)

enum GGShortcutScreens {
    static let maxCount = 12

    static func makeScreen(context: AccountContext) -> ViewController {
        let account = context.account.id.gg
        let peers = Promise<[EnginePeer.Id: EnginePeer]>([:])
        let peerIds: Signal<[EnginePeer.Id], NoError> = InterfaceSettings.settingsShortcuts.signal(for: account)
        |> map { shortcuts -> [EnginePeer.Id] in
            return shortcuts.compactMap { $0.peer.flatMap { EnginePeer.Id(ggKey: $0) } }
        }
        |> distinctUntilChanged
        peers.set(peerIds
        |> mapToSignal { ids -> Signal<[EnginePeer.Id: EnginePeer], NoError> in
            if ids.isEmpty {
                return .single([:])
            }
            return context.engine.data.subscribe(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))))
            |> map { result -> [EnginePeer.Id: EnginePeer] in
                var mapped: [EnginePeer.Id: EnginePeer] = [:]
                for (id, peer) in result {
                    if let peer {
                        mapped[id] = peer
                    }
                }
                return mapped
            }
        })
        let favicons = Promise<[String: UIImage]>([:])
        favicons.set(InterfaceSettings.settingsShortcuts.signal(for: account)
        |> map { shortcuts -> [String] in
            return shortcuts.compactMap { $0.kind == .site ? $0.url : nil }
        }
        |> distinctUntilChanged
        |> mapToSignal { urls -> Signal<[String: UIImage], NoError> in
            if urls.isEmpty {
                return .single([:])
            }
            return combineLatest(urls.map { url in
                return GGFaviconStore.shared.icon(url: url, size: 29.0) |> map { (url, $0) }
            })
            |> map { pairs -> [String: UIImage] in
                var result: [String: UIImage] = [:]
                for (url, image) in pairs {
                    if let image {
                        result[url] = image
                    }
                }
                return result
            }
        })

        // Resolved peers and favicons are copied into the box on the main queue right before the
        // list is rebuilt from them.
        let box = GGShortcutScreenBox()
        let state = combineLatest(peers.get(), favicons.get())
        |> deliverOnMainQueue
        |> map { peers, icons -> Void in
            box.peers = peers
            box.favicons = icons
            return Void()
        }
        weak var controllerRef: ViewController?

        let actions = GGListActions(select: { id in
            switch id {
            case "add.chat":
                GGShortcutScreens.promptPeer(context: context, controller: controllerRef, kind: .chat)
            case "add.miniApp":
                GGShortcutScreens.promptPeer(context: context, controller: controllerRef, kind: .miniApp)
            case "add.site":
                GGShortcutScreens.promptSite(context: context, controller: controllerRef)
            default:
                GGShortcutScreens.presentShortcutActions(id: id, context: context, controller: controllerRef)
            }
        })
        let controller = ggMakeInterfaceList(context: context, title: { GGStrings.Interface.Shortcuts.title }, update: state, sections: { presentationData in
            let shortcuts = InterfaceSettings.settingsShortcuts.value(for: account)
            var listRows: [GGListRow] = [.header(GGStrings.Interface.Shortcuts.listHeader)]
            for shortcut in shortcuts {
                switch shortcut.kind {
                case .chat, .miniApp:
                    let label = shortcut.kind == .miniApp ? GGStrings.Interface.SettingsTab.miniAppBadge : ""
                    if let key = shortcut.peer, let peer = box.peers[EnginePeer.Id(ggKey: key)] {
                        listRows.append(.peer(id: shortcut.id, peer: peer, title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder), label: label))
                    } else {
                        listRows.append(.disclosure(id: shortcut.id, title: GGStrings.Interface.Shortcuts.unavailable, label: label, icon: nil))
                    }
                case .site:
                    let url = shortcut.url ?? ""
                    let title = (shortcut.title?.isEmpty == false ? shortcut.title : nil) ?? GGSiteShortcut.displayHost(of: url)
                    let icon = box.favicons[url] ?? GGFaviconStore.monogram(for: GGSiteShortcut.host(of: url) ?? url, size: 29.0)
                    listRows.append(.disclosure(id: shortcut.id, title: title, label: GGStrings.Interface.SettingsTab.siteBadge, icon: icon))
                }
            }
            if shortcuts.isEmpty {
                listRows.append(.footer(GGStrings.Interface.Shortcuts.empty))
            }
            var sections = [GGListSection(listRows)]
            if shortcuts.count < GGShortcutScreens.maxCount {
                sections.append(GGListSection([
                    .action(id: "add.chat", title: GGStrings.Interface.Shortcuts.addChat, isDestructive: false),
                    .action(id: "add.miniApp", title: GGStrings.Interface.Shortcuts.addMiniApp, isDestructive: false),
                    .action(id: "add.site", title: GGStrings.Interface.Shortcuts.addSite, isDestructive: false),
                    .footer(GGStrings.Interface.Shortcuts.footer)
                ]))
            }
            return sections
        }, actions: actions)
        controllerRef = controller
        return controller
    }

    private static func update(context: AccountContext, _ f: (inout [GGSettingsShortcut]) -> Void) {
        let account = context.account.id.gg
        var shortcuts = InterfaceSettings.settingsShortcuts.value(for: account)
        f(&shortcuts)
        InterfaceSettings.settingsShortcuts.set(shortcuts, for: account)
    }

    private static func presentShortcutActions(id: String, context: AccountContext, controller: ViewController?) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let shortcuts = InterfaceSettings.settingsShortcuts.value(for: context.account.id.gg)
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else {
            return
        }
        let shortcut = shortcuts[index]
        var buttons: [(title: String, isDestructive: Bool, action: () -> Void)] = []
        buttons.append((GGStrings.Interface.Common.open, false, {
            GGShortcutActions.open(shortcut, context: context, navigationController: controller?.navigationController as? NavigationController)
        }))
        if let moved = ggMoved(shortcuts, index: index, by: -1) {
            buttons.append((GGStrings.Interface.Common.moveUp, false, {
                GGShortcutScreens.update(context: context, { $0 = moved })
            }))
        }
        if let moved = ggMoved(shortcuts, index: index, by: 1) {
            buttons.append((GGStrings.Interface.Common.moveDown, false, {
                GGShortcutScreens.update(context: context, { $0 = moved })
            }))
        }
        if shortcut.kind == .site {
            buttons.append((GGStrings.Interface.Common.rename, false, {
                ggPresentTextPrompt(from: controller, title: GGStrings.Interface.Shortcuts.siteTitlePrompt, text: shortcut.title ?? "", placeholder: GGSiteShortcut.displayHost(of: shortcut.url ?? ""), cancel: presentationData.strings.Common_Cancel, done: presentationData.strings.Common_Done, completion: { text in
                    let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                    GGShortcutScreens.update(context: context, { list in
                        if let i = list.firstIndex(where: { $0.id == id }) {
                            list[i].title = trimmed.isEmpty ? nil : trimmed
                        }
                    })
                })
            }))
        }
        buttons.append((presentationData.strings.Common_Delete, true, {
            GGShortcutScreens.update(context: context, { list in
                list.removeAll(where: { $0.id == id })
            })
        }))
        ggPresentActionSheet(context: context, from: controller, buttons: buttons)
    }

    /// `@username`, `t.me/username` or a numeric ID (as the chat list search by ID reads it).
    private static func promptPeer(context: AccountContext, controller: ViewController?, kind: GGSettingsShortcut.Kind) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let title = kind == .miniApp ? GGStrings.Interface.Shortcuts.miniAppPrompt : GGStrings.Interface.Shortcuts.chatPrompt
        ggPresentTextPrompt(from: controller, title: title, message: GGStrings.Interface.Shortcuts.peerPromptText, text: "", placeholder: "@username", cancel: presentationData.strings.Common_Cancel, done: presentationData.strings.Common_Done, completion: { text in
            var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["https://", "http://", "t.me/", "telegram.me/", "@"] where query.lowercased().hasPrefix(prefix) {
                query = String(query.dropFirst(prefix.count))
            }
            if let slash = query.firstIndex(of: "/") {
                query = String(query[..<slash])
            }
            if query.isEmpty {
                return
            }
            let resolve: Signal<EnginePeer?, NoError>
            let candidates = GGChatListFeature.peerIdCandidates(query)
            if !candidates.isEmpty {
                resolve = context.engine.data.get(EngineDataMap(candidates.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))))
                |> map { result -> EnginePeer? in
                    for id in candidates {
                        if let peer = result[id] ?? nil {
                            return peer
                        }
                    }
                    return nil
                }
            } else {
                resolve = context.engine.peers.resolvePeerByName(name: query, referrer: nil)
                |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                    guard case let .result(peer) = result else {
                        return .complete()
                    }
                    return .single(peer)
                }
                |> take(1)
            }
            let _ = (resolve |> deliverOnMainQueue).start(next: { peer in
                guard let peer else {
                    controller?.present(textAlertController(context: context, title: nil, text: GGStrings.Interface.Shortcuts.notFound, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                    return
                }
                if kind == .miniApp {
                    guard case let .user(user) = peer, let botInfo = user.botInfo, botInfo.flags.contains(.hasWebApp) else {
                        controller?.present(textAlertController(context: context, title: nil, text: GGStrings.Interface.Shortcuts.notMiniApp, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                        return
                    }
                }
                let key = peer.id.ggKey
                let id = (kind == .miniApp ? "miniApp:" : "chat:") + "\(key)"
                GGShortcutScreens.update(context: context, { list in
                    if !list.contains(where: { $0.id == id }) && list.count < GGShortcutScreens.maxCount {
                        list.append(GGSettingsShortcut(id: id, kind: kind, peer: key, url: nil, title: nil))
                    }
                })
            })
        })
    }

    private static func promptSite(context: AccountContext, controller: ViewController?) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        ggPresentTextPrompt(from: controller, title: GGStrings.Interface.Shortcuts.sitePrompt, text: "", placeholder: "https://", keyboard: .URL, cancel: presentationData.strings.Common_Cancel, done: presentationData.strings.Common_Done, completion: { text in
            guard let url = GGSiteShortcut.normalizedURL(text) else {
                controller?.present(textAlertController(context: context, title: nil, text: GGStrings.Interface.Shortcuts.invalidUrl, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            let id = "site:" + url
            GGShortcutScreens.update(context: context, { list in
                if !list.contains(where: { $0.id == id }) && list.count < GGShortcutScreens.maxCount {
                    list.append(GGSettingsShortcut(id: id, kind: .site, peer: nil, url: url, title: nil))
                }
            })
        })
    }
}

private final class GGShortcutScreenBox {
    var peers: [EnginePeer.Id: EnginePeer] = [:]
    var favicons: [String: UIImage] = [:]
}
