import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ItemListPeerItem
import PresentationDataUtils
import AppBundle

// One small list framework for the screens of this feature (histories, exclusions, bookmarks,
// versions): a screen describes rows with stable ids; taps and switches are looked up by id in an
// action table rebuilt together with the rows. Rows compare only what they draw.

struct GGADRow: Equatable {
    enum Kind: Equatable {
        case header(String)
        case footer(String)
        case peer(peer: EnginePeer, text: String, label: String, removeTitle: String?)
        case disclosure(title: String, label: String, icon: String?)
        case action(title: String, destructive: Bool)
        case toggle(title: String, value: Bool)
        case text(String)
    }

    let id: String
    let kind: Kind

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

struct GGADSection: Equatable {
    let id: String
    var rows: [GGADRow]

    init(id: String, rows: [GGADRow]) {
        self.id = id
        self.rows = rows
    }
}

/// What a screen shows at one moment, with what its rows do.
struct GGADScreenModel {
    var title: ItemListControllerTitle
    var sections: [GGADSection]
    var tap: [String: () -> Void] = [:]
    var toggle: [String: (Bool) -> Void] = [:]
    var remove: [String: () -> Void] = [:]
    var rightButton: (title: String, action: () -> Void)?

    init(title: ItemListControllerTitle, sections: [GGADSection]) {
        self.title = title
        self.sections = sections
    }
}

final class GGADListArguments {
    let context: AccountContext
    let handlers: GGADHandlers
    let setRevealed: (String?) -> Void

    init(context: AccountContext, handlers: GGADHandlers, setRevealed: @escaping (String?) -> Void) {
        self.context = context
        self.handlers = handlers
        self.setRevealed = setRevealed
    }
}

/// The current action tables (main queue).
final class GGADHandlers {
    var tap: [String: () -> Void] = [:]
    var toggle: [String: (Bool) -> Void] = [:]
    var remove: [String: () -> Void] = [:]
}

struct GGADEntry: ItemListNodeEntry {
    let row: GGADRow
    let sectionIndex: Int
    let rowIndex: Int
    let revealed: Bool

    var section: ItemListSectionId {
        return ItemListSectionId(self.sectionIndex)
    }

    var stableId: String {
        return self.row.id
    }

    static func ==(lhs: GGADEntry, rhs: GGADEntry) -> Bool {
        return lhs.row == rhs.row && lhs.sectionIndex == rhs.sectionIndex && lhs.rowIndex == rhs.rowIndex && lhs.revealed == rhs.revealed
    }

    static func <(lhs: GGADEntry, rhs: GGADEntry) -> Bool {
        if lhs.sectionIndex != rhs.sectionIndex {
            return lhs.sectionIndex < rhs.sectionIndex
        }
        return lhs.rowIndex < rhs.rowIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! GGADListArguments
        let id = self.row.id
        let handlers = arguments.handlers
        switch self.row.kind {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text.uppercased(), sectionId: self.section)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .text(text):
            return ItemListMultilineTextItem(presentationData: presentationData, text: text, enabledEntityTypes: [], sectionId: self.section, style: .blocks, longTapAction: {
                handlers.tap[id]?()
            })
        case let .peer(peer, text, label, removeTitle):
            var revealOptions: ItemListPeerItemRevealOptions?
            if let removeTitle {
                revealOptions = ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .destructive, title: removeTitle, action: {
                    handlers.remove[id]?()
                })])
            }
            let currentPresentationData = arguments.context.sharedContext.currentPresentationData.with { $0 }
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: currentPresentationData.dateTimeFormat, nameDisplayOrder: currentPresentationData.nameDisplayOrder, context: arguments.context, peer: peer, presence: nil, text: text.isEmpty ? .none : .text(text, .secondary), label: label.isEmpty ? .none : .text(label, .standard, nil, false), editing: ItemListPeerItemEditing(editable: removeTitle != nil, editing: false, revealed: self.revealed), revealOptions: revealOptions, switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                handlers.tap[id]?()
            }, setPeerIdWithRevealedOptions: { peerId, _ in
                arguments.setRevealed(peerId == nil ? nil : id)
            }, removePeer: { _ in
                handlers.remove[id]?()
            })
        case let .disclosure(title, label, icon):
            let image = icon.flatMap { name in
                return generateTintedImage(image: UIImage(bundleImageName: name), color: presentationData.theme.list.itemPrimaryTextColor)
            }
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: image, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                handlers.tap[id]?()
            })
        case let .action(title, destructive):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: destructive ? .destructive : .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                handlers.tap[id]?()
            })
        case let .toggle(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                handlers.toggle[id]?(value)
            })
        }
    }
}

/// An ItemListController driven by a model signal. One subscription per screen, owned by it.
func ggMakeADListController(context: AccountContext, model: Signal<GGADScreenModel, NoError>, onSegment: ((Int) -> Void)? = nil) -> ItemListController {
    let handlers = GGADHandlers()
    let revealed = ValuePromise<String?>(nil, ignoreRepeated: true)
    let arguments = GGADListArguments(context: context, handlers: handlers, setRevealed: { id in
        revealed.set(id)
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, model, revealed.get())
    |> map { presentationData, model, revealedId -> (ItemListControllerState, (ItemListNodeState, GGADListArguments)) in
        handlers.tap = model.tap
        handlers.toggle = model.toggle
        handlers.remove = model.remove
        var entries: [GGADEntry] = []
        for (sectionIndex, section) in model.sections.enumerated() {
            for (rowIndex, row) in section.rows.enumerated() {
                entries.append(GGADEntry(row: row, sectionIndex: sectionIndex, rowIndex: rowIndex, revealed: revealedId == row.id))
            }
        }
        var rightButton: ItemListNavigationButton?
        if let button = model.rightButton {
            rightButton = ItemListNavigationButton(content: .text(button.title), style: .regular, enabled: true, action: button.action)
        }
        let itemListPresentationData = ItemListPresentationData(presentationData)
        let controllerState = ItemListControllerState(presentationData: itemListPresentationData, title: model.title, leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: itemListPresentationData, entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    if let onSegment {
        controller.titleControlValueChanged = { index in
            onSegment(index)
        }
    }
    return controller
}
