import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import AlertUI
import UndoUI

// The list screens of this module (badge screen, fake gifts, export): a screen is a signal of rows
// with stable ids; what a row does is looked up by id in tables rebuilt together with the rows.
// Rows compare only what they draw.

/// An image compared by identity (images are cached, so the same picture is the same object).
struct GGPEImage: Equatable {
    let image: UIImage

    static func ==(lhs: GGPEImage, rhs: GGPEImage) -> Bool {
        return lhs.image === rhs.image
    }
}

struct GGPERow: Equatable {
    enum Kind: Equatable {
        case header(String)
        case footer(String)
        case info(String)
        case action(title: String, destructive: Bool, enabled: Bool)
        case disclosure(title: String, label: String, icon: GGPEImage?, enabled: Bool)
        case peer(title: String, label: String, peer: EnginePeer?)
        case toggle(title: String, value: Bool, enabled: Bool)
        case check(title: String, subtitle: String?, checked: Bool)
        case input(text: String, placeholder: String)
        case multilineInput(text: String, placeholder: String)
    }

    let id: String
    let kind: Kind
}

struct GGPEScreenModel {
    var title: String
    var sections: [[GGPERow]] = []
    var tap: [String: () -> Void] = [:]
    var text: [String: (String) -> Void] = [:]
    var toggle: [String: (Bool) -> Void] = [:]
    var rightButton: (title: String, enabled: Bool, action: () -> Void)?

    init(title: String) {
        self.title = title
    }
}

final class GGPEHandlers {
    var tap: [String: () -> Void] = [:]
    var text: [String: (String) -> Void] = [:]
    var toggle: [String: (Bool) -> Void] = [:]
}

private struct GGPEEntry: ItemListNodeEntry {
    let row: GGPERow
    let sectionIndex: Int
    let rowIndex: Int
    let context: AccountContext

    var section: ItemListSectionId {
        return ItemListSectionId(self.sectionIndex)
    }

    var stableId: String {
        return self.row.id
    }

    static func ==(lhs: GGPEEntry, rhs: GGPEEntry) -> Bool {
        return lhs.row == rhs.row && lhs.sectionIndex == rhs.sectionIndex && lhs.rowIndex == rhs.rowIndex
    }

    static func <(lhs: GGPEEntry, rhs: GGPEEntry) -> Bool {
        if lhs.sectionIndex != rhs.sectionIndex {
            return lhs.sectionIndex < rhs.sectionIndex
        }
        return lhs.rowIndex < rhs.rowIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let handlers = arguments as! GGPEHandlers
        let id = self.row.id
        switch self.row.kind {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text.uppercased(), sectionId: self.section)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .info(text):
            return ItemListMultilineTextItem(presentationData: presentationData, text: text, enabledEntityTypes: [], sectionId: self.section, style: .blocks)
        case let .action(title, destructive, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: destructive ? .destructive : (enabled ? .generic : .disabled), alignment: .natural, sectionId: self.section, style: .blocks, action: {
                handlers.tap[id]?()
            })
        case let .disclosure(title, label, icon, enabled):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon?.image, title: title, enabled: enabled, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                handlers.tap[id]?()
            })
        case let .peer(title, label, peer):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: peer == nil ? nil : self.context, iconPeer: peer, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                handlers.tap[id]?()
            })
        case let .toggle(title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                handlers.toggle[id]?(value)
            })
        case let .check(title, subtitle, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: subtitle, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                handlers.tap[id]?()
            })
        case let .input(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: true, autocorrection: true), clearType: .always, sectionId: self.section, textUpdated: { value in
                handlers.text[id]?(value)
            }, action: {
            })
        case let .multilineInput(text, placeholder):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: placeholder, maxLength: nil, sectionId: self.section, style: .blocks, textUpdated: { value in
                handlers.text[id]?(value)
            })
        }
    }
}

/// An ItemListController driven by a model signal. One subscription per screen, owned by it.
func ggPEMakeListController(context: AccountContext, model: Signal<GGPEScreenModel, NoError>) -> ItemListController {
    let handlers = GGPEHandlers()
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, model)
    |> map { presentationData, model -> (ItemListControllerState, (ItemListNodeState, GGPEHandlers)) in
        handlers.tap = model.tap
        handlers.text = model.text
        handlers.toggle = model.toggle
        var entries: [GGPEEntry] = []
        for (sectionIndex, rows) in model.sections.enumerated() {
            for (rowIndex, row) in rows.enumerated() {
                entries.append(GGPEEntry(row: row, sectionIndex: sectionIndex, rowIndex: rowIndex, context: context))
            }
        }
        var rightButton: ItemListNavigationButton?
        if let button = model.rightButton {
            rightButton = ItemListNavigationButton(content: .text(button.title), style: .bold, enabled: button.enabled, action: button.action)
        }
        let itemListPresentationData = ItemListPresentationData(presentationData)
        let controllerState = ItemListControllerState(presentationData: itemListPresentationData, title: .text(model.title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: itemListPresentationData, entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, handlers))
    }
    return ItemListController(context: context, state: signal)
}

/// An action sheet with plain buttons and Cancel.
func ggPEPresentActionSheet(context: AccountContext, from controller: ViewController?, title: String? = nil, buttons: [(title: String, isDestructive: Bool, action: () -> Void)]) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var items: [ActionSheetItem] = []
    if let title = title {
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

/// "Delete …?" with a destructive confirmation.
func ggPEConfirmDestructive(context: AccountContext, from controller: ViewController?, title: String, text: String, confirm: String, action: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller?.present(textAlertController(context: context, title: title, text: text, actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: confirm, action: action)
    ]), in: .window(.root))
}

/// A short toast at the bottom of `controller`.
func ggPEPresentToast(context: AccountContext, from controller: ViewController?, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller?.present(UndoOverlayController(
        presentationData: presentationData,
        content: .info(title: nil, text: text, timeout: nil, customUndoText: actionTitle),
        elevatedLayout: false,
        action: { result in
            if case .undo = result {
                action?()
            }
            return true
        }
    ), in: .current)
}
