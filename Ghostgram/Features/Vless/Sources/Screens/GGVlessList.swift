import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils

// A small list toolkit for the screens of this module: a screen is a signal of rows with stable ids;
// what a row does is looked up by id in tables rebuilt with the rows. Rows compare only what they draw.

struct GGVlessRow: Equatable {
    enum Kind: Equatable {
        case header(String)
        case footer(String)
        case info(String)
        case action(title: String, destructive: Bool, enabled: Bool)
        case disclosure(title: String, label: String)
        case check(title: String, label: String, checked: Bool)
        case input(text: String, placeholder: String)
        case multilineInput(text: String, placeholder: String)
        case toggle(title: String, value: Bool, enabled: Bool)
    }

    let id: String
    let kind: Kind
}

struct GGVlessScreenModel {
    var title: String
    var sections: [[GGVlessRow]] = []
    var tap: [String: () -> Void] = [:]
    var text: [String: (String) -> Void] = [:]
    var toggle: [String: (Bool) -> Void] = [:]
    var rightButton: (title: String, action: () -> Void)?

    init(title: String) {
        self.title = title
    }
}

final class GGVlessHandlers {
    var tap: [String: () -> Void] = [:]
    var text: [String: (String) -> Void] = [:]
    var toggle: [String: (Bool) -> Void] = [:]
}

struct GGVlessEntry: ItemListNodeEntry {
    let row: GGVlessRow
    let sectionIndex: Int
    let rowIndex: Int

    var section: ItemListSectionId {
        return ItemListSectionId(self.sectionIndex)
    }

    var stableId: String {
        return self.row.id
    }

    static func ==(lhs: GGVlessEntry, rhs: GGVlessEntry) -> Bool {
        return lhs.row == rhs.row && lhs.sectionIndex == rhs.sectionIndex && lhs.rowIndex == rhs.rowIndex
    }

    static func <(lhs: GGVlessEntry, rhs: GGVlessEntry) -> Bool {
        if lhs.sectionIndex != rhs.sectionIndex {
            return lhs.sectionIndex < rhs.sectionIndex
        }
        return lhs.rowIndex < rhs.rowIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let handlers = arguments as! GGVlessHandlers
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
        case let .disclosure(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                handlers.tap[id]?()
            })
        case let .check(title, label, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: label.isEmpty ? nil : label, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                handlers.tap[id]?()
            })
        case let .input(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                handlers.text[id]?(value)
            }, action: {
            })
        case let .toggle(title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                handlers.toggle[id]?(value)
            })
        case let .multilineInput(text, placeholder):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: placeholder, maxLength: nil, sectionId: self.section, style: .blocks, capitalization: false, autocorrection: false, textUpdated: { value in
                handlers.text[id]?(value)
            })
        }
    }
}

/// An ItemListController driven by a model signal. One subscription per screen, owned by it.
func ggVlessMakeListController(context: AccountContext, model: Signal<GGVlessScreenModel, NoError>) -> ItemListController {
    let handlers = GGVlessHandlers()
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, model)
    |> map { presentationData, model -> (ItemListControllerState, (ItemListNodeState, GGVlessHandlers)) in
        handlers.tap = model.tap
        handlers.text = model.text
        handlers.toggle = model.toggle
        var entries: [GGVlessEntry] = []
        for (sectionIndex, rows) in model.sections.enumerated() {
            for (rowIndex, row) in rows.enumerated() {
                entries.append(GGVlessEntry(row: row, sectionIndex: sectionIndex, rowIndex: rowIndex))
            }
        }
        var rightButton: ItemListNavigationButton?
        if let button = model.rightButton {
            rightButton = ItemListNavigationButton(content: .text(button.title), style: .bold, enabled: true, action: button.action)
        }
        let itemListPresentationData = ItemListPresentationData(presentationData)
        let controllerState = ItemListControllerState(presentationData: itemListPresentationData, title: .text(model.title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: itemListPresentationData, entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, handlers))
    }
    return ItemListController(context: context, state: signal)
}
