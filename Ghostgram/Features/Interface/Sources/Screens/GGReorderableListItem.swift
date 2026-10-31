import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

/// A row that is moved by dragging its grip (≡) on the right, like iOS's own reorderable lists
/// and Telegram's folder list. A tap anywhere else selects the row. Drawn like
/// `ItemListDisclosureItem` (same insets, corners and separators), the label sits left of the grip.
final class GGReorderableListItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let systemStyle: ItemListSystemStyle
    let title: String
    let label: String
    let sectionId: ItemListSectionId
    let action: () -> Void

    init(presentationData: ItemListPresentationData, systemStyle: ItemListSystemStyle, title: String, label: String, sectionId: ItemListSectionId, action: @escaping () -> Void) {
        self.presentationData = presentationData
        self.systemStyle = systemStyle
        self.title = title
        self.label = label
        self.sectionId = sectionId
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = GGReorderableListItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(false) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? GGReorderableListItemNode {
                let makeLayout = nodeValue.asyncLayout()

                var animated = true
                if case .None = animation {
                    animated = false
                }

                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animated)
                        })
                    }
                }
            }
        }
    }

    var selectable: Bool {
        return true
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action()
    }
}

private let titleFont = Font.regular(17.0)

final class GGReorderableListItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let highlightedBackgroundNode: ASDisplayNode
    private let maskNode: ASImageNode

    private let titleNode: TextNode
    private let labelNode: TextNode
    private var reorderControlNode: ItemListEditableReorderControlNode?

    private let activateArea: AccessibilityAreaNode

    private var item: GGReorderableListItem?

    var tag: ItemListItemTag? {
        return nil
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true

        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.contentMode = .left
        self.titleNode.contentsScale = UIScreen.main.scale

        self.labelNode = TextNode()
        self.labelNode.isUserInteractionEnabled = false

        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true

        self.activateArea = AccessibilityAreaNode()

        super.init(layerBacked: false, rotated: false, seeThrough: false)

        self.addSubnode(self.titleNode)
        self.addSubnode(self.labelNode)
        self.addSubnode(self.activateArea)

        self.activateArea.activate = { [weak self] in
            self?.item?.action()
            return true
        }
    }

    func asyncLayout() -> (_ item: GGReorderableListItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, (Bool) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeLabelLayout = TextNode.asyncLayout(self.labelNode)
        let reorderControlLayout = ItemListEditableReorderControlNode.asyncLayout(self.reorderControlNode)

        let currentItem = self.item

        return { [weak self] item, params, neighbors in
            let themeUpdated = currentItem?.presentationData.theme !== item.presentationData.theme
            let theme = item.presentationData.theme

            let reorderSizeAndApply = reorderControlLayout(theme)
            let reorderWidth = reorderSizeAndApply.0

            let leftInset: CGFloat = 16.0 + params.leftInset
            let rightEdge: CGFloat = params.width - params.rightInset - reorderWidth

            let (labelLayout, labelApply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.label, font: titleFont, textColor: theme.list.itemSecondaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(0.0, (rightEdge - leftInset) * 0.5), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
            let labelSpacing: CGFloat = labelLayout.size.width > 0.0 ? 10.0 : 0.0
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(0.0, rightEdge - leftInset - labelLayout.size.width - labelSpacing - 4.0), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let verticalInset: CGFloat
            switch item.systemStyle {
            case .glass:
                verticalInset = 15.0
            case .legacy:
                verticalInset = 11.0
            }

            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let contentSize = CGSize(width: params.width, height: titleLayout.size.height + verticalInset * 2.0)
            let separatorHeight = UIScreenPixel
            let separatorRightInset: CGFloat = item.systemStyle == .glass ? 16.0 : 0.0

            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, { animated in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item

                let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.4, curve: .spring) : .immediate

                if themeUpdated {
                    strongSelf.topStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                    strongSelf.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
                    strongSelf.highlightedBackgroundNode.backgroundColor = theme.list.itemHighlightedBackgroundColor
                }

                strongSelf.activateArea.accessibilityLabel = item.title
                strongSelf.activateArea.accessibilityValue = item.label
                strongSelf.activateArea.accessibilityTraits = .button

                let _ = titleApply()
                let _ = labelApply()

                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
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

                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: item.systemStyle == .glass) : nil

                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                strongSelf.backgroundNode.frame = backgroundFrame
                strongSelf.maskNode.frame = backgroundFrame.insetBy(dx: params.leftInset, dy: 0.0)
                strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: separatorHeight))
                strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height - separatorHeight), size: CGSize(width: params.width - params.rightInset - bottomStripeInset - separatorRightInset, height: separatorHeight))

                transition.updateFrame(node: strongSelf.titleNode, frame: CGRect(origin: CGPoint(x: leftInset, y: verticalInset + 1.0), size: titleLayout.size))
                transition.updateFrame(node: strongSelf.labelNode, frame: CGRect(origin: CGPoint(x: rightEdge - 4.0 - labelLayout.size.width, y: verticalInset + 1.0), size: labelLayout.size))

                let reorderControlNode = reorderSizeAndApply.1(contentSize.height, false, transition)
                if strongSelf.reorderControlNode == nil {
                    strongSelf.reorderControlNode = reorderControlNode
                    strongSelf.addSubnode(reorderControlNode)
                }
                reorderControlNode.frame = CGRect(origin: CGPoint(x: rightEdge, y: 0.0), size: CGSize(width: reorderWidth, height: contentSize.height))

                strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -UIScreenPixel), size: CGSize(width: params.width, height: contentSize.height + UIScreenPixel))
                strongSelf.activateArea.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: rightEdge - params.leftInset, height: contentSize.height))
            })
        }
    }

    override func isReorderable(at point: CGPoint) -> Bool {
        if let reorderControlNode = self.reorderControlNode, reorderControlNode.frame.contains(point) {
            return true
        }
        return false
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)

        if highlighted {
            self.highlightedBackgroundNode.alpha = 1.0
            if self.highlightedBackgroundNode.supernode == nil {
                if self.bottomStripeNode.supernode != nil {
                    self.insertSubnode(self.highlightedBackgroundNode, aboveSubnode: self.bottomStripeNode)
                } else {
                    self.insertSubnode(self.highlightedBackgroundNode, at: 0)
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
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
