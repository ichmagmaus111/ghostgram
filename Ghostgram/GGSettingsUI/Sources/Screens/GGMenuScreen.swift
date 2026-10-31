import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import GGCore

/// Per-screen UI state that is never persisted.
struct GGMenuScreenState: Equatable {
    var expandedGroups = Set<String>()
    /// Slider values while a finger is on the slider (previews follow them; the setting is not written).
    var drafts: [String: Double] = [:]
    var segmentIndex: Int = 0
    var query: String = ""
}

/// Mutable bits the screen's closures share. Touched only on the main queue.
private final class GGMenuScreenHolder {
    var menuContext: GGMenuContext?
    var results: [GGMenuSearchEntry] = []
    var token: Int = 0
    /// The runtime rows of this screen (`GGMenuRegistry.register(dynamicRowsIn:)`), by id.
    var dynamicRowsById: [String: GGMenuRow] = [:]

    func row(_ id: String) -> GGMenuRow? {
        if let row = GGMenuStorage.shared.rowsById[id] {
            return row
        }
        return self.dynamicRowsById[id]
    }
}

final class GGMenuScreenArguments {
    let activate: (GGMenuEntryId) -> Void
    let toggle: (GGMenuEntryId, Bool) -> Void
    let toggleExpanded: (GGMenuEntryId) -> Void
    let groupChildToggled: (GGMenuEntryId, String) -> Void
    let sliderUpdated: (GGMenuEntryId, Double) -> Void
    let sliderCommitted: (GGMenuEntryId, Double) -> Void
    let indexSelected: (GGMenuEntryId, Int) -> Void
    let queryUpdated: (String) -> Void
    let dismissInput: () -> Void
    private let rowLookup: (String) -> GGMenuRow?

    init(rowLookup: @escaping (String) -> GGMenuRow?, activate: @escaping (GGMenuEntryId) -> Void, toggle: @escaping (GGMenuEntryId, Bool) -> Void, toggleExpanded: @escaping (GGMenuEntryId) -> Void, groupChildToggled: @escaping (GGMenuEntryId, String) -> Void, sliderUpdated: @escaping (GGMenuEntryId, Double) -> Void, sliderCommitted: @escaping (GGMenuEntryId, Double) -> Void, indexSelected: @escaping (GGMenuEntryId, Int) -> Void, queryUpdated: @escaping (String) -> Void, dismissInput: @escaping () -> Void) {
        self.rowLookup = rowLookup
        self.activate = activate
        self.toggle = toggle
        self.toggleExpanded = toggleExpanded
        self.groupChildToggled = groupChildToggled
        self.sliderUpdated = sliderUpdated
        self.sliderCommitted = sliderCommitted
        self.indexSelected = indexSelected
        self.queryUpdated = queryUpdated
        self.dismissInput = dismissInput
    }

    private func row(_ entryId: GGMenuEntryId) -> GGMenuRow? {
        if case let .row(id) = entryId {
            return self.rowLookup(id)
        }
        return nil
    }

    func miniChatConfiguration(_ entryId: GGMenuEntryId) -> GGMiniChatConfiguration? {
        if let row = self.row(entryId), case let .preview(preview) = row.kind, case let .miniChat(configuration) = preview {
            return configuration
        }
        return nil
    }

    func sliderFormat(_ entryId: GGMenuEntryId) -> (Double) -> String {
        if let row = self.row(entryId), case let .slider(_, _, _, format) = row.kind {
            return format
        }
        return { value in
            return "\(value)"
        }
    }

    func cardImages(_ entryId: GGMenuEntryId, _ theme: PresentationTheme) -> [UIImage?] {
        if let row = self.row(entryId), case let .cards(_, options) = row.kind {
            return options.map { $0.image(theme) }
        }
        return []
    }

    func previewMaker(_ entryId: GGMenuEntryId) -> ((GGMenuContext) -> UIView)? {
        if let row = self.row(entryId), case let .preview(preview) = row.kind, case let .custom(_, make) = preview {
            return make
        }
        return nil
    }

    func customBuilder(_ entryId: GGMenuEntryId) -> ((GGMenuContext) -> ListViewItem)? {
        if let row = self.row(entryId), case let .custom(builder) = row.kind {
            return builder
        }
        return nil
    }
}

