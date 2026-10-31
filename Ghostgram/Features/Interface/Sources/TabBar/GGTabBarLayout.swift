import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import TabBarComponent
import GGCore
import GGHooks

/// The one model of the main tab bar (tabbar_tweaks, SG-A1…A4): order, own labels, hidden tabs,
/// look (labels, wide, hidden bar, height). Applied in two places only — `GGRootHooks.tabControllers`
/// (which controllers, in which order) and `GGTabBarHooks` (how the bar draws them) — and both
/// re-apply live on a change: no restart.
enum GGTabBarLayout {
    static let contacts = "contacts"
    static let calls = "calls"
    static let chats = "chats"
    static let settings = "settings"

    static let allIds: [String] = [contacts, calls, chats, settings]
    static let defaultOrder: [String] = [contacts, calls, chats, settings]
    /// The chat list and Settings always stay in the bar.
    static let hideableIds: Set<String> = [contacts, calls]

    static let heightOffsetRange: ClosedRange<Double> = 0.0 ... 24.0
    static let bottomOffsetRange: ClosedRange<Double> = 0.0 ... 40.0

    static func clampHeightOffset(_ value: Double) -> Double {
        return min(GGTabBarLayout.heightOffsetRange.upperBound, max(GGTabBarLayout.heightOffsetRange.lowerBound, value))
    }

    static func clampBottomOffset(_ value: Double) -> Double {
        return min(GGTabBarLayout.bottomOffsetRange.upperBound, max(GGTabBarLayout.bottomOffsetRange.lowerBound, value))
    }

    /// Known ids once each, missing ones appended in Telegram's order.
    static func normalizedOrder(_ order: [String]) -> [String] {
        var result: [String] = []
        for id in order where GGTabBarLayout.allIds.contains(id) && !result.contains(id) {
            result.append(id)
        }
        for id in GGTabBarLayout.defaultOrder where !result.contains(id) {
            result.append(id)
        }
        return result
    }
}

/// One account's root: the tab bar and Telegram's four tab controllers, held weakly.
final class GGRootEntry {
    weak var context: AccountContext?
    weak var navigationController: NavigationController?
    weak var contacts: ViewController?
    weak var calls: ViewController?
    weak var chatList: ViewController?
    weak var settings: ViewController?
    /// Tab id of each tab bar item (own labels are looked up by the item).
    var itemIds: [ObjectIdentifier: String] = [:]

    init(context: AccountContext) {
        self.context = context
    }

    var tabBarController: TabBarController? {
        guard let navigationController = self.navigationController else {
            return nil
        }
        for controller in navigationController.viewControllers {
            if let tabBarController = controller as? TabBarController {
                return tabBarController
            }
        }
        return nil
    }

    func controller(for id: String) -> ViewController? {
        switch id {
        case GGTabBarLayout.contacts:
            return self.contacts
        case GGTabBarLayout.calls:
            return self.calls
        case GGTabBarLayout.chats:
            return self.chatList
        case GGTabBarLayout.settings:
            return self.settings
        default:
            return nil
        }
    }
}

/// The roots of all accounts that built their tab bar (main thread).
final class GGRootRegistry {
    static let shared = GGRootRegistry()

    private var entries: [GGRootEntry] = []

    private init() {
    }

    func entry(for context: AccountContext) -> GGRootEntry {
        self.entries.removeAll(where: { $0.context == nil })
        if let entry = self.entries.first(where: { $0.context === context }) {
            return entry
        }
        let entry = GGRootEntry(context: context)
        self.entries.append(entry)
        return entry
    }

    var allEntries: [GGRootEntry] {
        self.entries.removeAll(where: { $0.context == nil })
        return self.entries
    }

    /// The root chat list of an account (the tab), if built.
    func rootChatList(context: AccountContext) -> ChatListController? {
        return self.entries.first(where: { $0.context === context })?.chatList as? ChatListController
    }

    /// The tab id of a tab bar item of any account.
    func tabId(for item: UITabBarItem) -> String? {
        let id = ObjectIdentifier(item)
        for entry in self.entries {
            if let value = entry.itemIds[id] {
                return value
            }
        }
        return nil
    }
}

