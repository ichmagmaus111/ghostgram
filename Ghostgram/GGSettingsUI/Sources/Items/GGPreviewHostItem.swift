import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

/// Preview surface colors (shared by every custom preview so they read as one family).
public func ggPreviewBackgroundColor(theme: PresentationTheme) -> UIColor {
    return theme.list.itemPrimaryTextColor.withAlphaComponent(theme.overallDarkAppearance ? 0.05 : 0.035)
}

public func ggPreviewOutlineColor(theme: PresentationTheme) -> UIColor {
    return theme.list.itemPrimaryTextColor.withAlphaComponent((theme.overallDarkAppearance ? 0.05 : 0.035) + 0.085)
}

/// The one preview host: a plain UIView inside a block with glass corners, constant height.
/// The view is created once per node (`make`) and refreshed on every apply (`update`).
final class GGPreviewHostItem: ListViewItem, ItemListItem {
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
            let node = GGPreviewHostItemNode()
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
            guard let nodeValue = node() as? GGPreviewHostItemNode else {
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

/// Block chrome shared by every GG list item that draws its own content: background, separators
/// and the glass corner mask, computed exactly like the upstream ItemList items.
final class GGBlockChrome {
    let backgroundNode: ASDisplayNode
    let topStripeNode: ASDisplayNode
    let bottomStripeNode: ASDisplayNode
    let maskNode: ASImageNode

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true
        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false
    }

    /// `drawsBackground == false` keeps the background node out (the mini chat draws the wallpaper itself).
    func apply(to node: ASDisplayNode, theme: PresentationTheme, params: ListViewItemLayoutParams, neighbors: ItemListNeighbors, contentSize: CGSize, insets: UIEdgeInsets, drawsBackground: Bool) {
        let separatorHeight = UIScreenPixel
        let separatorRightInset: CGFloat = 16.0

        self.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.topStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
        self.bottomStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor

        if drawsBackground {
            if self.backgroundNode.supernode == nil {
                node.insertSubnode(self.backgroundNode, at: 0)
            }
        } else if self.backgroundNode.supernode != nil {
            self.backgroundNode.removeFromSupernode()
        }
        if self.topStripeNode.supernode == nil {
            node.addSubnode(self.topStripeNode)
        }
        if self.bottomStripeNode.supernode == nil {
            node.addSubnode(self.bottomStripeNode)
        }
        if self.maskNode.supernode == nil {
            node.addSubnode(self.maskNode)
        }

        let hasCorners = itemListHasRoundedBlockLayout(params)
        var hasTopCorners = false
        var hasBottomCorners = false
        switch neighbors.top {
        case .sameSection(false):
            self.topStripeNode.isHidden = true
        default:
            hasTopCorners = true
            self.topStripeNode.isHidden = hasCorners
        }
        let bottomStripeOffset: CGFloat
        switch neighbors.bottom {
        case .sameSection(false):
            bottomStripeOffset = -separatorHeight
            self.bottomStripeNode.isHidden = false
        default:
            bottomStripeOffset = 0.0
            hasBottomCorners = true
            self.bottomStripeNode.isHidden = hasCorners
        }

        self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: true) : nil

        let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
        self.backgroundNode.frame = backgroundFrame
        self.maskNode.frame = backgroundFrame.insetBy(dx: params.leftInset, dy: 0.0)
        self.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: separatorHeight))
        self.bottomStripeNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 16.0, y: contentSize.height + bottomStripeOffset), size: CGSize(width: params.width - params.leftInset - params.rightInset - 16.0 - separatorRightInset, height: separatorHeight))
    }

    var backgroundFrame: CGRect {
        return self.backgroundNode.frame
    }
}

private final class GGPreviewHostItemNode: ListViewItemNode {
    private let chrome = GGBlockChrome()
    private var contentView: UIView?
    private var item: GGPreviewHostItem?

    init() {
        super.init(layerBacked: false)
        self.clipsToBounds = false
    }

    func asyncLayout() -> (_ item: GGPreviewHostItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: item.height)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                strongSelf.chrome.apply(to: strongSelf, theme: item.theme, params: params, neighbors: neighbors, contentSize: contentSize, insets: insets, drawsBackground: true)

                let contentView: UIView
                if let current = strongSelf.contentView {
                    contentView = current
                } else {
                    contentView = item.make()
                    contentView.clipsToBounds = true
                    strongSelf.view.insertSubview(contentView, belowSubview: strongSelf.chrome.maskNode.view)
                    strongSelf.contentView = contentView
                }
                contentView.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: params.width - params.leftInset - params.rightInset, height: item.height))
                item.update(contentView)
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