/// The project's public chats: shown on the root and in «О приложении».
let ggMenuLinks: [(id: String, url: String, username: String, icon: GGMenuIcon)] = [
    (id: "channel", url: "https://t.me/ghostgrama", username: "@ghostgrama", icon: .bundle("Chat/Context Menu/Channels")),
    (id: "chat", url: "https://t.me/ghostgramchat", username: "@ghostgramchat", icon: .bundle("Chat/Context Menu/Groups")),
    (id: "forum", url: "https://t.me/ghostgramforum", username: "@ghostgramforum", icon: .bundle("Chat/Context Menu/Replies"))
]

func ggMenuLinkTitle(_ id: String) -> String {
    switch id {
    case "channel":
        return GGStrings.Menu.Root.channel
    case "chat":
        return GGStrings.Menu.Root.chat
    default:
        return GGStrings.Menu.Root.forum
    }
}

/// Root of the Ghostgram menu.
public func ggMakeSettingsController(context: AccountContext) -> ViewController {
    return ggMakeGeneratedMenuScreen(context: context, screen: .root, tabDescriptor: nil, focusRowId: nil)
}

/// Builds any menu screen. `focusRowId` (from search) scrolls to the row and highlights it once.
func ggMakeMenuScreen(context: AccountContext, screen: GGMenuScreenID, focusRowId: String?) -> ViewController? {
    guard case let .tab(tabId) = screen else {
        return ggMakeGeneratedMenuScreen(context: context, screen: screen, tabDescriptor: nil, focusRowId: focusRowId)
    }
    guard let tab = GGMenuStorage.shared.tabs[tabId] else {
        return nil
    }
    if let makeScreen = tab.makeScreen {
        let handle = GGMenuScreenHandle(context: context)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = makeScreen(GGMenuContext(context: context, presentationData: presentationData, accountPeer: nil, drafts: [:], handle: handle))
        handle.controller = controller
        return controller
    }
    return ggMakeGeneratedMenuScreen(context: context, screen: screen, tabDescriptor: tab, focusRowId: focusRowId)
}

