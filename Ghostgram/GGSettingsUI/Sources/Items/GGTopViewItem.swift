import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import ItemListUI
import LottieSettings
import AnimatedStickerNode
import TelegramAnimatedStickerNode

/// Header of a sub-screen: a short centered text, under a bundled animated sticker when the tab has
/// one. Emoji are not drawn (owner, 2026-10-27: no emoji at the top of tabs). No block background.
final class GGTopViewItem: ListViewItem, ItemListItem {
    let context: AccountContext
    let theme: PresentationTheme
    let content: GGMenuTopView.Content
    let text: String
    let sectionId: ItemListSectionId
    let isAlwaysPlain: Bool = true

    init(context: AccountContext, theme: PresentationTheme, content: GGMenuTopView.Content, text: String, sectionId: ItemListSectionId) {
        self.context = context
        self.theme = theme
        self.content = content
        self.text = text
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = GGTopViewItemNode(lottieSettings: self.context.lottieRenderingSettings)
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
            guard let nodeValue = node() as? GGTopViewItemNode else {
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

private final class GGTopViewItemNode: ListViewItemNode {
    private let textNode: TextNode
    private let animationNode: DefaultAnimatedStickerNodeImpl

    private var item: GGTopViewItem?
    private var setupAnimationName: String?

    init(lottieSettings: LottieRenderingSettings) {
        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false
        self.textNode.displaysAsynchronously = false

        self.animationNode = DefaultAnimatedStickerNodeImpl(lottieSettings: lottieSettings)

        super.init(layerBacked: false)

        self.addSubnode(self.textNode)
        self.addSubnode(self.animationNode)
    }

    override func didLoad() {
        super.didLoad()

        self.animationNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.animationTapGesture(_:))))
    }

    @objc private func animationTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state, !self.animationNode.isPlaying {
            self.animationNode.play(firstFrame: false, fromIndex: nil)
        }
    }

    func asyncLayout() -> (_ item: GGTopViewItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTextLayout = TextNode.asyncLayout(self.textNode)

        return { [weak self] item, params, neighbors in
            let iconBox: CGFloat
            switch item.content {
            case .emoji:
                iconBox = 0.0
            case .animation:
                iconBox = 90.0
            }

            let textInset: CGFloat = 48.0 + params.leftInset
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.text, font: Font.regular(14.0), textColor: item.theme.list.freeTextColor), backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: max(1.0, params.width - params.rightInset - textInset * 2.0), height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))

            let topInset: CGFloat = 9.0
            let iconSpacing: CGFloat = iconBox > 0.0 ? 10.0 : 0.0
            let height = topInset + iconBox + iconSpacing + textLayout.size.height + 17.0
            var insets = itemListNeighborsGroupedInsets(neighbors, params)
            insets.top = 0.0
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: insets)

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                let _ = textApply()

                let boxFrame = CGRect(origin: CGPoint(x: floor((params.width - iconBox) / 2.0), y: topInset), size: CGSize(width: iconBox, height: iconBox))

                switch item.content {
                case .emoji:
                    strongSelf.animationNode.isHidden = true
                case let .animation(name):
                    strongSelf.animationNode.isHidden = false
                    if strongSelf.setupAnimationName != name {
                        strongSelf.setupAnimationName = name
                        strongSelf.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(name: name), width: 192, height: 192, playbackMode: .once, mode: .direct(cachePathPrefix: nil))
                        strongSelf.animationNode.visibility = true
                    }
                    strongSelf.animationNode.frame = boxFrame
                    strongSelf.animationNode.updateLayout(size: boxFrame.size)
                }

                strongSelf.textNode.frame = CGRect(origin: CGPoint(x: floor((params.width - textLayout.size.width) / 2.0), y: boxFrame.maxY + iconSpacing), size: textLayout.size)
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
