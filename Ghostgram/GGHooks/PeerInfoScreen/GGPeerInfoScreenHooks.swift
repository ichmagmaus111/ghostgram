// Compiled into PeerInfoScreen (filegroup //Ghostgram/GGHooks:PeerInfoScreenHookSources):
// maps the public points (GGSettingsTabHooks, GGPeerInfoHooks) to PeerInfoScreen's internal
// item types. No feature logic.

import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import GGCore
import GGHooks

/// Sections Ghostgram adds to the Settings tab.
struct GGSettingsTabSections {
    /// Right below «Мой профиль» (shortcuts).
    var afterMyProfile: [(AnyHashable, [PeerInfoScreenItem])] = []
    /// At the end of the tab.
    var bottom: [(AnyHashable, [PeerInfoScreenItem])] = []
}

/// GHOST hook target: `settingsItems(...)` in PeerInfoSettingsItems.swift, before the sections are
/// assembled: hides Telegram's rows features asked to hide, reorders them, adds Ghostgram's rows.
func ggApplySettingsTabHooks(_ items: inout [SettingsSection: [PeerInfoScreenItem]], context: AccountContext, presentationData: PresentationData) -> GGSettingsTabSections {
    var sections = GGSettingsTabSections()
    // Rows with a section of their own come first after «Мой профиль» (the «Ghostgram» entry).
    for row in GGSettingsTabHooks.visibleRows(placement: .ownSectionAfterMyProfile, context: context) {
        sections.afterMyProfile.append(("gg.section.\(row.id)" as AnyHashable, [PeerInfoScreenDisclosureItem(id: "gg.\(row.id)", text: row.title(), icon: row.icon(presentationData.theme), action: {
            row.action(context, context.sharedContext.mainWindow?.viewController as? NavigationController)
        })]))
    }
    if !GGSettingsTabHooks.hiddenItem.isEmpty {
        for section in SettingsSection.allCases {
            guard let sectionItems = items[section] else {
                continue
            }
            let sectionName = "\(section)"
            items[section] = sectionItems.filter { item in
                return !GGSettingsTabHooks.isItemHidden(GGSettingsTabItemKey(section: sectionName, itemId: item.id), context: context)
            }
        }
    }
    if !GGSettingsTabHooks.itemOrder.isEmpty {
        for section in SettingsSection.allCases {
            guard let sectionItems = items[section], sectionItems.count > 1 else {
                continue
            }
            var ids = sectionItems.map { $0.id }
            for handler in GGSettingsTabHooks.itemOrder.handlers {
                ids = handler("\(section)", ids, context)
            }
            var byId: [AnyHashable: PeerInfoScreenItem] = [:]
            for item in sectionItems where byId[item.id] == nil {
                byId[item.id] = item
            }
            let reordered = ids.compactMap { byId[$0] }
            if reordered.count == sectionItems.count && Set(ids).count == ids.count {
                items[section] = reordered
            }
        }
    }
    if !GGSettingsTabHooks.dynamicRows.isEmpty {
        let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController
        var dynamicItems: [PeerInfoScreenItem] = []
        for handler in GGSettingsTabHooks.dynamicRows.handlers {
            for row in handler(context, presentationData) {
                dynamicItems.append(PeerInfoScreenDisclosureItem(id: "gg.dynamic.\(row.id)", label: row.label.flatMap { .text($0) } ?? .none, text: row.title, icon: row.icon, action: {
                    row.action(context, navigationController ?? (context.sharedContext.mainWindow?.viewController as? NavigationController))
                }))
            }
        }
        if !dynamicItems.isEmpty {
            sections.afterMyProfile.append(("gg.dynamic" as AnyHashable, dynamicItems))
        }
    }
    if GGSettingsTabHooks.rows.isEmpty {
        return sections
    }
    func makeItem(_ row: GGSettingsTabRow) -> PeerInfoScreenItem {
        return PeerInfoScreenDisclosureItem(id: "gg.\(row.id)", text: row.title(), icon: row.icon(presentationData.theme), action: {
            row.action(context, context.sharedContext.mainWindow?.viewController as? NavigationController)
        })
    }
    let above = GGSettingsTabHooks.visibleRows(placement: .aboveMyProfile, context: context).map(makeItem)
    let below = GGSettingsTabHooks.visibleRows(placement: .belowMyProfile, context: context).map(makeItem)
    if !above.isEmpty || !below.isEmpty {
        items[.myProfile] = above + (items[.myProfile] ?? []) + below
    }
    let bottom = GGSettingsTabHooks.visibleRows(placement: .bottom, context: context).map(makeItem)
    if !bottom.isEmpty {
        sections.bottom.append(("gg.bottom" as AnyHashable, bottom))
    }
    return sections
}