private func ggMakeGeneratedMenuScreen(context: AccountContext, screen: GGMenuScreenID, tabDescriptor: GGMenuTabDescriptor?, focusRowId: String?) -> ViewController {
    let storage = GGMenuStorage.shared
    let handle = GGMenuScreenHandle(context: context)

    var initialState = GGMenuScreenState()
    if let focusRowId, let groupId = storage.groupByChildId[focusRowId] {
        initialState.expandedGroups.insert(groupId)
    }
    // A search result inside a segmented tab opens on the segment that holds the row.
    if let focusRowId, let segments = tabDescriptor?.segments, !segments.isEmpty {
        let rowId = storage.groupByChildId[focusRowId] ?? focusRowId
        if let row = storage.rowsById[rowId], let segment = storage.sectionsById[row.section]?.segment, let index = segments.firstIndex(where: { $0.id == segment }) {
            initialState.segmentIndex = index
        }
    }
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((inout GGMenuScreenState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }

    let holder = GGMenuScreenHolder()

    let currentContext: () -> GGMenuContext? = {
        return holder.menuContext
    }

    let arguments = GGMenuScreenArguments(rowLookup: { id in
        return holder.row(id)
    }, activate: { entryId in
        guard let menuContext = currentContext() else {
            return
        }
        switch entryId {
        case let .category(rawValue):
            if let category = GGMenuCategory(rawValue: rawValue) {
                handle.open(screen: .category(category), focusRowId: nil)
            }
        case let .link(id):
            if let link = ggMenuLinks.first(where: { $0.id == id }) {
                handle.openTelegramLink(link.url)
            }
        case let .result(index):
            guard index < holder.results.count else {
                return
            }
            let result = holder.results[index]
            handle.controller?.view.endEditing(true)
            handle.open(screen: result.target, focusRowId: result.focusRowId)
        case let .row(id):
            guard let row = holder.row(id) else {
                return
            }
            switch row.kind {
            case let .tab(tabId):
                handle.open(screen: .tab(tabId), focusRowId: nil)
            case let .action(action):
                // Actions go through the access gates too (export, import, a feature's own).
                ggMenuWithAccess(.action(rowId: row.id), path: ggMenuScreenPathIds(screen), context: context, perform: {
                    if let currentContext = currentContext() {
                        action(currentContext)
                    }
                    return nil
                })
            case let .choice(binding, options):
                ggPresentChoice(row: row, binding: binding, options: options, menuContext: menuContext)
            default:
                break
            }
        default:
            break
        }
    }, toggle: { entryId, value in
        guard let menuContext = currentContext(), case let .row(id) = entryId, let row = holder.row(id) else {
            return
        }
        switch row.kind {
        case let .toggle(binding):
            binding.set(value, in: menuContext)
        case let .expandableGroup(master, _):
            master.set(value, in: menuContext)
        default:
            break
        }
    }, toggleExpanded: { entryId in
        guard case let .row(id) = entryId else {
            return
        }
        updateState { state in
            if state.expandedGroups.contains(id) {
                state.expandedGroups.remove(id)
            } else {
                state.expandedGroups.insert(id)
            }
        }
    }, groupChildToggled: { _, childId in
        guard let menuContext = currentContext(), let child = storage.rowsById[childId], case let .toggle(binding) = child.kind else {
            return
        }
        binding.set(!binding.value(in: menuContext), in: menuContext)
    }, sliderUpdated: { entryId, value in
        guard case let .row(id) = entryId, let row = holder.row(id), case let .slider(binding, _, _, _) = row.kind else {
            return
        }
        updateState { state in
            state.drafts[binding.key] = value
        }
    }, sliderCommitted: { entryId, value in
        guard let menuContext = currentContext(), case let .row(id) = entryId, let row = holder.row(id), case let .slider(binding, _, _, _) = row.kind else {
            return
        }
        binding.set(value, in: menuContext)
        updateState { state in
            state.drafts.removeValue(forKey: binding.key)
        }
    }, indexSelected: { entryId, index in
        guard let menuContext = currentContext(), case let .row(id) = entryId, let row = holder.row(id) else {
            return
        }
        switch row.kind {
        case let .discreteChoice(binding, options):
            if index >= 0 && index < options.count {
                binding.set(options[index].value, in: menuContext)
            }
        case let .cards(binding, options):
            if index >= 0 && index < options.count {
                binding.set(options[index].value, in: menuContext)
            }
        default:
            break
        }
    }, queryUpdated: { query in
        updateState { state in
            state.query = query
        }
    }, dismissInput: {
        handle.controller?.view.endEditing(true)
    })

    let accountPeer: Signal<EnginePeer?, NoError> = .single(nil)
    |> then(context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)))

    let focusTag: ItemListItemTag? = focusRowId.flatMap { rowId in
        return GGMenuEntryTag(id: storage.groupByChildId[rowId] ?? rowId)
    }

    // Runtime rows of this screen's sections, one signal for all of them (none — a constant).
    let dynamicRows = ggMenuDynamicRows(screen: screen, context: context, handle: handle)

    // One signal per screen: presentation data + the settings revision + the GG language + this
    // screen's state (+ its runtime rows). The subscription belongs to the ItemListController and
    // dies with it.
    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        GGSettingsStore.shared.revision,
        GGLocalization.shared.languageCodeSignal,
        statePromise.get(),
        accountPeer,
        dynamicRows
    )
    |> map { presentationData, _, _, state, accountPeer, dynamicRows -> (ItemListControllerState, (ItemListNodeState, GGMenuScreenArguments)) in
        let menuContext = GGMenuContext(context: context, presentationData: presentationData, accountPeer: accountPeer, drafts: state.drafts, handle: handle)
        holder.menuContext = menuContext
        holder.token += 1
        var dynamicRowsById: [String: GGMenuRow] = [:]
        for rows in dynamicRows.values {
            for row in rows {
                assert(storage.rowsById[row.id] == nil, "GGMenu: dynamic row \(row.id) clashes with a registered row")
                dynamicRowsById[row.id] = row
            }
        }
        holder.dynamicRowsById = dynamicRowsById

        let built = ggBuildMenuEntries(screen: screen, tab: tabDescriptor, menuContext: menuContext, state: state, dynamicRows: dynamicRows, token: holder.token)
        holder.results = built.results

        let title: ItemListControllerTitle
        switch screen {
        case .root:
            title = .text("")
        case let .category(category):
            title = .text(category.title)
        case .tab:
            let tabTitle = tabDescriptor?.title() ?? ""
            if let segments = tabDescriptor?.segments, !segments.isEmpty {
                title = .textWithTabs(tabTitle, segments.map { $0.title() }, min(state.segmentIndex, segments.count - 1))
            } else {
                title = .text(tabTitle)
            }
        }

        var rightNavigationButton: ItemListNavigationButton?
        if built.resettable.contains(where: { !$0.isDefault(menuContext) }) {
            rightNavigationButton = ItemListNavigationButton(content: .text(GGStrings.Menu.Common.reset), style: .regular, enabled: true, action: {
                ggConfirmScreenReset(bindings: built.resettable, menuContext: menuContext)
            })
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: title, leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: built.entries, style: .blocks, ensureVisibleItemTag: focusTag, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    handle.controller = controller
    controller.titleControlValueChanged = { index in
        updateState { state in
            state.segmentIndex = index
        }
    }

    if let focusTag {
        var didHighlight = false
        controller.afterTransactionCompleted = { [weak controller] in
            guard !didHighlight, let controller else {
                return
            }
            controller.forEachItemNode { itemNode in
                if let itemNode = itemNode as? ItemListItemNode, let tag = itemNode.tag, tag.isEqual(to: focusTag) {
                    didHighlight = true
                    itemNode.displayHighlight()
                }
            }
        }
    }

    return controller
}

struct GGMenuBuildResult {
    var entries: [GGMenuEntry] = []
    var resettable: [GGMenuAnyBinding] = []
    var results: [GGMenuSearchEntry] = []
}

/// The runtime rows of the screen's sections, by section, as one signal.
private func ggMenuDynamicRows(screen: GGMenuScreenID, context: AccountContext, handle: GGMenuScreenHandle) -> Signal<[GGMenuSectionID: [GGMenuRow]], NoError> {
    let storage = GGMenuStorage.shared
    var signals: [Signal<(GGMenuSectionID, [GGMenuRow]), NoError>] = []
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let providerContext = GGMenuContext(context: context, presentationData: presentationData, accountPeer: nil, drafts: [:], handle: handle)
    for section in storage.sections(for: screen) {
        guard let providers = storage.dynamicRowProviders[section.id] else {
            continue
        }
        for provider in providers {
            let sectionId = section.id
            signals.append(provider(providerContext)
            |> map { rows -> (GGMenuSectionID, [GGMenuRow]) in
                return (sectionId, rows)
            })
        }
    }
    if signals.isEmpty {
        return .single([:])
    }
    return combineLatest(signals)
    |> map { values -> [GGMenuSectionID: [GGMenuRow]] in
        var result: [GGMenuSectionID: [GGMenuRow]] = [:]
        for (sectionId, rows) in values {
            result[sectionId, default: []].append(contentsOf: rows)
        }
        return result
    }
}

/// Whether a screen would show anything. Tabs without rows are not linked (no dead screens); the
/// demo registration switches this off to show the whole skeleton.
func ggMenuScreenHasContent(_ screen: GGMenuScreenID, menuContext: GGMenuContext, depth: Int = 0) -> Bool {
    let storage = GGMenuStorage.shared
    if storage.showsEmptyTabs {
        return true
    }
    if depth > 8 {
        return false
    }
    if case let .tab(tabId) = screen, let tab = storage.tabs[tabId], tab.makeScreen != nil {
        return true
    }
    for section in storage.sections(for: screen) {
        if let isVisible = section.isVisible, !isVisible(menuContext) {
            continue
        }
        // Runtime rows are not known here: such a section always counts as content.
        if storage.hasDynamicRows(in: section.id) {
            return true
        }
        for row in storage.rows(in: section.id) {
            if ggMenuRowIsVisible(row, menuContext: menuContext, depth: depth + 1) {
                return true
            }
        }
    }
    return false
}

func ggMenuRowIsVisible(_ row: GGMenuRow, menuContext: GGMenuContext, depth: Int = 0) -> Bool {
    if let isVisible = row.isVisible, !isVisible(menuContext) {
        return false
    }
    if case let .tab(tabId) = row.kind {
        return ggMenuScreenHasContent(.tab(tabId), menuContext: menuContext, depth: depth)
    }
    return true
}

private func ggBuildMenuEntries(screen: GGMenuScreenID, tab: GGMenuTabDescriptor?, menuContext: GGMenuContext, state: GGMenuScreenState, dynamicRows: [GGMenuSectionID: [GGMenuRow]], token: Int) -> GGMenuBuildResult {
    var result = GGMenuBuildResult()
    switch screen {
    case .root:
        ggBuildRootEntries(menuContext: menuContext, state: state, result: &result)
    case .category, .tab:
        ggBuildSectionEntries(screen: screen, tab: tab, menuContext: menuContext, state: state, dynamicRows: dynamicRows, token: token, result: &result)
    }
    return result
}

private func ggBuildRootEntries(menuContext: GGMenuContext, state: GGMenuScreenState, result: inout GGMenuBuildResult) {
    // «Версия 13.0 (186)»: the build number follows the version, as on the About screen.
    result.entries.append(GGMenuEntry(id: .header, key: GGMenuSortKey(section: 0, rank: 1, order: 0, tie: ""), section: 0, payload: .header(title: GGStrings.Menu.title, version: GGStrings.Menu.Root.version(version: ggAppVersionString())), menuContext: menuContext))
    result.entries.append(GGMenuEntry(id: .search, key: GGMenuSortKey(section: 1, rank: 1, order: 0, tie: ""), section: 1, payload: .search(text: state.query, placeholder: GGStrings.Menu.Root.searchPlaceholder), menuContext: menuContext))

    let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
        let results = ggMenuSearch(query: query, menuContext: menuContext)
        result.results = results
        if results.isEmpty {
            result.entries.append(GGMenuEntry(id: .empty, key: GGMenuSortKey(section: 2, rank: 2, order: 0, tie: ""), section: 2, payload: .footer(GGStrings.Menu.Search.noResults), menuContext: menuContext))
        } else {
            for (index, entry) in results.enumerated() {
                result.entries.append(GGMenuEntry(id: .result(index), key: GGMenuSortKey(section: 2, rank: 1, order: index, tie: ""), section: 2, payload: .navigation(title: entry.title, subtitle: entry.path.joined(separator: " › "), label: nil, icon: entry.icon, enabled: true, destructive: false), menuContext: menuContext))
            }
        }
        return
    }

    var categoryEntries: [GGMenuEntry] = []
    for (index, category) in GGMenuCategory.allCases.enumerated() {
        if !ggMenuScreenHasContent(.category(category), menuContext: menuContext) {
            continue
        }
        categoryEntries.append(GGMenuEntry(id: .category(category.rawValue), key: GGMenuSortKey(section: 3, rank: 1, order: index, tie: ""), section: 3, payload: .navigation(title: category.title, subtitle: category.subtitle, label: nil, icon: category.icon, enabled: true, destructive: false), menuContext: menuContext))
    }
    if !categoryEntries.isEmpty {
        result.entries.append(GGMenuEntry(id: .sectionHeader("root.categories"), key: GGMenuSortKey(section: 3, rank: 0, order: 0, tie: ""), section: 3, payload: .sectionHeader(GGStrings.Menu.Root.categories), menuContext: menuContext))
        result.entries.append(contentsOf: categoryEntries)
    }

    result.entries.append(GGMenuEntry(id: .sectionHeader("root.links"), key: GGMenuSortKey(section: 4, rank: 0, order: 0, tie: ""), section: 4, payload: .sectionHeader(GGStrings.Menu.Root.links), menuContext: menuContext))
    for (index, link) in ggMenuLinks.enumerated() {
        result.entries.append(GGMenuEntry(id: .link(link.id), key: GGMenuSortKey(section: 4, rank: 1, order: index, tie: ""), section: 4, payload: .navigation(title: ggMenuLinkTitle(link.id), subtitle: nil, label: link.username, icon: link.icon, enabled: true, destructive: false), menuContext: menuContext))
    }
    result.entries.append(GGMenuEntry(id: .sectionFooter("root.links"), key: GGMenuSortKey(section: 4, rank: 2, order: 0, tie: ""), section: 4, payload: .footer(GGStrings.Menu.Root.footer(version: ggAppVersionString())), menuContext: menuContext))
}