enum GGTabBarFeature {
    static func register() {
        // Which controllers, in which order. Called by TelegramRootController when it builds or
        // updates the tabs, and by `rearrangeAll()` on a change of the organizer.
        GGRootHooks.tabControllers.register({ controllers, rootContext in
            let entry = GGRootRegistry.shared.entry(for: rootContext.context)
            entry.contacts = rootContext.contacts
            entry.calls = rootContext.calls
            entry.chatList = rootContext.chatList
            entry.settings = rootContext.settings
            controllers = GGTabBarFeature.arranged(controllers, entry: entry)
        })

        GGLifecycleHooks.rootControllersDidLoad.register({ context, navigationController in
            let entry = GGRootRegistry.shared.entry(for: context)
            entry.navigationController = navigationController
        })

        GGTabBarHooks.style.register({
            return InterfaceSnapshots.shared.current.tabBarStyle
        })

        GGTabBarHooks.itemTitle.register({ item in
            guard let id = GGRootRegistry.shared.tabId(for: item) else {
                return nil
            }
            let titles = InterfaceSettings.tabTitles.value
            if let title = titles[id], !title.isEmpty {
                return title
            }
            return nil
        })

        InterfaceSnapshots.shared.tabBarStyleChanged = {
            let hidesBar = InterfaceSnapshots.shared.current.tabBarStyle.hidesBar
            for entry in GGRootRegistry.shared.allEntries {
                guard let tabBarController = entry.tabBarController else {
                    continue
                }
                // With the bar gone the chat list's «Settings» button is the only way between tabs:
                // the bar is usually hidden from Settings, which would otherwise stay selected with
                // no way back to the chats.
                if hidesBar, let chatList = entry.chatList, let index = tabBarController.controllers.firstIndex(where: { $0 === chatList }), tabBarController.selectedIndex != index {
                    tabBarController.selectedIndex = index
                }
                tabBarController.updateLayout(transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
        InterfaceSnapshots.shared.tabArrangementChanged = {
            GGTabBarFeature.rearrangeAll()
        }
    }

    /// Telegram's controllers (contacts, calls if shown, chats, settings + whatever another
    /// feature appended) in the organizer's order, hidden tabs removed.
    static func arranged(_ controllers: [ViewController], entry: GGRootEntry) -> [ViewController] {
        let snapshot = InterfaceSnapshots.shared.current
        entry.itemIds = [:]
        for id in GGTabBarLayout.allIds {
            if let controller = entry.controller(for: id) {
                entry.itemIds[ObjectIdentifier(controller.tabBarItem)] = id
            }
        }
        if snapshot.tabOrder == GGTabBarLayout.defaultOrder && snapshot.hiddenTabs.isEmpty {
            return controllers
        }
        var known: [String: ViewController] = [:]
        var others: [ViewController] = []
        for controller in controllers {
            if let id = GGTabBarLayout.allIds.first(where: { entry.controller(for: $0) === controller }) {
                known[id] = controller
            } else {
                others.append(controller)
            }
        }
        var result: [ViewController] = []
        for id in snapshot.tabOrder {
            guard let controller = known[id] else {
                continue
            }
            if snapshot.hiddenTabs.contains(id) {
                continue
            }
            result.append(controller)
        }
        result.append(contentsOf: others)
        return result
    }

    /// Re-applies the organizer to every built tab bar (main thread).
    static func rearrangeAll() {
        for entry in GGRootRegistry.shared.allEntries {
            guard let tabBarController = entry.tabBarController else {
                continue
            }
            // Rebuild from Telegram's full set: a tab hidden before must be able to come back.
            var base: [ViewController] = []
            if let contacts = entry.contacts {
                base.append(contacts)
            }
            if let calls = entry.calls {
                base.append(calls)
            }
            if let chatList = entry.chatList {
                base.append(chatList)
            }
            if let settings = entry.settings {
                base.append(settings)
            }
            let known = Set(base.map { ObjectIdentifier($0) })
            for controller in tabBarController.controllers where !known.contains(ObjectIdentifier(controller)) {
                base.append(controller)
            }
            let arranged = GGTabBarFeature.arranged(base, entry: entry)
            if arranged.map({ ObjectIdentifier($0) }) != tabBarController.controllers.map({ ObjectIdentifier($0) }) {
                tabBarController.setControllers(arranged, selectedIndex: nil)
            }
        }
    }
}
