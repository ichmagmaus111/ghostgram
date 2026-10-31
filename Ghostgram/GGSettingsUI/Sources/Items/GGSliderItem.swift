import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import LegacyComponents
import UIKitRuntimeUtils
import ItemListUI

/// Slider row: title, current value in accent, a Telegram-style slider under them.
/// `updated` fires on every tick (previews only), `committed` once on release (the write).
/// While the finger is down, values coming back from the list are ignored (`isInteracting`),
/// so the knob and the preview never jump back.
final class GGSliderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let fontSize: PresentationFontSize
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let enabled: Bool
    let sectionId: ItemListSectionId
    let tag: ItemListItemTag?
    let updated: (Double) -> Void
    let committed: (Double) -> Void

    init(theme: PresentationTheme, fontSize: PresentationFontSize, title: String, value: Double, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String, enabled: Bool, sectionId: ItemListSectionId, tag: ItemListItemTag?, updated: @escaping (Double) -> Void, committed: @escaping (Double) -> Void) {
        self.theme = theme
        self.fontSize = fontSize
        self.title = title
        self.value = value
        self.range = range
        self.step = step
        self.format = format
        self.enabled = enabled
        self.sectionId = sectionId
        self.tag = tag
        self.updated = updated
        self.committed = committed
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = GGSliderItemNode()
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
            guard let nodeValue = node() as? GGSliderItemNode else {
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

/// `TGPhotoEditorSliderView` misplaces the knob when `minimumValue > 0`, so the slider always runs
/// from 0 and the offset is applied here.
private struct GGSliderMapping {
    let lower: Double
    let upper: Double
    let step: Double

    var sliderMaximum: CGFloat {
        return CGFloat(max(0.0, self.upper - self.lower))
    }

    func sliderValue(_ value: Double) -> CGFloat {
        return CGFloat(min(self.upper, max(self.lower, value)) - self.lower)
    }

    func value(_ sliderValue: CGFloat) -> Double {
        var value = Double(sliderValue) + self.lower
        if self.step > 0.0 {
            value = (value / self.step).rounded() * self.step
        }
        return min(self.upper, max(self.lower, value))
    }

    /// Tick marks only for short scales; long scales snap in `value(_:)`.
    var positionsCount: Int {
        guard self.step > 0.0 else {
            return 0
        }
        let count = Int(((self.upper - self.lower) / self.step).rounded()) + 1
        return count <= 11 ? count : 0
    }
}

private final class GGSliderItemNode: ListViewItemNode, ItemListItemNode {
    private let chrome = GGBlockChrome()
    private let titleNode: TextNode
    private let valueNode: ImmediateTextNode
    private var sliderView: TGPhotoEditorSliderView?

    private var item: GGSliderItem?
    private var layoutParams: ListViewItemLayoutParams?
    private var isInteracting = false
    private var currentValue: Double = 0.0

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false

        self.valueNode = ImmediateTextNode()
        self.valueNode.isUserInteractionEnabled = false
        self.valueNode.displaysAsynchronously = false

        super.init(layerBacked: false)

        self.addSubnode(self.titleNode)
        self.addSubnode(self.valueNode)
    }

    override func didLoad() {
        super.didLoad()

        let sliderView = TGPhotoEditorSliderView()
        sliderView.enablePanHandling = true
        sliderView.trackCornerRadius = 2.0
        sliderView.lineSize = 4.0
        sliderView.dotSize = 5.0
        sliderView.minimumValue = 0.0
        sliderView.startValue = 0.0
        sliderView.disablesInteractiveTransitionGestureRecognizer = true
        sliderView.interactionBegan = { [weak self] in
            self?.isInteracting = true
        }
        sliderView.interactionEnded = { [weak self] in
            guard let self else {
                return
            }
            self.isInteracting = false
            self.item?.committed(self.currentValue)
        }
        sliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
        self.view.addSubview(sliderView)
        self.sliderView = sliderView

        if let item = self.item, let params = self.layoutParams {
            self.updateSlider(item: item, params: params, themeUpdated: true)
            self.updateValueText(item: item, params: params)
        }
    }

    private func updateSlider(item: GGSliderItem, params: ListViewItemLayoutParams, themeUpdated: Bool) {
        // The value comes first: the first layout is applied before the slider view exists
        // (`didLoad`), and the value label used to show the 0 it started with until a touch.
        if !self.isInteracting {
            self.currentValue = item.value
        }
        guard let sliderView = self.sliderView else {
            return
        }
        let mapping = GGSliderMapping(lower: item.range.lowerBound, upper: item.range.upperBound, step: item.step)
        if themeUpdated {
            sliderView.backgroundColor = .clear
            sliderView.backColor = item.theme.list.itemSwitchColors.frameColor
            sliderView.startColor = item.theme.list.itemSwitchColors.frameColor
            sliderView.trackColor = item.theme.list.itemAccentColor
            sliderView.knobImage = PresentationResourcesItemList.knobImage(item.theme)
        }
        sliderView.maximumValue = mapping.sliderMaximum
        sliderView.positionsCount = mapping.positionsCount
        sliderView.useLinesForPositions = mapping.positionsCount > 0
        sliderView.isUserInteractionEnabled = item.enabled
        sliderView.alpha = item.enabled ? 1.0 : 0.4
        if !self.isInteracting {
            sliderView.value = mapping.sliderValue(item.value)
        }
        sliderView.frame = CGRect(origin: CGPoint(x: params.leftInset + 15.0, y: 37.0), size: CGSize(width: params.width - params.leftInset - params.rightInset - 15.0 * 2.0, height: 44.0))
        sliderView.hitTestEdgeInsets = UIEdgeInsets(top: -sliderView.frame.minX, left: 0.0, bottom: 0.0, right: -sliderView.frame.minX)
    }

    private func updateValueText(item: GGSliderItem, params: ListViewItemLayoutParams) {
        let font = Font.regular(item.fontSize.itemListBaseFontSize)
        self.valueNode.attributedText = NSAttributedString(string: item.format(self.currentValue), font: font, textColor: item.theme.list.itemAccentColor)
        let size = self.valueNode.updateLayout(CGSize(width: params.width / 2.0, height: 40.0))
        self.valueNode.frame = CGRect(origin: CGPoint(x: params.width - params.rightInset - 16.0 - size.width, y: 13.0), size: size)
    }

    func asyncLayout() -> (_ item: GGSliderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let currentItem = self.item

        return { [weak self] item, params, neighbors in
            let themeUpdated = currentItem?.theme !== item.theme
            let titleFont = Font.regular(item.fontSize.itemListBaseFontSize)
            let titleColor = item.enabled ? item.theme.list.itemPrimaryTextColor : item.theme.list.itemDisabledTextColor
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: titleColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width - params.leftInset - params.rightInset - 120.0, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let contentSize = CGSize(width: params.width, height: 88.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                strongSelf.layoutParams = params
                strongSelf.chrome.apply(to: strongSelf, theme: item.theme, params: params, neighbors: neighbors, contentSize: contentSize, insets: insets, drawsBackground: true)

                let _ = titleApply()
                strongSelf.titleNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 16.0, y: 13.0), size: titleLayout.size)

                strongSelf.updateSlider(item: item, params: params, themeUpdated: themeUpdated)
                strongSelf.updateValueText(item: item, params: params)
            })
        }
    }

    @objc private func sliderValueChanged() {
        guard let sliderView = self.sliderView, let item = self.item, let params = self.layoutParams else {
            return
        }
        let mapping = GGSliderMapping(lower: item.range.lowerBound, upper: item.range.upperBound, step: item.step)
        let value = mapping.value(sliderView.value)
        if value == self.currentValue {
            return
        }
        self.currentValue = value
        self.updateValueText(item: item, params: params)
        item.updated(value)
        if !self.isInteracting {
            // A tap on the track (no drag) ends without interactionEnded.
            item.committed(value)
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