private func ggBuildSectionEntries(screen: GGMenuScreenID, tab: GGMenuTabDescriptor?, menuContext: GGMenuContext, state: GGMenuScreenState, dynamicRows: [GGMenuSectionID: [GGMenuRow]], token: Int, result: inout GGMenuBuildResult) {
    let storage = GGMenuStorage.shared
    var sectionIndex: ItemListSectionId = 0

    if let tab, let topView = tab.topView {
        result.entries.append(GGMenuEntry(id: .topView, key: GGMenuSortKey(section: Int.min, rank: 1, order: 0, tie: ""), section: sectionIndex, payload: .topView(content: topView.content, text: topView.text()), menuContext: menuContext))
        sectionIndex += 1
    }

    var selectedSegment: String?
    if let segments = tab?.segments, !segments.isEmpty {
        selectedSegment = segments[max(0, min(state.segmentIndex, segments.count - 1))].id
    }

    var emittedAnySection = false
    for section in storage.sections(for: screen) {
        if let segment = section.segment, let selectedSegment, segment != selectedSegment {
            continue
        }
        if let isVisible = section.isVisible, !isVisible(menuContext) {
            continue
        }
        var rowContext = menuContext
        rowContext.sectionId = sectionIndex

        var rowEntries: [GGMenuEntry] = []
        var sectionBindings: [GGMenuAnyBinding] = []
        for row in storage.rows(in: section.id) {
            if !ggMenuRowIsVisible(row, menuContext: rowContext) {
                continue
            }
            let payload = ggMenuRowPayload(row: row, menuContext: rowContext, state: state, token: token)
            rowEntries.append(GGMenuEntry(id: .row(row.id), key: GGMenuSortKey(section: section.order, sectionTie: section.id.rawValue, rank: 1, order: row.order, tie: row.id), section: sectionIndex, payload: payload, menuContext: rowContext))
            sectionBindings.append(contentsOf: row.anyBindings)
        }
        // Runtime rows: after the registered ones by `order`, never in the navbar reset.
        if let sectionDynamicRows = dynamicRows[section.id] {
            for row in sectionDynamicRows {
                if !ggMenuRowIsVisible(row, menuContext: rowContext) {
                    continue
                }
                let payload = ggMenuRowPayload(row: row, menuContext: rowContext, state: state, token: token)
                rowEntries.append(GGMenuEntry(id: .row(row.id), key: GGMenuSortKey(section: section.order, sectionTie: section.id.rawValue, rank: 1, order: row.order, tie: row.id), section: sectionIndex, payload: payload, menuContext: rowContext))
            }
            rowEntries.sort(by: { $0.key < $1.key })
        }
        if rowEntries.isEmpty {
            continue
        }
        emittedAnySection = true
        result.resettable.append(contentsOf: sectionBindings)

        if let header = section.header {
            result.entries.append(GGMenuEntry(id: .sectionHeader(section.id.rawValue), key: GGMenuSortKey(section: section.order, sectionTie: section.id.rawValue, rank: 0, order: 0, tie: ""), section: sectionIndex, payload: .sectionHeader(header()), menuContext: rowContext))
        }
        result.entries.append(contentsOf: rowEntries)

        var footerParts: [String] = []
        if let footer = section.footer?(rowContext), !footer.isEmpty {
            footerParts.append(footer)
        }
        if sectionBindings.contains(where: { $0.isPendingRestart(rowContext) }) {
            footerParts.append(GGStrings.Core.requiresRestartFooter)
        }
        if !footerParts.isEmpty {
            result.entries.append(GGMenuEntry(id: .sectionFooter(section.id.rawValue), key: GGMenuSortKey(section: section.order, sectionTie: section.id.rawValue, rank: 2, order: 0, tie: ""), section: sectionIndex, payload: .footer(footerParts.joined(separator: "\n\n")), menuContext: rowContext))
        }
        sectionIndex += 1
    }

    if !emittedAnySection {
        result.entries.append(GGMenuEntry(id: .empty, key: GGMenuSortKey(section: Int.max, rank: 2, order: 0, tie: ""), section: sectionIndex, payload: .footer(GGStrings.Menu.Common.emptyTab), menuContext: menuContext))
    }
}

