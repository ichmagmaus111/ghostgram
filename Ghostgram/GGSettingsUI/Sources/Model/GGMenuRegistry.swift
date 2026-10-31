import Foundation
import UIKit
import Display
import SwiftSignalKit

/// Registration API for features. Called on the main thread from the feature's `register()`,
/// i.e. once at launch (see FOUNDATION_SPEC §2). Reading happens only while menu screens are built.
public enum GGMenuRegistry {
    public static func register(_ row: GGMenuRow) {
        GGMenuStorage.shared.add(row: row)
    }

    /// Segments («Чаты / Папки / Типы») for a tab someone else created — usually a tab of the
    /// skeleton. Sections pick their segment with `GGMenuSectionDescriptor.segment`.
    public static func register(segments: [GGMenuSegment], for tab: GGMenuTabID) {
        GGMenuStorage.shared.setSegments(segments, for: tab)
    }

    /// Rows a section gets at runtime from data the registry can not know at launch (the chats of
    /// a list, the user's folders). `rows` is called once per opening of the screen; its signal lives
    /// as long as the screen and re-emits the whole list. The rows are shown after the section's
    /// registered rows (by `order`), take part neither in the search nor in the navbar reset, and
    /// their ids must not clash with registered ones (prefix them with the setting's key).
    /// The context passed in can push and present; for row titles use the context of the row
    /// (`.custom` builders get it on every rebuild).
    public static func register(dynamicRowsIn section: GGMenuSectionID, _ rows: @escaping (GGMenuContext) -> Signal<[GGMenuRow], NoError>) {
        GGMenuStorage.shared.addDynamicRows(section: section, provider: rows)
    }

    /// A third-party component on «О приложении › Сторонние компоненты» (a bundled library).
    public static func register(license: GGMenuLicense) {
        ggRegisterLicense(license)
    }

    /// Feature-owned deeper tabs (e.g. «История» inside «Удалённые и изменённые»). The row that
    /// opens the tab is registered separately as a `.tab(id)` row in a section of the parent screen.
    public static func register(tab: GGMenuTabDescriptor) {
        GGMenuStorage.shared.add(tab: tab)
    }

    public static func register(section: GGMenuSectionDescriptor) {
        GGMenuStorage.shared.add(section: section)
    }

    /// Convenience for the most common case: a tab plus its «кнопка с подписью» in the parent section.
    public static func register(tab: GGMenuTabDescriptor, linkIn section: GGMenuSectionID, order: Int, subtitle: (() -> String)? = nil, icon: GGMenuIcon? = nil, label: ((GGMenuContext) -> String?)? = nil) {
        GGMenuStorage.shared.add(tab: tab)
        GGMenuStorage.shared.add(row: GGMenuRow(
            id: "menu.link.\(tab.id.rawValue)",
            section: section,
            order: order,
            title: tab.title,
            subtitle: subtitle,
            icon: icon,
            kind: .tab(tab.id),
            searchKeywords: tab.searchKeywords,
            label: label
        ))
    }
}

/// Main-thread storage behind `GGMenuRegistry`. Sorted views are cached and dropped on every change.
final class GGMenuStorage {
    struct ChatModifier {
        let id: String
        let order: Int
        let modify: (inout [GGPreviewMessage], GGMenuContext) -> Void
    }

    struct ChatListModifier {
        let id: String
        let order: Int
        let modify: (inout [GGPreviewChatListRow], GGMenuContext) -> Void
    }

    static let shared = GGMenuStorage()

    private(set) var rowsById: [String: GGMenuRow] = [:]
    private var rowsBySection: [GGMenuSectionID: [GGMenuRow]] = [:]
    private(set) var tabs: [GGMenuTabID: GGMenuTabDescriptor] = [:]
    private(set) var sectionsById: [GGMenuSectionID: GGMenuSectionDescriptor] = [:]
    private var sectionsByScreen: [GGMenuScreenID: [GGMenuSectionDescriptor]] = [:]
    /// Setting key → row id: every setting has exactly one place in the menu.
    private var rowIdBySettingKey: [String: String] = [:]
    /// Group child row id → group row id.
    private(set) var groupByChildId: [String: String] = [:]
    /// Demo registration only: show tabs and categories that have no rows yet.
    var showsEmptyTabs = false
    private(set) var chatModifiers: [ChatModifier] = []
    private(set) var chatListModifiers: [ChatListModifier] = []
    private var modifierIds = Set<String>()
    /// Section → runtime row providers (`register(dynamicRowsIn:)`).
    private(set) var dynamicRowProviders: [GGMenuSectionID: [(GGMenuContext) -> Signal<[GGMenuRow], NoError>]] = [:]

    private var sortedSectionsCache: [GGMenuScreenID: [GGMenuSectionDescriptor]] = [:]
    private var sortedRowsCache: [GGMenuSectionID: [GGMenuRow]] = [:]

    private init() {
    }

    private func invalidate() {
        self.sortedSectionsCache.removeAll()
        self.sortedRowsCache.removeAll()
    }

