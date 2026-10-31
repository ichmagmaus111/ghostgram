import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import CheckNode
import AppBundle

/// An expandable row without a master switch (`GGMenuRowKind.expandableList`, 2026-10-27): the title,
/// a summary on the right («скрыто: 2 из 4», nothing while no child is on) and a chevron; a tap on the
/// header opens the children in place, as checkboxes inside the same block. The block, the children
/// and the expansion are drawn as in the master-switch group (upstream `ItemListExpandableSwitchItem`,
/// `.expandableGroup`); the switch and its «N/M» are replaced by the summary.
final class GGExpandableListItem: ListViewItem, ItemListItem {
    struct SubItem: Equatable {
        let id: String
        let title: String
        let isSelected: Bool
        let isEnabled: Bool
    }

    let presentationData: ItemListPresentationData
    let icon: UIImage?
    let title: String
    let summary: String?
    let isExpanded: Bool
    let subItems: [SubItem]
    let enabled: Bool
    let sectionId: ItemListSectionId
    let tag: ItemListItemTag?
    let toggleExpanded: () -> Void
    let subAction: (SubItem) -> Void

    let selectable: Bool = true

    init(presentationData: ItemListPresentationData, icon: UIImage?, title: String, summary: String?, isExpanded: Bool, subItems: [SubItem], enabled: Bool, sectionId: ItemListSectionId, tag: ItemListItemTag?, toggleExpanded: @escaping () -> Void, subAction: @escaping (SubItem) -> Void) {
        self.presentationData = presentationData
        self.icon = icon
        self.title = title
        self.summary = summary
        self.isExpanded = isExpanded
        self.subItems = subItems
        self.enabled = enabled
        self.sectionId = sectionId
        self.tag = tag
        self.toggleExpanded = toggleExpanded
        self.subAction = subAction
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = GGExpandableListItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(ListViewItemUpdateAnimation.None) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? GGExpandableListItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply(animation)
                    })
                }
            }
        }
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        if self.enabled {
            self.toggleExpanded()
        }
    }
}

/// One child: a checkbox and its title, tappable on its own.
private final class GGExpandableListSubItemNode: HighlightTrackingButtonNode {
    private let textNode: ImmediateTextNode
    private var checkNode: CheckNode?
    private let separatorNode: ASDisplayNode

    private var theme: PresentationTheme?
    private var item: GGExpandableListItem.SubItem?
    private var action: ((GGExpandableListItem.SubItem) -> Void)?

    init() {
        self.textNode = ImmediateTextNode()
        self.textNode.isUserInteractionEnabled = false

        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true

        super.init()

        self.addSubnode(self.separatorNode)
        self.addSubnode(self.textNode)

        self.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
    }

    @objc private func pressed() {
        guard let item = self.item, item.isEnabled, let action = self.action else {
            return
        }
        action(item)
    }

    func update(presentationData: ItemListPresentationData, item: GGExpandableListItem.SubItem, action: @escaping (GGExpandableListItem.SubItem) -> Void, size: CGSize, transition: ContainedViewLayoutTransition) {
        let themeUpdated = self.theme !== presentationData.theme
        self.theme = presentationData.theme

        self.item = item
        self.action = action

        let leftInset: CGFloat = 60.0
        let separatorRightInset: CGFloat = 16.0

        if themeUpdated {
            self.separatorNode.backgroundColor = presentationData.theme.list.itemBlocksSeparatorColor
        }

        let checkNode: CheckNode
        if let current = self.checkNode {
            checkNode = current
            if themeUpdated {
                checkNode.theme = CheckNodeTheme(theme: presentationData.theme, style: .plain)
            }
        } else {
            checkNode = CheckNode(theme: CheckNodeTheme(theme: presentationData.theme, style: .plain))
            checkNode.isUserInteractionEnabled = false
            self.checkNode = checkNode
            self.addSubnode(checkNode)
        }

        let checkSize = CGSize(width: 22.0, height: 22.0)
        checkNode.frame = CGRect(origin: CGPoint(x: floor((leftInset - checkSize.width) / 2.0), y: floor((size.height - checkSize.height) / 2.0)), size: checkSize)
        checkNode.setSelected(item.isSelected, animated: transition.isAnimated)

        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: leftInset, y: size.height - UIScreenPixel), size: CGSize(width: size.width - leftInset - separatorRightInset, height: UIScreenPixel)))

        self.textNode.maximumNumberOfLines = 1
        self.textNode.truncationType = .end
        self.textNode.attributedText = NSAttributedString(string: item.title, font: Font.regular(presentationData.fontSize.itemListBaseFontSize), textColor: presentationData.theme.list.itemPrimaryTextColor)
        let titleSize = self.textNode.updateLayout(CGSize(width: max(1.0, size.width - leftInset - separatorRightInset), height: 100.0))
        self.textNode.frame = CGRect(origin: CGPoint(x: leftInset, y: floor((size.height - titleSize.height) / 2.0)), size: titleSize)

        self.alpha = item.isEnabled ? 1.0 : 0.5
        self.accessibilityLabel = item.title
        self.accessibilityValue = item.isSelected ? presentationData.strings.VoiceOver_Common_On : presentationData.strings.VoiceOver_Common_Off
    }
}