private func ggMenuRowPayload(row: GGMenuRow, menuContext: GGMenuContext, state: GGMenuScreenState, token: Int) -> GGMenuEntryPayload {
    let enabled = row.isEnabled?(menuContext) ?? true
    let subtitle = row.subtitle?()
    switch row.kind {
    case let .toggle(binding):
        return .toggle(title: row.title(), subtitle: subtitle, icon: row.icon, value: binding.value(in: menuContext), enabled: enabled)
    case let .choice(binding, options):
        let current = binding.value(in: menuContext)
        let valueTitle = options.first(where: { $0.value == current })?.title() ?? current
        return .choice(title: row.title(), subtitle: subtitle, icon: row.icon, valueTitle: valueTitle, enabled: enabled)
    case let .slider(binding, range, step, _):
        return .slider(title: row.title(), value: menuContext.displayValue(binding), lower: range.lowerBound, upper: range.upperBound, step: step, enabled: enabled)
    case .tab, .action:
        return .navigation(title: row.title(), subtitle: subtitle, label: row.label?(menuContext), icon: row.icon, enabled: enabled, destructive: row.isDestructive)
    case let .expandableGroup(master, children):
        let childPayloads = ggMenuGroupChildPayloads(children, menuContext: menuContext)
        return .group(title: row.title(), icon: row.icon, value: master.value(in: menuContext), expanded: state.expandedGroups.contains(row.id), children: childPayloads, enabled: enabled)
    case let .expandableList(children, summary):
        let childPayloads = ggMenuGroupChildPayloads(children, menuContext: menuContext)
        let count = GGMenuGroupCount(values: childPayloads.map { $0.value })
        return .list(title: row.title(), icon: row.icon, summary: count.summary(summary), expanded: state.expandedGroups.contains(row.id), children: childPayloads, enabled: enabled)
    case let .preview(preview):
        switch preview {
        case let .miniChat(configuration):
            var previewContext = menuContext
            previewContext.previewScope = configuration.scope
            var content = configuration.content(previewContext)
            content.messages = GGPreviewModifiers.applyChat(content.messages, context: previewContext)
            return .miniChat(content: content, accountPeer: menuContext.accountPeer, height: configuration.height, token: configuration.isLive ? token : nil)
        case let .miniChatList(configuration):
            var previewContext = menuContext
            previewContext.previewScope = configuration.scope
            let rows = GGPreviewModifiers.applyChatList(configuration.rows(previewContext), context: previewContext)
            return .miniChatList(rows: rows, height: configuration.height)
        case let .custom(height, _):
            return .customPreview(height: height, token: token)
        }
    case .custom:
        return .custom(token: token)
    case let .discreteChoice(binding, options):
        let current = binding.value(in: menuContext)
        return .discrete(labels: options.map { $0.title() }, selectedIndex: options.firstIndex(where: { $0.value == current }) ?? 0, enabled: enabled)
    case let .cards(binding, options):
        let current = binding.value(in: menuContext)
        return .cards(titles: options.map { $0.title() }, selectedIndex: options.firstIndex(where: { $0.value == current }) ?? 0, enabled: enabled)
    }
}

