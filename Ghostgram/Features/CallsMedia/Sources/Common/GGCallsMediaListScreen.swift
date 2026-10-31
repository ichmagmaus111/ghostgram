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

/// One list screen for the zone's libraries (sounds, call recordings, the feed's chats): action rows
/// on top, the items, a footer. Rebuilt from one signal — settings revision, presentation data, the
/// language and the screen's own `extra` data; everything else goes through closures.
struct GGMediaListItem: Equatable {
    let id: String
    let title: String
    let label: String
    let peer: EnginePeer?

    init(id: String, title: String, label: String = "", peer: EnginePeer? = nil) {
        self.id = id
        self.title = title
        self.label = label
        self.peer = peer
    }
}

struct GGMediaListAction {
    let id: String
    let title: String
    let action: () -> Void
}

struct GGMediaListContent {
    let title: String
    let actions: [GGMediaListAction]
    let emptyText: String
    let footer: String?
    let items: [GGMediaListItem]
}

private final class GGMediaListArguments {
    let context: AccountContext
    var actions: [String: () -> Void] = [:]
    let select: (String) -> Void

    init(context: AccountContext, select: @escaping (String) -> Void) {
        self.context = context
        self.select = select
    }
}

private enum GGMediaListEntry: ItemListNodeEntry {
    case action(Int, String, String)
    case item(Int, GGMediaListItem)
    case empty(String)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .action:
            return 0
        case .item, .empty, .footer:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case let .action(index, _, _):
            return index
        case .empty:
            return 1000
        case let .item(index, _):
            return 2000 + index
        case .footer:
            return Int.max
        }
    }

    static func ==(lhs: GGMediaListEntry, rhs: GGMediaListEntry) -> Bool {
        switch lhs {
        case let .action(index, id, title):
            if case .action(index, id, title) = rhs {
                return true
            }
            return false
        case let .item(index, item):
            if case let .item(rhsIndex, rhsItem) = rhs, index == rhsIndex, item == rhsItem {
                return true
            }
            return false
        case let .empty(text):
            if case .empty(text) = rhs {
                return true
            }
            return false
        case let .footer(text):
            if case .footer(text) = rhs {
                return true
            }
            return false
        }
    }

    static func <(lhs: GGMediaListEntry, rhs: GGMediaListEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! GGMediaListArguments
        switch self {
        case let .action(_, id, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.actions[id]?()
            })
        case let .item(_, item):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: item.peer == nil ? nil : arguments.context, iconPeer: item.peer, title: item.title, label: item.label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.select(item.id)
            })
        case let .empty(text), let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// `content` is evaluated on every rebuild; `extra` adds the screen's own data (peers, files).
func ggMakeMediaListScreen(context: AccountContext, extra: Signal<Void, NoError> = .single(Void()), content: @escaping () -> GGMediaListContent, select: @escaping (String) -> Void) -> ViewController {
    let arguments = GGMediaListArguments(context: context, select: select)
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, GGSettingsStore.shared.revision, GGLocalization.shared.languageCodeSignal, extra)
    |> map { presentationData, _, _, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let value = content()
        var entries: [GGMediaListEntry] = []
        var actions: [String: () -> Void] = [:]
        for (index, action) in value.actions.enumerated() {
            entries.append(.action(index, action.id, action.title))
            actions[action.id] = action.action
        }
        arguments.actions = actions
        if value.items.isEmpty {
            entries.append(.empty(value.emptyText))
        } else {
            for (index, item) in value.items.enumerated() {
                entries.append(.item(index, item))
            }
        }
        if let footer = value.footer {
            entries.append(.footer(footer))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(value.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}

/// Action sheet with plain buttons and Cancel.
func ggPresentMediaActionSheet(context: AccountContext, title: String?, actions: [(title: String, isDestructive: Bool, action: () -> Void)], present: (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var items: [ActionSheetItem] = []
    if let title = title {
        items.append(ActionSheetTextItem(title: title, parseMarkdown: false))
    }
    for item in actions {
        let action = item.action
        items.append(ActionSheetButtonItem(title: item.title, color: item.isDestructive ? .destructive : .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            action()
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
    present(actionSheet)
}
