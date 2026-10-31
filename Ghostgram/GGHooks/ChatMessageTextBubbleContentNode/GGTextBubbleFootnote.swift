// Compiled into ChatMessageTextBubbleContentNode (filegroup
// //Ghostgram/GGHooks:ChatMessageTextBubbleContentNodeHookSources): the footnote under a text
// bubble's text (`GGMessageDecoration.footnote`, e.g. previous versions of an edited message).
// It is a separate TextNode: text selection and copying never include it, it has its own opacity.

import Foundation
import UIKit
import ObjectiveC
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import TextFormat
import ChatMessageBubbleContentNode
import GGHooks

private var ggFootnoteNodeKey: UInt8 = 0

/// The footnote of one layout pass.
struct GGTextBubbleFootnote {
    let size: CGSize
    let alpha: CGFloat
    let apply: () -> TextNode

    /// Space between the message text and the footnote.
    static let spacing: CGFloat = 2.0
}

typealias GGTextBubbleFootnoteLayout = (ChatMessageBubbleContentItem, CGSize, PresentationThemePartedColors) -> GGTextBubbleFootnote?

/// GHOST hook target: the start of `asyncLayoutContent`, captured like upstream's own layouts
/// (the current node is read on the main thread). nil when nobody decorates messages.
func ggTextBubbleFootnoteLayout(_ node: ASDisplayNode) -> GGTextBubbleFootnoteLayout? {
    if !GGMessageDecorationHooks.isActive {
        return nil
    }
    let layout = TextNode.asyncLayout(objc_getAssociatedObject(node, &ggFootnoteNodeKey) as? TextNode)
    return { item, constrainedSize, messageTheme in
        guard let footnote = GGMessageDecorationHooks.footnote(for: item.message, context: item.context), !footnote.text.isEmpty else {
            return nil
        }
        let fontSize = max(11.0, item.presentationData.messageFont.pointSize - 2.0)
        let font = Font.regular(fontSize)
        let string = stringWithAppliedEntities(footnote.text, entities: footnote.entities, baseColor: messageTheme.secondaryTextColor, linkColor: messageTheme.linkTextColor, baseFont: font, linkFont: font, boldFont: Font.semibold(fontSize), italicFont: Font.italic(fontSize), boldItalicFont: Font.semiboldItalic(fontSize), fixedFont: Font.monospace(fontSize), blockQuoteFont: font, message: nil)
        let (textLayout, textApply) = layout(TextNodeLayoutArguments(attributedString: string, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: constrainedSize))
        return GGTextBubbleFootnote(size: textLayout.size, alpha: footnote.alpha, apply: textApply)
    }
}

/// GHOST hook target: the apply of the text bubble. `textFrame` is the text column including the
/// footnote (its last `size.height` points are the footnote's).
func ggApplyTextBubbleFootnote(_ node: ASDisplayNode, _ footnote: GGTextBubbleFootnote?, textFrame: CGRect) {
    let current = objc_getAssociatedObject(node, &ggFootnoteNodeKey) as? TextNode
    guard let footnote else {
        if let current {
            current.removeFromSupernode()
            objc_setAssociatedObject(node, &ggFootnoteNodeKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return
    }
    let textNode = footnote.apply()
    if textNode !== current {
        current?.removeFromSupernode()
        textNode.isUserInteractionEnabled = false
        node.addSubnode(textNode)
        objc_setAssociatedObject(node, &ggFootnoteNodeKey, textNode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    textNode.alpha = footnote.alpha
    textNode.frame = CGRect(origin: CGPoint(x: textFrame.minX, y: textFrame.maxY - footnote.size.height), size: footnote.size)
}
