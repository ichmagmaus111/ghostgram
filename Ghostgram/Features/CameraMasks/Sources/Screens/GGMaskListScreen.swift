import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import GGCore

/// One row of the zone's own list screens (masks, studio, virtual camera). The content is plain
/// data (compared to decide what to redraw); the actions are closures looked up by row id.
struct GGListRow {
    enum Kind {
        case header(String)
        case footer(String)
        case action(title: String, destructive: Bool, enabled: Bool)
        case disclosure(title: String, label: String, icon: UIImage?, enabled: Bool)
        case checkbox(title: String, subtitle: String?, checked: Bool, enabled: Bool)
        case toggle(title: String, value: Bool, enabled: Bool)
        /// A UIView block of a fixed height (previews, sliders). `key` changes force an update.
        case view(height: CGFloat, key: String, make: () -> UIView, update: (UIView) -> Void)
    }

    let id: String
    let section: Int
    let kind: Kind
    let action: (() -> Void)?
    let toggled: ((Bool) -> Void)?

    init(id: String, section: Int, kind: Kind, action: (() -> Void)? = nil, toggled: ((Bool) -> Void)? = nil) {
        self.id = id
        self.section = section
        self.kind = kind
        self.action = action
        self.toggled = toggled
    }

    fileprivate var equalityKey: String {
        switch self.kind {
        case let .header(text):
            return "h|\(self.id)|\(text)"
        case let .footer(text):
            return "f|\(self.id)|\(text)"
        case let .action(title, destructive, enabled):
            return "a|\(self.id)|\(title)|\(destructive)|\(enabled)"
        case let .disclosure(title, label, icon, enabled):
            return "d|\(self.id)|\(title)|\(label)|\(icon.map { "\(ObjectIdentifier($0).hashValue)" } ?? "")|\(enabled)"
        case let .checkbox(title, subtitle, checked, enabled):
            return "c|\(self.id)|\(title)|\(subtitle ?? "")|\(checked)|\(enabled)"
        case let .toggle(title, value, enabled):
            return "t|\(self.id)|\(title)|\(value)|\(enabled)"
        case let .view(height, key, _, _):
            return "v|\(self.id)|\(height)|\(key)"
        }
    }
}

private struct GGListEntry: ItemListNodeEntry {
    let index: Int
    let row: GGListRow

    var section: ItemListSectionId {
        return ItemListSectionId(self.row.section)
    }

    var stableId: Int {
        return self.index
    }

    static func ==(lhs: GGListEntry, rhs: GGListEntry) -> Bool {
        return lhs.index == rhs.index && lhs.row.equalityKey == rhs.row.equalityKey
    }

    static func <(lhs: GGListEntry, rhs: GGListEntry) -> Bool {
        return lhs.index < rhs.index
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let row = self.row
        let sectionId = self.section
        switch row.kind {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: sectionId)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: sectionId)
        case let .action(title, destructive, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: !enabled ? .disabled : (destructive ? .destructive : .generic), alignment: .natural, sectionId: sectionId, style: .blocks, action: {
                row.action?()
            })
        case let .disclosure(title, label, icon, enabled):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, enabled: enabled, label: label, sectionId: sectionId, style: .blocks, disclosureStyle: .arrow, action: {
                row.action?()
            })
        case let .checkbox(title, subtitle, checked, enabled):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: subtitle, style: .right, checked: checked, enabled: enabled, zeroSeparatorInsets: false, sectionId: sectionId, action: {
                row.action?()
            })
        case let .toggle(title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: sectionId, style: .blocks, updated: { value in
                row.toggled?(value)
            })
        case let .view(height, _, make, update):
            return GGViewHostItem(theme: presentationData.theme, sectionId: sectionId, height: height, make: make, update: update)
        }
    }
}

/// What a list screen shows on one rebuild.
struct GGListScreenContent {
    let title: String
    let rows: [GGListRow]
    let rightButton: (title: String, enabled: Bool, action: () -> Void)?

    init(title: String, rows: [GGListRow], rightButton: (title: String, enabled: Bool, action: () -> Void)? = nil) {
        self.title = title
        self.rows = rows
        self.rightButton = rightButton
    }
}

/// A list screen rebuilt from one signal (presentation data, settings revision, language and the
/// screen's own `extra` signal). Nothing is cached in the screen; the content closure reads models.
func ggMakeListScreen(context: AccountContext, extra: Signal<Void, NoError>, content: @escaping () -> GGListScreenContent) -> ItemListController {
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, GGSettingsStore.shared.revision, GGLocalization.shared.languageCodeSignal, extra)
    |> map { presentationData, _, _, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let value = content()
        var rightButton: ItemListNavigationButton?
        if let button = value.rightButton {
            rightButton = ItemListNavigationButton(content: .text(button.title), style: .bold, enabled: button.enabled, action: button.action)
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(value.title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let entries = value.rows.enumerated().map { GGListEntry(index: $0.offset, row: $0.element) }
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, Void()))
    }
    return ItemListController(context: context, state: signal)
}