    func add(row: GGMenuRow) {
        assert(Thread.isMainThread)
        if self.rowsById[row.id] != nil {
            assertionFailure("GGMenu: duplicate row id \(row.id)")
            return
        }
        var bindingOwners: [(key: String, rowId: String)] = []
        if let children = row.groupChildren {
            if case let .expandableGroup(master, _) = row.kind {
                bindingOwners.append((key: master.key, rowId: row.id))
            }
            for child in children {
                for binding in child.anyBindings {
                    bindingOwners.append((key: binding.key, rowId: child.id))
                }
            }
        } else {
            for binding in row.anyBindings {
                bindingOwners.append((key: binding.key, rowId: row.id))
            }
        }
        for owner in bindingOwners {
            if let existing = self.rowIdBySettingKey[owner.key] {
                assertionFailure("GGMenu: setting \(owner.key) is bound by both \(existing) and \(owner.rowId)")
            } else {
                self.rowIdBySettingKey[owner.key] = owner.rowId
            }
        }
        self.rowsById[row.id] = row
        if let children = row.groupChildren {
            for child in children {
                if self.rowsById[child.id] != nil {
                    assertionFailure("GGMenu: duplicate row id \(child.id)")
                    continue
                }
                if !child.isToggle {
                    assertionFailure("GGMenu: group \(row.id) child \(child.id) must be a toggle")
                }
                self.rowsById[child.id] = child
                self.groupByChildId[child.id] = row.id
            }
        }
        self.rowsBySection[row.section, default: []].append(row)
        self.invalidate()
    }

    func add(tab: GGMenuTabDescriptor) {
        assert(Thread.isMainThread)
        if self.tabs[tab.id] != nil {
            assertionFailure("GGMenu: duplicate tab id \(tab.id.rawValue)")
            return
        }
        self.tabs[tab.id] = tab
        self.invalidate()
    }

    /// Replaces the tab's segments, keeping everything else of its descriptor.
    func setSegments(_ segments: [GGMenuSegment], for tabId: GGMenuTabID) {
        assert(Thread.isMainThread)
        guard let tab = self.tabs[tabId] else {
            assertionFailure("GGMenu: segments for an unknown tab \(tabId.rawValue)")
            return
        }
        if !tab.segments.isEmpty {
            assertionFailure("GGMenu: tab \(tabId.rawValue) already has segments")
        }
        self.tabs[tabId] = GGMenuTabDescriptor(id: tab.id, parent: tab.parent, title: tab.title, topView: tab.topView, segments: segments, makeScreen: tab.makeScreen, searchKeywords: tab.searchKeywords)
        self.invalidate()
    }

    func addDynamicRows(section: GGMenuSectionID, provider: @escaping (GGMenuContext) -> Signal<[GGMenuRow], NoError>) {
        assert(Thread.isMainThread)
        self.dynamicRowProviders[section, default: []].append(provider)
        self.invalidate()
    }

    func hasDynamicRows(in section: GGMenuSectionID) -> Bool {
        return self.dynamicRowProviders[section] != nil
    }

    func add(section: GGMenuSectionDescriptor) {
        assert(Thread.isMainThread)
        if self.sectionsById[section.id] != nil {
            assertionFailure("GGMenu: duplicate section id \(section.id.rawValue)")
            return
        }
        if let existing = self.sectionsByScreen[section.screen]?.first(where: { $0.order == section.order }) {
            assertionFailure("GGMenu: sections \(existing.id.rawValue) and \(section.id.rawValue) share order \(section.order)")
        }
        self.sectionsById[section.id] = section
        self.sectionsByScreen[section.screen, default: []].append(section)
        self.invalidate()
    }

    func addChatModifier(_ modifier: ChatModifier) {
        assert(Thread.isMainThread)
        if !self.modifierIds.insert("chat." + modifier.id).inserted {
            assertionFailure("GGMenu: duplicate chat preview modifier \(modifier.id)")
            return
        }
        self.chatModifiers.append(modifier)
        self.chatModifiers.sort(by: { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.id < rhs.id
        })
    }

    func addChatListModifier(_ modifier: ChatListModifier) {
        assert(Thread.isMainThread)
        if !self.modifierIds.insert("chatList." + modifier.id).inserted {
            assertionFailure("GGMenu: duplicate chat list preview modifier \(modifier.id)")
            return
        }
        self.chatListModifiers.append(modifier)
        self.chatListModifiers.sort(by: { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.id < rhs.id
        })
    }

    func sections(for screen: GGMenuScreenID) -> [GGMenuSectionDescriptor] {
        if let cached = self.sortedSectionsCache[screen] {
            return cached
        }
        let sorted = (self.sectionsByScreen[screen] ?? []).sorted(by: { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.id.rawValue < rhs.id.rawValue
        })
        self.sortedSectionsCache[screen] = sorted
        return sorted
    }

    func rows(in section: GGMenuSectionID) -> [GGMenuRow] {
        if let cached = self.sortedRowsCache[section] {
            return cached
        }
        let sorted = (self.rowsBySection[section] ?? []).sorted(by: { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.id < rhs.id
        })
        self.sortedRowsCache[section] = sorted
        return sorted
    }

    /// The row a setting is bound to (its one place in the menu).
    func row(forSettingKey key: String) -> GGMenuRow? {
        guard let rowId = self.rowIdBySettingKey[key] else {
            return nil
        }
        return self.rowsById[rowId]
    }
}
