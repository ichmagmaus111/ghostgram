import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import UndoUI
import GGCore

/// One row of a zone screen. The zone's editors (tab bar, Settings tab, shortcuts, icon packs,
/// badges, reactions) are plain ItemListController lists built from these.
enum GGListRow: Equatable {
    case header(String)
    case footer(String)
    case toggle(id: String, title: String, value: Bool, enabled: Bool)
    case disclosure(id: String, title: String, label: String, icon: UIImage?)
    /// Moved by dragging its grip; `GGListActions.reorder` gets the section's new order.
    case reorderable(id: String, title: String, label: String)
    case peer(id: String, peer: EnginePeer, title: String, label: String)
    case check(id: String, title: String, subtitle: String?, checked: Bool)
    case action(id: String, title: String, isDestructive: Bool)
    case input(id: String, text: String, placeholder: String)

    static func ==(lhs: GGListRow, rhs: GGListRow) -> Bool {
        switch lhs {
        case let .header(text):
            if case .header(text) = rhs {
                return true
            }
            return false
        case let .footer(text):
            if case .footer(text) = rhs {
                return true
            }
            return false
        case let .toggle(id, title, value, enabled):
            if case .toggle(id, title, value, enabled) = rhs {
                return true
            }
            return false
        case let .disclosure(id, title, label, icon):
            if case let .disclosure(rhsId, rhsTitle, rhsLabel, rhsIcon) = rhs, id == rhsId, title == rhsTitle, label == rhsLabel, icon === rhsIcon {
                return true
            }
            return false
        case let .reorderable(id, title, label):
            if case .reorderable(id, title, label) = rhs {
                return true
            }
            return false
        case let .peer(id, peer, title, label):
            if case .peer(id, peer, title, label) = rhs {
                return true
            }
            return false
        case let .check(id, title, subtitle, checked):
            if case .check(id, title, subtitle, checked) = rhs {
                return true
            }
            return false
        case let .action(id, title, isDestructive):
            if case .action(id, title, isDestructive) = rhs {
                return true
            }
            return false
        case let .input(id, text, placeholder):
            if case .input(id, text, placeholder) = rhs {
                return true
            }
            return false
        }
    }

    fileprivate var rowId: String {
        switch self {
        case let .header(text):
            return "header." + text
        case let .footer(text):
            return "footer." + text
        case let .toggle(id, _, _, _), let .disclosure(id, _, _, _), let .reorderable(id, _, _), let .peer(id, _, _, _), let .check(id, _, _, _), let .action(id, _, _), let .input(id, _, _):
            return id
        }
    }

    fileprivate var reorderableId: String? {
        if case let .reorderable(id, _, _) = self {
            return id
        }
        return nil
    }
}

struct GGListSection: Equatable {
    var rows: [GGListRow]

    init(_ rows: [GGListRow]) {
        self.rows = rows
    }
}

/// What a row does. `select` gets the row id of disclosure/reorderable/peer/check/action rows;
/// `reorder` gets the ids of one section's reorderable rows in their new order when a drag ends.
final class GGListActions {
    let toggle: (String, Bool) -> Void
    let select: (String) -> Void
    let textChanged: (String, String) -> Void
    let reorder: ([String]) -> Void

    init(toggle: @escaping (String, Bool) -> Void = { _, _ in }, select: @escaping (String) -> Void = { _ in }, textChanged: @escaping (String, String) -> Void = { _, _ in }, reorder: @escaping ([String]) -> Void = { _ in }) {
        self.toggle = toggle
        self.select = select
        self.textChanged = textChanged
        self.reorder = reorder
    }
}

/// The order a drag in progress has given to a section's reorderable rows. Shown instead of the
/// stored order until the finger is lifted, then stored once through `GGListActions.reorder`.
private final class GGListReorderState {
    var orders: [Int: [String]] = [:]
    let revision = ValuePromise<Int>(0, ignoreRepeated: false)
    private var counter = 0