/// GHOST hook target: the end of `settingsItems(...)`: Ghostgram's sections go to their places.
func ggInsertSettingsTabSections(_ result: inout [(AnyHashable, [PeerInfoScreenItem])], _ sections: GGSettingsTabSections) {
    if !sections.afterMyProfile.isEmpty {
        var index = 0
        for (offset, entry) in result.enumerated() {
            if let section = entry.0.base as? SettingsSection, section.rawValue <= SettingsSection.myProfile.rawValue {
                index = offset + 1
            }
        }
        result.insert(contentsOf: sections.afterMyProfile, at: index)
    }
    result.append(contentsOf: sections.bottom)
}

/// GHOST hook target: PeerInfoScreen — the Settings tab is rebuilt when a feature changed what it
/// shows (`GGSettingsTabHooks.invalidate()`), not only when Telegram's data changes.
func ggSettingsTabRefreshing<T>(_ signal: Signal<T, NoError>) -> Signal<T, NoError> {
    if !GGSettingsTabHooks.changesTab {
        return signal
    }
    return combineLatest(signal, GGSettingsTabHooks.revision)
    |> map { value, _ -> T in
        return value
    }
}

/// The group the profile was opened from (a member's profile opened from a group message).
func ggPeerInfoSourceChatPeerId(_ interaction: PeerInfoInteraction) -> EnginePeer.Id? {
    return ggPeerInfoSourceMessageId(interaction)?.peerId
}

/// The message the profile was opened from (a tap on its author), if any.
func ggPeerInfoSourceMessageId(_ interaction: PeerInfoInteraction) -> EngineMessage.Id? {
    return (interaction.getController() as? PeerInfoScreenImpl)?.controllerNode.sourceMessageId
}

/// The point context of a profile's info items; nil before the peer is known.
func ggPeerInfoContext(data: PeerInfoScreenData, context: AccountContext, interaction: PeerInfoInteraction) -> GGPeerInfoContext? {
    guard let peer = data.peer else {
        return nil
    }
    let sourceMessageId = ggPeerInfoSourceMessageId(interaction)
    return GGPeerInfoContext(context: context, peer: peer, chatPeer: data.chatPeer, isSettings: false, controller: interaction.getController(), sourceChatPeerId: sourceMessageId?.peerId, sourceMessageId: sourceMessageId, cachedData: data.cachedData)
}

/// GHOST hook target: `infoItems(...)` in PeerInfoProfileItems.swift — Telegram's items features hide.
func ggPeerInfoHidesItem(_ kind: GGPeerInfoItemKind, data: PeerInfoScreenData, context: AccountContext, interaction: PeerInfoInteraction) -> Bool {
    return GGPeerInfoHooks.hidesItem(kind, context: ggPeerInfoContext(data: data, context: context, interaction: interaction))
}

/// GHOST hook target: `infoItems(...)` in PeerInfoProfileItems.swift: feature rows (ID, DC, dates).
func ggAppendPeerInfoRows(_ items: inout [PeerInfoScreenItem], data: PeerInfoScreenData, context: AccountContext, interaction: PeerInfoInteraction) {
    if GGPeerInfoHooks.infoRows.isEmpty {
        return
    }
    guard let peerInfoContext = ggPeerInfoContext(data: data, context: context, interaction: interaction) else {
        return
    }
    let rows = GGPeerInfoHooks.rows(context: peerInfoContext)
    // A comment closes its card (a bot's «Открывая это мини-приложение…» under «Открыть приложение»):
    // rows after it got the card's background drawn over the comment. They go in front of it.
    var insertionIndex = items.count
    while insertionIndex > 0 && items[insertionIndex - 1] is PeerInfoScreenCommentItem {
        insertionIndex -= 1
    }
    for row in rows {
        var itemAction: ((ASDisplayNode, Promise<Bool>?) -> Void)?
        if let action = row.action {
            itemAction = { _, _ in
                action()
            }
        }
        var itemLongTapAction: ((ASDisplayNode) -> Void)?
        if let longTapAction = row.longTapAction {
            itemLongTapAction = { _ in
                longTapAction()
            }
        }
        items.insert(PeerInfoScreenLabeledValueItem(id: "gg.\(row.id)", label: row.label, rightLabel: row.rightLabel, text: row.text, action: itemAction, longTapAction: itemLongTapAction, requestLayout: { animated in
            interaction.requestLayout(animated)
        }), at: insertionIndex)
        insertionIndex += 1
    }
}

/// GHOST hook target: `PeerInfoScreenNode`, right after `paneContainerNode.update(...)` — the shared
/// media area as features see it (GGPeerInfoHooks.paneContainerDidLayout). Without handlers: nothing.
func ggPeerInfoPaneContainerDidLayout(_ node: PeerInfoScreenNode) {
    if GGPeerInfoHooks.paneContainerDidLayout.isEmpty {
        return
    }
    let hasPanes = !node.state.isEditing && !(node.data?.availablePanes ?? []).isEmpty
    let layout = GGPeerInfoPaneLayout(context: node.context, peerId: node.peerId, isSettings: node.isSettings, hasPanes: hasPanes, paneContainer: node.paneContainerNode, controller: node.controller)
    for handler in GGPeerInfoHooks.paneContainerDidLayout.handlers {
        handler(layout)
    }
}
