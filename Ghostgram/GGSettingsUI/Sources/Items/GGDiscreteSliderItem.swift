import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import LegacyComponents
import UIKitRuntimeUtils
import ItemListUI

/// Discrete choice with a label above every tick (the shape of upstream `MaximumCacheSizePickerItem`,
/// with labels passed in and any number of positions from 2 to 6).
final class GGDiscreteSliderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let labels: [String]
    let selectedIndex: Int
    let enabled: Bool
    let sectionId: ItemListSectionId
    let tag: ItemListItemTag?
    let selected: (Int) -> Void

    init(theme: PresentationTheme, labels: [String], selectedIndex: Int, enabled: Bool, sectionId: ItemListSectionId, tag: ItemListItemTag?, selected: @escaping (Int) -> Void) {
        self.theme = theme
        self.labels = labels
        self.selectedIndex = selectedIndex
        self.enabled = enabled
        self.sectionId = sectionId
        self.tag = tag
        self.selected = selected
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = GGDiscreteSliderItemNode()
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
            guard let nodeValue = node() as? GGDiscreteSliderItemNode else {
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

private final class GGDiscreteSliderItemNode: ListViewItemNode, ItemListItemNode {
    private let chrome = GGBlockChrome()
    private var textNodes: [TextNode] = []
    private var sliderView: TGPhotoEditorSliderView?

    private var item: GGDiscreteSliderItem?
    private var layoutParams: ListViewItemLayoutParams?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        super.init(layerBacked: false)
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
        sliderView.useLinesForPositions = true
        sliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
        self.view.addSubview(sliderView)
        self.sliderView = sliderView

        if let item = self.item, let params = self.layoutParams {
            self.updateSlider(item: item, params: params, themeUpdated: true)
        }
    }

    private func updateSlider(item: GGDiscreteSliderItem, params: ListViewItemLayoutParams, themeUpdated: Bool) {
        guard let sliderView = self.sliderView else {
            return
        }
        if themeUpdated {
            sliderView.backgroundColor = .clear
            sliderView.backColor = item.theme.list.itemSwitchColors.frameColor
            sliderView.startColor = item.theme.list.itemSwitchColors.frameColor
            sliderView.trackColor = item.theme.list.itemAccentColor
            sliderView.knobImage = PresentationResourcesItemList.knobImage(item.theme)
        }
        let count = max(2, item.labels.count)
        sliderView.maximumValue = CGFloat(count - 1)
        sliderView.positionsCount = count
        sliderView.value = CGFloat(max(0, min(count - 1, item.selectedIndex)))
        sliderView.isUserInteractionEnabled = item.enabled
        sliderView.alpha = item.enabled ? 1.0 : 0.4
        sliderView.frame = CGRect(origin: CGPoint(x: params.leftInset + 15.0, y: 37.0), size: CGSize(width: params.width - params.leftInset - params.rightInset - 15.0 * 2.0, height: 44.0))
        sliderView.hitTestEdgeInsets = UIEdgeInsets(top: -sliderView.frame.minX, left: 0.0, bottom: 0.0, right: -sliderView.frame.minX)
    }

    func asyncLayout() -> (_ item: GGDiscreteSliderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let currentItem = self.item
        var currentTextNodes = self.textNodes
        while currentTextNodes.count < 6 {
            let textNode = TextNode()
            textNode.isUserInteractionEnabled = false
            textNode.displaysAsynchronously = false
            currentTextNodes.append(textNode)
        }
        let makeTextLayouts = currentTextNodes.map { TextNode.asyncLayout($0) }

        return { [weak self] item, params, neighbors in
            let themeUpdated = currentItem?.theme !== item.theme
            let labels = Array(item.labels.prefix(6))

            var textLayouts: [(TextNodeLayout, () -> TextNode)] = []
            for i in 0 ..< labels.count {
                let color = i == item.selectedIndex ? item.theme.list.itemAccentColor : item.theme.list.itemSecondaryTextColor
                textLayouts.append(makeTextLayouts[i](TextNodeLayoutArguments(attributedString: NSAttributedString(string: labels[i], font: Font.regular(13.0), textColor: color), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(1.0, (params.width - params.leftInset - params.rightInset) / CGFloat(max(1, labels.count))), height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets())))
            }

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

                strongSelf.textNodes = currentTextNodes
                let delta = (params.width - params.leftInset - params.rightInset - 18.0 * 2.0) / CGFloat(max(1, labels.count - 1))
                for i in 0 ..< currentTextNodes.count {
                    let textNode = currentTextNodes[i]
                    guard i < textLayouts.count else {
                        textNode.removeFromSupernode()
                        continue
                    }
                    let (textLayout, textApply) = textLayouts[i]
                    let _ = textApply()
                    if textNode.supernode == nil {
                        strongSelf.addSubnode(textNode)
                    }
                    var position = params.leftInset + 18.0 + delta * CGFloat(i)
                    if i == labels.count - 1 {
                        position -= textLayout.size.width
                    } else if i > 0 {
                        position -= textLayout.size.width / 2.0
                    }
                    textNode.frame = CGRect(origin: CGPoint(x: position, y: 15.0), size: textLayout.size)
                }

                strongSelf.updateSlider(item: item, params: params, themeUpdated: themeUpdated)
            })
        }
    }

    @objc private func sliderValueChanged() {
        guard let sliderView = self.sliderView, let item = self.item else {
            return
        }
        let index = Int(sliderView.value.rounded())
        if index != item.selectedIndex {
            item.selected(index)
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