/// The visible toggle children of an expandable row, as its item draws them.
private func ggMenuGroupChildPayloads(_ children: [GGMenuRow], menuContext: GGMenuContext) -> [GGMenuGroupChildPayload] {
    var result: [GGMenuGroupChildPayload] = []
    for child in children {
        if let isVisible = child.isVisible, !isVisible(menuContext) {
            continue
        }
        if case let .toggle(binding) = child.kind {
            result.append(GGMenuGroupChildPayload(id: child.id, title: child.title(), value: binding.value(in: menuContext), enabled: child.isEnabled?(menuContext) ?? true))
        }
    }
    return result
}

/// ≤ 6 options → action sheet with checkmarks; more → a list screen.
private func ggPresentChoice(row: GGMenuRow, binding: GGMenuBinding<String>, options: [GGMenuChoiceOption], menuContext: GGMenuContext) {
    let current = binding.value(in: menuContext)
    if options.count > 6 {
        menuContext.push(ggMakeChoiceListController(context: menuContext.context, title: row.title(), options: options, binding: binding, menuContext: menuContext))
        return
    }
    let presentationData = menuContext.presentationData
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var items: [ActionSheetItem] = [ActionSheetTextItem(title: row.title(), parseMarkdown: false)]
    for option in options {
        items.append(ActionSheetCheckboxItem(title: option.title(), label: "", value: option.value == current, action: { [weak actionSheet] _ in
            actionSheet?.dismissAnimated()
            binding.set(option.value, in: menuContext)
        }))
    }
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    menuContext.present(actionSheet)
}

private func ggConfirmScreenReset(bindings: [GGMenuAnyBinding], menuContext: GGMenuContext) {
    let presentationData = menuContext.presentationData
    menuContext.present(textAlertController(context: menuContext.context, title: GGStrings.Menu.Common.resetTitle, text: GGStrings.Menu.Common.resetText, actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: GGStrings.Menu.Common.reset, action: {
            for binding in bindings {
                binding.reset(menuContext)
            }
        })
    ]))
}