    func update() {
        self.counter += 1
        self.revision.set(self.counter)
    }

    /// Puts the section's reorderable rows into the dragged order; other rows keep their places.
    func apply(to rows: [GGListRow], section: Int) -> [GGListRow] {
        guard let order = self.orders[section] else {
            return rows
        }
        let present = rows.compactMap { $0.reorderableId }
        guard present.count == order.count, Set(present) == Set(order) else {
            self.orders.removeValue(forKey: section)
            return rows
        }
        var byId: [String: GGListRow] = [:]
        for row in rows {
            if let id = row.reorderableId {
                byId[id] = row
            }
        }
        var next = order.makeIterator()
        return rows.map { row -> GGListRow in
            if row.reorderableId != nil, let id = next.next(), let moved = byId[id] {
                return moved
            }
            return row
        }
    }
}

private struct GGListEntry: ItemListNodeEntry {
    let section: ItemListSectionId
    let order: Int
    let stableId: String
    let row: GGListRow
    let context: AccountContext

    static func ==(lhs: GGListEntry, rhs: GGListEntry) -> Bool {
        return lhs.section == rhs.section && lhs.order == rhs.order && lhs.stableId == rhs.stableId && lhs.row == rhs.row
    }

    static func <(lhs: GGListEntry, rhs: GGListEntry) -> Bool {
        return lhs.order < rhs.order
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let actions = arguments as! GGListActions
        switch self.row {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .toggle(id, title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                actions.toggle(id, value)
            })
        case let .disclosure(id, title, label, icon):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                actions.select(id)
            })
        case let .reorderable(id, title, label):
            return GGReorderableListItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, action: {
                actions.select(id)
            })
        case let .peer(id, peer, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: self.context, iconPeer: peer, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                actions.select(id)
            })
        case let .check(id, title, subtitle, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: subtitle, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                actions.select(id)
            })
        case let .action(id, title, isDestructive):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: isDestructive ? .destructive : .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                actions.select(id)
            })
        case let .input(id, text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                actions.textChanged(id, value)
            }, action: {})
        }
    }
}

/// A list screen of this zone. `sections` is re-evaluated whenever the presentation data, the
/// Ghostgram language, a setting (`revision`) or `update` changes. Right button optional.
/// `.reorderable` rows are dragged by their grip, within their own section only.
func ggMakeInterfaceList(
    context: AccountContext,
    title: @escaping () -> String,
    update: Signal<Void, NoError> = .single(Void()),
    sections: @escaping (PresentationData) -> [GGListSection],
    actions: GGListActions,
    rightButton: (() -> (title: String, action: () -> Void))? = nil
) -> ItemListController {
    let reorderState = GGListReorderState()
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, GGSettingsStore.shared.revision, GGLocalization.shared.languageCodeSignal, update, reorderState.revision.get())
    |> map { presentationData, _, _, _, _ -> (ItemListControllerState, (ItemListNodeState, GGListActions)) in
        var entries: [GGListEntry] = []
        var order = 0
        var seen = Set<String>()
        for (sectionIndex, section) in sections(presentationData).enumerated() {
            for row in reorderState.apply(to: section.rows, section: sectionIndex) {
                var stableId = "\(sectionIndex)." + row.rowId
                if seen.contains(stableId) {
                    stableId += ".\(order)"
                }
                seen.insert(stableId)
                entries.append(GGListEntry(section: ItemListSectionId(sectionIndex), order: order, stableId: stableId, row: row, context: context))
                order += 1
            }
        }
        var rightNavigationButton: ItemListNavigationButton?
        if let rightButton = rightButton?() {
            rightNavigationButton = ItemListNavigationButton(content: .text(rightButton.title), style: .bold, enabled: true, action: rightButton.action)
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title()), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, actions))
    }
    let controller = ItemListController(context: context, state: signal)
    // The list asks for one step at a time: the dragged row ends up at `toIndex`. Only its own
    // section's reorderable rows are reordered; a drop past a header, footer or another section
    // puts it first or last.
    controller.setReorderEntry({ (fromIndex: Int, toIndex: Int, entries: [GGListEntry]) -> Signal<Bool, NoError> in
        guard fromIndex >= 0, fromIndex < entries.count, toIndex >= 0, toIndex < entries.count, entries[fromIndex].row.reorderableId != nil else {
            return .single(false)
        }
        let section = entries[fromIndex].section
        let current = entries.filter { $0.section == section }.compactMap { $0.row.reorderableId }
        var moved = entries
        let entry = moved.remove(at: fromIndex)
        moved.insert(entry, at: toIndex)
        let updated = moved.filter { $0.section == section }.compactMap { $0.row.reorderableId }
        if updated == current {
            return .single(false)
        }
        reorderState.orders[Int(section)] = updated
        reorderState.update()
        return .single(true)
    })
    controller.setReorderCompleted({ (_: [GGListEntry]) -> Void in
        if reorderState.orders.isEmpty {
            return
        }
        let orders = reorderState.orders
        for section in orders.keys.sorted() {
            if let ids = orders[section] {
                actions.reorder(ids)
            }
        }
        reorderState.orders.removeAll()
        reorderState.update()
    })
    return controller
}

