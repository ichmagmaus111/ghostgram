import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import GGCore

/// One searchable place in the menu: a category, a tab or a row.
struct GGMenuSearchEntry {
    let id: String
    let title: String
    /// «Категория › Вкладка» (without «Ghostgram» and without the title itself).
    let path: [String]
    let keywords: [String]
    let icon: GGMenuIcon?
    let target: GGMenuScreenID
    let focusRowId: String?
}

/// For Telegram's own settings search (`SettingsUI/Sources/Search`): the same places as the
/// Ghostgram search, with breadcrumbs that start at «Ghostgram».
public struct GGMenuSearchItem {
    public let id: String
    public let title: String
    public let breadcrumbs: [String]
    public let keywords: [String]
    /// Opens the screen (it scrolls to the row and highlights it) through the access gates
    /// (`GGMenuAccessGates`): `push` may be called later, after the code was entered, or never.
    public let open: (AccountContext, @escaping (ViewController) -> Void) -> Void
}

public func ggSettingsSearchItems(context: AccountContext) -> [GGMenuSearchItem] {
    assert(Thread.isMainThread)
    let menuContext = ggDetachedMenuContext(context: context)
    let appName = GGStrings.Menu.title
    return ggMenuSearchIndex(menuContext: menuContext).map { entry in
        let target = entry.target
        let focusRowId = entry.focusRowId
        return GGMenuSearchItem(
            id: "ghostgram." + entry.id,
            title: entry.title,
            breadcrumbs: [appName] + entry.path,
            keywords: entry.keywords,
            open: { context, push in
                ggMenuWithAccess(.screen(target), path: ggMenuScreenPathIds(target), context: context, perform: {
                    guard let controller = ggMakeMenuScreen(context: context, screen: target, focusRowId: focusRowId) else {
                        return nil
                    }
                    push(controller)
                    return controller
                })
            }
        )
    }
}

/// A context for code that runs outside a menu screen (search from Telegram's settings).
func ggDetachedMenuContext(context: AccountContext) -> GGMenuContext {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return GGMenuContext(context: context, presentationData: presentationData, accountPeer: nil, drafts: [:], handle: GGMenuScreenHandle(context: context))
}

private func ggMenuScreenPath(_ screen: GGMenuScreenID, depth: Int = 0) -> [String] {
    if depth > 8 {
        return []
    }
    switch screen {
    case .root:
        return []
    case let .category(category):
        return [category.title]
    case let .tab(tabId):
        guard let tab = GGMenuStorage.shared.tabs[tabId] else {
            return []
        }
        return ggMenuScreenPath(tab.parent, depth: depth + 1) + [tab.title()]
    }
}

/// Every visible place, in menu order. Rows hidden by their own condition (or living on a screen
/// that is not reachable) are left out: a result must open something that is really there.
func ggMenuSearchIndex(menuContext: GGMenuContext) -> [GGMenuSearchEntry] {
    let storage = GGMenuStorage.shared
    var result: [GGMenuSearchEntry] = []
    var visitedScreens = Set<GGMenuScreenID>()

    func visit(screen: GGMenuScreenID, depth: Int) {
        if depth > 8 || visitedScreens.contains(screen) {
            return
        }
        visitedScreens.insert(screen)
        let screenPath = ggMenuScreenPath(screen)
        var segments: [GGMenuSegment] = []
        if case let .tab(tabId) = screen, let tab = storage.tabs[tabId] {
            segments = tab.segments
        }
        for section in storage.sections(for: screen) {
            if let isVisible = section.isVisible, !isVisible(menuContext) {
                continue
            }
            // A row of a segmented tab shows its segment in the path («Исключения › Типы»).
            var path = screenPath
            if let segmentId = section.segment, let segment = segments.first(where: { $0.id == segmentId }) {
                path.append(segment.title())
            }
            for row in storage.rows(in: section.id) {
                if !ggMenuRowIsVisible(row, menuContext: menuContext) {
                    continue
                }
                switch row.kind {
                case let .tab(tabId):
                    guard let tab = storage.tabs[tabId] else {
                        continue
                    }
                    var keywords = row.searchKeywords()
                    keywords.append(contentsOf: tab.searchKeywords())
                    if let subtitle = row.subtitle?() {
                        keywords.append(subtitle)
                    }
                    result.append(GGMenuSearchEntry(id: "tab." + tabId.rawValue, title: tab.title(), path: path, keywords: keywords, icon: row.icon, target: .tab(tabId), focusRowId: nil))
                    visit(screen: .tab(tabId), depth: depth + 1)
                case .preview:
                    continue
                case let .expandableGroup(_, children), let .expandableList(children, _):
                    let title = row.title()
                    result.append(GGMenuSearchEntry(id: row.id, title: title, path: path, keywords: ggRowKeywords(row), icon: row.icon, target: screen, focusRowId: row.id))
                    for child in children {
                        if let isVisible = child.isVisible, !isVisible(menuContext) {
                            continue
                        }
                        result.append(GGMenuSearchEntry(id: child.id, title: child.title(), path: path + [title], keywords: ggRowKeywords(child), icon: row.icon, target: screen, focusRowId: child.id))
                    }
                default:
                    let title = row.title()
                    if title.isEmpty {
                        continue
                    }
                    result.append(GGMenuSearchEntry(id: row.id, title: title, path: path, keywords: ggRowKeywords(row), icon: row.icon, target: screen, focusRowId: row.id))
                }
            }
        }
    }

    for category in GGMenuCategory.allCases {
        if !ggMenuScreenHasContent(.category(category), menuContext: menuContext) {
            continue
        }
        result.append(GGMenuSearchEntry(id: "category." + category.rawValue, title: category.title, path: [], keywords: [category.subtitle], icon: category.icon, target: .category(category), focusRowId: nil))
        visit(screen: .category(category), depth: 0)
    }
    return result
}

private func ggRowKeywords(_ row: GGMenuRow) -> [String] {
    var keywords = row.searchKeywords()
    if let subtitle = row.subtitle?() {
        keywords.append(subtitle)
    }
    return keywords
}

/// Case- and diacritic-insensitive («черный» finds «Чёрный»); every word of the query must match
/// somewhere (title, keywords, path). Ranking: title prefix → title contains all → anything else.
func ggMenuSearch(query: String, menuContext: GGMenuContext) -> [GGMenuSearchEntry] {
    let words = ggFoldForSearch(query).split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    if words.isEmpty {
        return []
    }
    var ranked: [(rank: Int, index: Int, entry: GGMenuSearchEntry)] = []
    for (index, entry) in ggMenuSearchIndex(menuContext: menuContext).enumerated() {
        let title = ggFoldForSearch(entry.title)
        let haystack = ([title] + entry.keywords.map(ggFoldForSearch) + entry.path.map(ggFoldForSearch)).joined(separator: " ")
        if !words.allSatisfy({ haystack.contains($0) }) {
            continue
        }
        let rank: Int
        if title.hasPrefix(words[0]) || title.contains(" " + words[0]) {
            rank = 0
        } else if words.allSatisfy({ title.contains($0) }) {
            rank = 1
        } else {
            rank = 2
        }
        ranked.append((rank: rank, index: index, entry: entry))
    }
    ranked.sort(by: { lhs, rhs in
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank
        }
        return lhs.index < rhs.index
    })
    return ranked.map { $0.entry }
}

func ggFoldForSearch(_ string: String) -> String {
    return string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
}
