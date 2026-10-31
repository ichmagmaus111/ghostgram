import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

struct GGChoiceCard {
    let title: String
    let image: UIImage?
}

/// N cards with a picture and a caption; the selected one gets an accent border (0.25 s).
final class GGChoiceCardsItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let cards: [GGChoiceCard]
    let selectedIndex: Int
    let enabled: Bool
    let sectionId: ItemListSectionId
    let tag: ItemListItemTag?
    let selected: (Int) -> Void

    init(theme: PresentationTheme, cards: [GGChoiceCard], selectedIndex: Int, enabled: Bool, sectionId: ItemListSectionId, tag: ItemListItemTag?, selected: @escaping (Int) -> Void) {
        self.theme = theme
        self.cards = cards
        self.selectedIndex = selectedIndex
        self.enabled = enabled
        self.sectionId = sectionId
        self.tag = tag
        self.selected = selected
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = GGChoiceCardsItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            completion(node, {
                return (nil, { _ in apply() })
            })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? GGChoiceCardsItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            completion(layout, { _ in
                apply()
            })
        }
    }
}

private final class GGChoiceCardView: UIView {
    let imageView = UIImageView()
    let titleLabel = UILabel()
    private let borderLayer = CAShapeLayer()
    var tapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 10.0
        self.clipsToBounds = true
        self.imageView.contentMode = .scaleAspectFit
        self.addSubview(self.imageView)
        self.titleLabel.textAlignment = .center
        self.titleLabel.font = Font.regular(13.0)
        self.addSubview(self.titleLabel)
        self.borderLayer.fillColor = nil
        self.layer.addSublayer(self.borderLayer)
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.tapped?()
        }
    }

    func update(theme: PresentationTheme, card: GGChoiceCard, isSelected: Bool, animated: Bool) {
        self.backgroundColor = ggPreviewBackgroundColor(theme: theme)
        self.imageView.image = card.image
        self.titleLabel.text = card.title
        self.titleLabel.textColor = isSelected ? theme.list.itemAccentColor : theme.list.itemPrimaryTextColor
        self.titleLabel.font = isSelected ? Font.semibold(13.0) : Font.regular(13.0)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        self.borderLayer.strokeColor = (isSelected ? theme.list.itemAccentColor : ggPreviewOutlineColor(theme: theme)).cgColor
        self.borderLayer.lineWidth = isSelected ? 2.0 : 0.5
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        self.titleLabel.frame = CGRect(x: 4.0, y: bounds.height - 24.0, width: bounds.width - 8.0, height: 18.0)
        self.imageView.frame = CGRect(x: 8.0, y: 8.0, width: bounds.width - 16.0, height: max(0.0, bounds.height - 40.0))
        self.borderLayer.frame = bounds
        self.borderLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1.0, dy: 1.0), cornerRadius: 9.0).cgPath
    }
}

private final class GGChoiceCardsItemNode: ListViewItemNode, ItemListItemNode {
    private let chrome = GGBlockChrome()
    private var cardViews: [GGChoiceCardView] = []
    private var item: GGChoiceCardsItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        super.init(layerBacked: false)
    }

    func asyncLayout() -> (_ item: GGChoiceCardsItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let currentItem = self.item

        return { [weak self] item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: 130.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                strongSelf.chrome.apply(to: strongSelf, theme: item.theme, params: params, neighbors: neighbors, contentSize: contentSize, insets: insets, drawsBackground: true)

                while strongSelf.cardViews.count < item.cards.count {
                    let cardView = GGChoiceCardView(frame: CGRect())
                    strongSelf.view.insertSubview(cardView, belowSubview: strongSelf.chrome.maskNode.view)
                    strongSelf.cardViews.append(cardView)
                }
                while strongSelf.cardViews.count > item.cards.count {
                    strongSelf.cardViews.removeLast().removeFromSuperview()
                }

                let spacing: CGFloat = 10.0
                let sideInset: CGFloat = params.leftInset + 16.0
                let count = CGFloat(max(1, item.cards.count))
                let cardWidth = floor((params.width - params.rightInset - sideInset - 16.0 - spacing * (count - 1.0)) / count)
                for i in 0 ..< item.cards.count {
                    let cardView = strongSelf.cardViews[i]
                    cardView.frame = CGRect(x: sideInset + (cardWidth + spacing) * CGFloat(i), y: 16.0, width: cardWidth, height: contentSize.height - 32.0)
                    let animated = currentItem != nil && currentItem?.selectedIndex != item.selectedIndex
                    cardView.update(theme: item.theme, card: item.cards[i], isSelected: i == item.selectedIndex, animated: animated)
                    cardView.isUserInteractionEnabled = item.enabled
                    cardView.alpha = item.enabled ? 1.0 : 0.4
                    cardView.tapped = { [weak self] in
                        guard let self, let item = self.item, i != item.selectedIndex else {
                            return
                        }
                        item.selected(i)
                    }
                }
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