/// An action sheet with plain buttons and Cancel.
func ggPresentActionSheet(context: AccountContext, from controller: ViewController?, title: String? = nil, buttons: [(title: String, isDestructive: Bool, action: () -> Void)]) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var items: [ActionSheetItem] = []
    if let title {
        items.append(ActionSheetTextItem(title: title, parseMarkdown: false))
    }
    for button in buttons {
        items.append(ActionSheetButtonItem(title: button.title, color: button.isDestructive ? .destructive : .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            button.action()
        }))
    }
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        })])
    ])
    controller?.present(actionSheet, in: .window(.root))
}

/// «Удалить …?» with a destructive confirmation.
func ggConfirmDestructive(context: AccountContext, from controller: ViewController?, title: String, text: String, confirm: String, action: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller?.present(textAlertController(context: context, title: title, text: text, actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: confirm, action: action)
    ]), in: .window(.root))
}

/// A UIKit alert with one text field (titles, names, links). `nil` = cancelled.
func ggPresentTextPrompt(from controller: ViewController?, title: String, message: String? = nil, text: String, placeholder: String, keyboard: UIKeyboardType = .default, cancel: String, done: String, completion: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addTextField { field in
        field.text = text
        field.placeholder = placeholder
        field.keyboardType = keyboard
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        if keyboard == .URL {
            field.autocapitalizationType = .none
        }
    }
    alert.addAction(UIAlertAction(title: cancel, style: .cancel))
    alert.addAction(UIAlertAction(title: done, style: .default, handler: { [weak alert] _ in
        completion(alert?.textFields?.first?.text ?? "")
    }))
    ggPresentNative(alert, from: controller)
}

/// Presents a UIKit controller over the topmost presented controller of `controller`'s window.
func ggPresentNative(_ native: UIViewController, from controller: ViewController?) {
    guard let rootController = controller?.view.window?.rootViewController else {
        return
    }
    var presenter = rootController
    while let presented = presenter.presentedViewController {
        presenter = presented
    }
    if let popover = native.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0.0, height: 0.0)
        popover.permittedArrowDirections = []
    }
    presenter.present(native, animated: true)
}

/// Moves an element one step up or down; returns nil at the edge.
func ggMoved<T>(_ array: [T], index: Int, by delta: Int) -> [T]? {
    let target = index + delta
    guard index >= 0, index < array.count, target >= 0, target < array.count else {
        return nil
    }
    var result = array
    let item = result.remove(at: index)
    result.insert(item, at: target)
    return result
}

/// A short bottom toast.
func ggToast(context: AccountContext, text: String) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
        return false
    })
}