/// A UIView in a list block with the list's corners, constant height.
final class GGViewHostItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let sectionId: ItemListSectionId
    let height: CGFloat
    let make: () -> UIView
    let update: (UIView) -> Void

    init(theme: PresentationTheme, sectionId: ItemListSectionId, height: CGFloat, make: @escaping () -> UIView, update: @escaping (UIView) -> Void) {
        self.theme = theme
        self.sectionId = sectionId
        self.height = height
        self.make = make
        self.update = update
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = GGViewHostItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? GGViewHostItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply()
                    })
                }
            }
        }
    }
}

private final class GGViewHostItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private var contentView: UIView?

    init() {
        super.init(layerBacked: false)
        self.backgroundNode.isLayerBacked = true
        self.maskNode.isUserInteractionEnabled = false
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.maskNode)
    }

    func asyncLayout() -> (_ item: GGViewHostItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: item.height)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            return (layout, {
                guard let self else {
                    return
                }
                self.backgroundNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                var hasTop = false
                var hasBottom = false
                switch neighbors.top {
                case .sameSection(false):
                    break
                default:
                    hasTop = true
                }
                switch neighbors.bottom {
                case .sameSection(false):
                    break
                default:
                    hasBottom = true
                }
                self.maskNode.image = itemListHasRoundedBlockLayout(params) ? PresentationResourcesItemList.cornersImage(item.theme, top: hasTop, bottom: hasBottom, glass: true) : nil
                let frame = CGRect(x: params.leftInset, y: 0.0, width: params.width - params.leftInset - params.rightInset, height: item.height)
                self.backgroundNode.frame = frame
                self.maskNode.frame = frame

                let contentView: UIView
                if let current = self.contentView {
                    contentView = current
                } else {
                    contentView = item.make()
                    contentView.clipsToBounds = true
                    self.view.insertSubview(contentView, belowSubview: self.maskNode.view)
                    self.contentView = contentView
                }
                contentView.frame = frame
                item.update(contentView)
            })
        }
    }
}

/// A slider block for the studio: title, value, slider. `changed` on every tick (the preview),
/// `committed` once when the finger lifts (the save).
final class GGSliderBlockView: UIView {
    static let height: CGFloat = 76.0

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    var format: (Double) -> String = { "\($0)" }
    var step: Double = 0.01
    var changed: ((Double) -> Void)?
    var committed: ((Double) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.titleLabel.font = UIFont.systemFont(ofSize: 17.0)
        self.valueLabel.font = UIFont.systemFont(ofSize: 17.0)
        self.valueLabel.textAlignment = .right
        self.addSubview(self.titleLabel)
        self.addSubview(self.valueLabel)
        self.addSubview(self.slider)
        self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.editingEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func configure(title: String, value: Double, range: ClosedRange<Double>, theme: PresentationTheme) {
        self.titleLabel.text = title
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.valueLabel.textColor = theme.list.itemAccentColor
        self.slider.minimumTrackTintColor = theme.list.itemAccentColor
        self.slider.minimumValue = Float(range.lowerBound)
        self.slider.maximumValue = Float(range.upperBound)
        if !self.slider.isTracking {
            self.slider.value = Float(value)
            self.valueLabel.text = self.format(value)
        }
    }

    private var quantized: Double {
        let raw = Double(self.slider.value)
        if self.step <= 0.0 {
            return raw
        }
        return (raw / self.step).rounded() * self.step
    }

    @objc private func valueChanged() {
        let value = self.quantized
        self.valueLabel.text = self.format(value)
        self.changed?(value)
    }

    @objc private func editingEnded() {
        self.committed?(self.quantized)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 16.0
        let width = self.bounds.width - inset * 2.0
        self.titleLabel.frame = CGRect(x: inset, y: 10.0, width: width * 0.65, height: 22.0)
        self.valueLabel.frame = CGRect(x: inset + width * 0.65, y: 10.0, width: width * 0.35, height: 22.0)
        self.slider.frame = CGRect(x: inset, y: 38.0, width: width, height: 30.0)
    }
}

/// UIKit pickers presented from list screens keep their delegate alive here until they finish.
/// Subclassed by each picker's delegate.
class GGPickerDelegateBox: NSObject {
    private static var active: [GGPickerDelegateBox] = []
    var onImage: ((UIImage?) -> Void)?
    var onDocument: ((URL?) -> Void)?

    func retain() {
        GGPickerDelegateBox.active.append(self)
    }

    /// Also drops the handlers, which usually capture the box itself.
    func releaseHandlers() {
        GGPickerDelegateBox.active.removeAll(where: { $0 === self })
        self.onImage = nil
        self.onDocument = nil
    }
}

/// Presents a native controller over the topmost one of a list screen.
func ggPresentNative(_ controller: UIViewController, from viewController: ViewController?) {
    guard let root = viewController?.view.window?.rootViewController else {
        return
    }
    var presenter = root
    while let presented = presenter.presentedViewController {
        presenter = presented
    }
    if let popover = controller.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0.0, height: 0.0)
        popover.permittedArrowDirections = []
    }
    presenter.present(controller, animated: true)
}
