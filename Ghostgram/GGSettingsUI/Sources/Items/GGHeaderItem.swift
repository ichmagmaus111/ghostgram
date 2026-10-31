import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI

/// Root header: the plain ghost, the app name and «Версия 13.0 (build)», no block background.
final class GGHeaderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let fontSize: PresentationFontSize
    let title: String
    let version: String
    let sectionId: ItemListSectionId
    let isAlwaysPlain: Bool = true

    init(theme: PresentationTheme, fontSize: PresentationFontSize, title: String, version: String, sectionId: ItemListSectionId) {
        self.theme = theme
        self.fontSize = fontSize
        self.title = title
        self.version = version
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = GGHeaderItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)

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
            guard let nodeValue = node() as? GGHeaderItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params)
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply()
                    })
                }
            }
        }
    }
}

private final class GGHeaderItemNode: ListViewItemNode {
    private let markNode: ASImageNode
    private let titleNode: TextNode
    private let versionNode: TextNode

    private var item: GGHeaderItem?

    init() {
        self.markNode = ASImageNode()
        self.markNode.isLayerBacked = true
        self.markNode.displaysAsynchronously = false
        self.markNode.displayWithoutProcessing = true

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false

        self.versionNode = TextNode()
        self.versionNode.isUserInteractionEnabled = false
        self.versionNode.displaysAsynchronously = false

        super.init(layerBacked: false)

        self.addSubnode(self.markNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.versionNode)
    }

    func asyncLayout() -> (_ item: GGHeaderItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeVersionLayout = TextNode.asyncLayout(self.versionNode)

        return { [weak self] item, params in
            let baseFontSize = item.fontSize.itemListBaseFontSize
            let titleFont = Font.semibold(floor(baseFontSize * 20.0 / 17.0))
            let versionFont = Font.regular(floor(baseFontSize * 14.0 / 17.0))
            let constrainedWidth = params.width - params.leftInset - params.rightInset - 32.0

            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: item.theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
            let (versionLayout, versionApply) = makeVersionLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.version, font: versionFont, textColor: item.theme.list.itemSecondaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))

            let markSize = CGSize(width: ggSettingsHeaderMarkSide, height: ggSettingsHeaderMarkSide)
            let topInset: CGFloat = 20.0
            let height = topInset + markSize.height + 14.0 + titleLayout.size.height + 3.0 + versionLayout.size.height + 22.0
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                let previousItem = strongSelf.item
                strongSelf.item = item

                if previousItem?.theme !== item.theme {
                    strongSelf.markNode.image = ggSettingsHeaderMark(theme: item.theme)
                }
                let _ = titleApply()
                let _ = versionApply()

                strongSelf.markNode.frame = CGRect(origin: CGPoint(x: floor((params.width - markSize.width) / 2.0), y: topInset), size: markSize)
                strongSelf.titleNode.frame = CGRect(origin: CGPoint(x: floor((params.width - titleLayout.size.width) / 2.0), y: topInset + markSize.height + 14.0), size: titleLayout.size)
                strongSelf.versionNode.frame = CGRect(origin: CGPoint(x: floor((params.width - versionLayout.size.width) / 2.0), y: strongSelf.titleNode.frame.maxY + 3.0), size: versionLayout.size)
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