private final class GGExpandableListItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomTopStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let highlightedBackgroundNode: ASDisplayNode
    private let maskNode: ASImageNode

    private let iconNode: ASImageNode
    private let titleNode: TextNode
    private let summaryNode: TextNode
    private let arrowNode: ASImageNode

    private let subItemContainer: ASDisplayNode
    private var subItemNodes: [String: GGExpandableListSubItemNode] = [:]

    private let activateArea: AccessibilityAreaNode

    private var item: GGExpandableListItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true

        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false

        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomTopStripeNode = ASDisplayNode()
        self.bottomTopStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true

        self.iconNode = ASImageNode()
        self.iconNode.isLayerBacked = true
        self.iconNode.displaysAsynchronously = false

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false

        self.summaryNode = TextNode()
        self.summaryNode.isUserInteractionEnabled = false

        self.arrowNode = ASImageNode()
        self.arrowNode.isLayerBacked = true
        self.arrowNode.displaysAsynchronously = false

        self.subItemContainer = ASDisplayNode()
        self.subItemContainer.clipsToBounds = true

        self.activateArea = AccessibilityAreaNode()

        super.init(layerBacked: false)

        self.addSubnode(self.titleNode)
        self.addSubnode(self.summaryNode)
        self.addSubnode(self.arrowNode)
        self.addSubnode(self.activateArea)
        self.addSubnode(self.subItemContainer)

        self.activateArea.activate = { [weak self] in
            guard let self, let item = self.item, item.enabled else {
                return false
            }
            item.toggleExpanded()
            return true
        }
    }

    func asyncLayout() -> (_ item: GGExpandableListItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSummaryLayout = TextNode.asyncLayout(self.summaryNode)

        let currentItem = self.item

        return { [weak self] item, params, neighbors in
            let theme = item.presentationData.theme
            let separatorHeight = UIScreenPixel
            let separatorRightInset: CGFloat = 16.0
            // The glass row metrics of the menu (every row there is `systemStyle: .glass`).
            let rowHeight: CGFloat = 52.0
            let verticalInset: CGFloat = 15.0
            // The chevron sits where the group's switch is; the summary ends before it.
            let arrowAreaWidth: CGFloat = 30.0

            var updatedTheme: PresentationTheme?
            if currentItem?.presentationData.theme !== theme {
                updatedTheme = theme
            }
            var updateIcon = false
            if currentItem?.icon != item.icon {
                updateIcon = true
            }

            let itemBackgroundColor = theme.list.itemBlocksBackgroundColor
            let itemSeparatorColor = theme.list.itemBlocksSeparatorColor
            let insets = itemListNeighborsGroupedInsets(neighbors, params)

            var leftInset = 16.0 + params.leftInset
            if item.icon != nil {
                leftInset += 43.0
            }
            let rightEdge = params.width - params.rightInset - 15.0
            let availableWidth = max(1.0, rightEdge - arrowAreaWidth - leftInset)

            let fontSize = item.presentationData.fontSize.itemListBaseFontSize
            let summaryColor = item.enabled ? theme.list.itemAccentColor : theme.list.itemDisabledTextColor
            let (summaryLayout, summaryApply) = makeSummaryLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.summary ?? "", font: Font.regular(fontSize), textColor: summaryColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: floor(availableWidth * 0.45), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
            let summaryGap: CGFloat = summaryLayout.size.width > 0.0 ? 8.0 : 0.0

            let titleColor = item.enabled ? theme.list.itemPrimaryTextColor : theme.list.itemDisabledTextColor
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: Font.regular(fontSize), textColor: titleColor), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: max(1.0, availableWidth - summaryLayout.size.width - summaryGap), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let mainContentHeight = max(rowHeight, titleLayout.size.height + verticalInset * 2.0)
            var subItemsHeight: CGFloat = 0.0
            if item.isExpanded {
                subItemsHeight = CGFloat(item.subItems.count) * rowHeight
            }
            let contentSize = CGSize(width: params.width, height: mainContentHeight + subItemsHeight)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size

            return (layout, { [weak self] animation in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                let transition: ContainedViewLayoutTransition = animation.transition

                strongSelf.activateArea.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: params.width - params.leftInset - params.rightInset, height: mainContentHeight))
                strongSelf.activateArea.accessibilityLabel = item.title
                strongSelf.activateArea.accessibilityValue = item.summary ?? ""
                var accessibilityTraits: UIAccessibilityTraits = [.button]
                if !item.enabled {
                    accessibilityTraits.insert(.notEnabled)
                }
                strongSelf.activateArea.accessibilityTraits = accessibilityTraits

                if let icon = item.icon {
                    if strongSelf.iconNode.supernode == nil {
                        strongSelf.addSubnode(strongSelf.iconNode)
                    }
                    if updateIcon {
                        strongSelf.iconNode.image = icon
                    }
                    strongSelf.iconNode.frame = CGRect(origin: CGPoint(x: params.leftInset + floor((leftInset - params.leftInset - icon.size.width) / 2.0), y: floor((mainContentHeight - icon.size.height) / 2.0)), size: icon.size)
                } else if strongSelf.iconNode.supernode != nil {
                    strongSelf.iconNode.image = nil
                    strongSelf.iconNode.removeFromSupernode()
                }

                if let updatedTheme {
                    strongSelf.topStripeNode.backgroundColor = itemSeparatorColor
                    strongSelf.bottomTopStripeNode.backgroundColor = itemSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = itemSeparatorColor
                    strongSelf.backgroundNode.backgroundColor = itemBackgroundColor
                    strongSelf.highlightedBackgroundNode.backgroundColor = updatedTheme.list.itemHighlightedBackgroundColor
                    strongSelf.arrowNode.image = generateTintedImage(image: UIImage(bundleImageName: "Item List/DisclosureArrow"), color: updatedTheme.list.disclosureArrowColor)
                }

                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.bottomTopStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomTopStripeNode, at: 3)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.addSubnode(strongSelf.maskNode)
                }

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    strongSelf.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    strongSelf.topStripeNode.isHidden = hasCorners
                }
                let bottomStripeInset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomStripeInset = leftInset
                    strongSelf.bottomStripeNode.isHidden = false
                default:
                    bottomStripeInset = 0.0
                    hasBottomCorners = true
                    strongSelf.bottomStripeNode.isHidden = hasCorners
                }
                // The line between the header and the children, only while they are open.
                strongSelf.bottomTopStripeNode.isHidden = !item.isExpanded || item.subItems.isEmpty

                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: true) : nil

                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                animation.animator.updateFrame(layer: strongSelf.backgroundNode.layer, frame: backgroundFrame, completion: nil)
                animation.animator.updateFrame(layer: strongSelf.maskNode.layer, frame: backgroundFrame.insetBy(dx: params.leftInset, dy: 0.0), completion: nil)
                animation.animator.updateFrame(layer: strongSelf.topStripeNode.layer, frame: CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight)), completion: nil)
                animation.animator.updateFrame(layer: strongSelf.bottomTopStripeNode.layer, frame: CGRect(origin: CGPoint(x: leftInset, y: mainContentHeight - separatorHeight), size: CGSize(width: layoutSize.width - leftInset - params.rightInset - separatorRightInset, height: separatorHeight)), completion: nil)
                animation.animator.updateFrame(layer: strongSelf.bottomStripeNode.layer, frame: CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height - separatorHeight), size: CGSize(width: layoutSize.width - bottomStripeInset - params.rightInset - separatorRightInset, height: separatorHeight)), completion: nil)

                let _ = titleApply()
                strongSelf.titleNode.frame = CGRect(origin: CGPoint(x: leftInset, y: floorToScreenPixels((mainContentHeight - titleLayout.size.height) / 2.0)), size: titleLayout.size)

                // The chevron points down while closed and up while open, as in the group.
                if let image = strongSelf.arrowNode.image {
                    let scaleFactor: CGFloat = 0.8
                    strongSelf.arrowNode.bounds = CGRect(origin: CGPoint(), size: CGSize(width: image.size.width * scaleFactor, height: image.size.height * scaleFactor))
                    strongSelf.arrowNode.position = CGPoint(x: rightEdge - arrowAreaWidth * 0.5, y: floorToScreenPixels(mainContentHeight / 2.0))
                    transition.updateTransformRotation(node: strongSelf.arrowNode, angle: item.isExpanded ? CGFloat.pi * -0.5 : CGFloat.pi * 0.5)
                }

                let _ = summaryApply()
                strongSelf.summaryNode.frame = CGRect(origin: CGPoint(x: rightEdge - arrowAreaWidth - summaryLayout.size.width, y: floorToScreenPixels((mainContentHeight - summaryLayout.size.height) / 2.0)), size: summaryLayout.size)

                strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -UIScreenPixel), size: CGSize(width: params.width, height: mainContentHeight + UIScreenPixel + UIScreenPixel))

                animation.animator.updateFrame(layer: strongSelf.subItemContainer.layer, frame: CGRect(origin: CGPoint(x: 0.0, y: mainContentHeight), size: CGSize(width: params.width, height: subItemsHeight)), completion: nil)

                var validIds = Set<String>()
                let subItemSize = CGSize(width: params.width - params.leftInset - params.rightInset, height: rowHeight)
                var nextSubItemPosition = CGPoint(x: params.leftInset, y: 0.0)
                for subItem in item.subItems {
                    validIds.insert(subItem.id)

                    let subItemNode: GGExpandableListSubItemNode
                    var subItemTransition = transition
                    if let current = strongSelf.subItemNodes[subItem.id] {
                        subItemNode = current
                    } else {
                        subItemTransition = .immediate
                        subItemNode = GGExpandableListSubItemNode()
                        strongSelf.subItemNodes[subItem.id] = subItemNode
                        strongSelf.subItemContainer.addSubnode(subItemNode)
                    }
                    subItemNode.update(presentationData: item.presentationData, item: subItem, action: item.subAction, size: subItemSize, transition: subItemTransition)
                    subItemTransition.updateFrame(node: subItemNode, frame: CGRect(origin: nextSubItemPosition, size: subItemSize))
                    nextSubItemPosition.y += subItemSize.height
                }
                for (id, subItemNode) in strongSelf.subItemNodes where !validIds.contains(id) {
                    subItemNode.removeFromSupernode()
                    strongSelf.subItemNodes.removeValue(forKey: id)
                }
            })
        }
    }

    override func visibleForSelection(at point: CGPoint) -> Bool {
        if !self.canBeSelected {
            return false
        }
        // Only the header expands; the children are buttons of their own.
        if point.y > self.subItemContainer.frame.minY {
            return false
        }
        return true
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        var highlighted = highlighted
        if point.y > self.subItemContainer.frame.minY {
            highlighted = false
        }

        super.setHighlighted(highlighted, at: point, animated: animated)

        if highlighted {
            self.highlightedBackgroundNode.alpha = 1.0
            if self.highlightedBackgroundNode.supernode == nil {
                if self.bottomStripeNode.supernode != nil {
                    self.insertSubnode(self.highlightedBackgroundNode, aboveSubnode: self.bottomStripeNode)
                } else {
                    self.addSubnode(self.highlightedBackgroundNode)
                }
            }
        } else if self.highlightedBackgroundNode.supernode != nil {
            if animated {
                self.highlightedBackgroundNode.layer.animateAlpha(from: self.highlightedBackgroundNode.alpha, to: 0.0, duration: 0.4, completion: { [weak self] completed in
                    if completed {
                        self?.highlightedBackgroundNode.removeFromSupernode()
                    }
                })
                self.highlightedBackgroundNode.alpha = 0.0
            } else {
                self.highlightedBackgroundNode.removeFromSupernode()
            }
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.allowsGroupOpacity = true
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4, completion: { [weak self] _ in
            self?.layer.allowsGroupOpacity = false
        })
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.allowsGroupOpacity = true
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
