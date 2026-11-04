import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import TextFormat
import LocalizedPeerData
import ChatControllerInteraction
import ChatPresentationInterfaceState
import GGVoiceTranscription

// Compiled into ChatMessageInteractiveFileNode (filegroup
// //Ghostgram/Features/Voice:ChatMessageInteractiveFileNodeSources), owner W3-1.

/// Word bubbles over an expanded transcription («Слова-пузыри»). All words are drawn into ONE shape
/// layer under the text (not a layer per word), and the path is rebuilt whenever the words, the text
/// layout or the size change — rotation, iPad split, text size and the expand animation included.
/// Taps are resolved by the file node (`wordAt`), the node itself takes no touches.
final class GGVoiceWordBubblesNode: ASDisplayNode {
    private struct Key: Equatable {
        var words: [GGTranscriptionWord]
        var size: CGSize
        var textLength: Int
        var color: UIColor
    }

    private let shapeLayer = CAShapeLayer()
    private var key: Key?
    private var wordRects: [(GGTranscriptionWord, [CGRect])] = []
    /// The decoded words of the last stored entry: a layout pass that changed nothing decodes nothing.
    private(set) var cachedEntry: (entry: Data, text: String, words: [GGTranscriptionWord]?)?

    func words(entry: Data, text: String) -> [GGTranscriptionWord]? {
        if let cachedEntry = self.cachedEntry, cachedEntry.entry == entry, cachedEntry.text == text {
            return cachedEntry.words
        }
        let words = GGTranscriptionWords.decode(entry, text: text)
        self.cachedEntry = (entry, text, words)
        return words
    }

    override init() {
        super.init()
        self.isUserInteractionEnabled = false
        self.layer.addSublayer(self.shapeLayer)
    }

    func update(words: [GGTranscriptionWord], textNode: TextNode, color: UIColor, size: CGSize) {
        let textLength = textNode.currentText?.length ?? 0
        let key = Key(words: words, size: size, textLength: textLength, color: color)
        if self.key == key {
            return
        }
        self.key = key
        self.shapeLayer.frame = CGRect(origin: CGPoint(), size: size)

        var wordRects: [(GGTranscriptionWord, [CGRect])] = []
        let path = UIBezierPath()
        for word in words {
            guard word.location >= 0, word.length > 0, word.location + word.length <= textLength else {
                continue
            }
            guard let rects = textNode.textRangeRects(in: word.range)?.rects, !rects.isEmpty else {
                continue
            }
            let bubbleRects = rects.map { $0.insetBy(dx: -2.0, dy: -0.5) }
            for rect in bubbleRects {
                path.append(UIBezierPath(roundedRect: rect, cornerRadius: min(6.0, rect.height * 0.35)))
            }
            wordRects.append((word, bubbleRects))
        }
        self.wordRects = wordRects
        self.shapeLayer.path = path.cgPath
        self.shapeLayer.fillColor = color.withAlphaComponent(0.13).cgColor
    }

    /// The word under a point in this node's coordinates.
    func word(at point: CGPoint) -> GGTranscriptionWord? {
        for (word, rects) in self.wordRects {
            for rect in rects where rect.insetBy(dx: -2.0, dy: -2.0).contains(point) {
                return word
            }
        }
        return nil
    }
}

/// Inserts the selected words of a transcription into the chat's input field as a block quote with the
/// author's name. The source is explicit (the transcription's own selection), so a caption on the voice
/// message can never turn this into a reply quote of the caption. A reply quote is not used at all: the
/// server only accepts quotes of the message text, and a transcription is not the message text.
func ggInsertTranscriptionQuote(controllerInteraction: ChatControllerInteraction, message: EngineRawMessage, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return
    }
    var quoted = trimmed
    if let author = message.author {
        quoted = EnginePeer(author).compactDisplayTitle + ":\n" + trimmed
    }
    let quote = NSMutableAttributedString(string: quoted, attributes: [ChatTextInputAttributes.block: ChatTextInputTextQuoteAttribute(kind: .quote, isCollapsed: false)])
    if let author = message.author {
        let nameLength = (EnginePeer(author).compactDisplayTitle as NSString).length
        quote.addAttribute(ChatTextInputAttributes.bold, value: true as NSNumber, range: NSRange(location: 0, length: nameLength))
    }
    let insertion = NSMutableAttributedString(attributedString: quote)
    insertion.append(NSAttributedString(string: "\n"))
    controllerInteraction.updateInputState { state in
        let selection = state.selectionRange
        return state.replacingFlatRange(NSRange(location: selection.lowerBound, length: selection.count), with: insertion)
    }
    controllerInteraction.updateInputMode { _ in
        return .text
    }
}

extension ChatMessageInteractiveFileNode {
    /// Shows word bubbles when the expanded text is exactly the stored transcription (not a translation)
    /// and words with timings exist for it; removes them otherwise. Main thread, from the layout apply.
    func ggUpdateWordBubbles(message: EngineRawMessage, shownText: String?, color: UIColor) {
        var entry: Data?
        if let shownText, GGVoiceTranscription.wordBubblesEnabled, self.textNode.supernode === self.textClippingNode, ggTranscriptionText(of: message) == shownText {
            entry = GGTranscriptionWords.storedEntry(in: message)
        }
        guard let shownText, let entry else {
            if let bubbles = self.ggWordBubblesNode {
                self.ggWordBubblesNode = nil
                bubbles.removeFromSupernode()
            }
            return
        }
        let bubbles: GGVoiceWordBubblesNode
        if let current = self.ggWordBubblesNode {
            bubbles = current
        } else {
            bubbles = GGVoiceWordBubblesNode()
            self.ggWordBubblesNode = bubbles
            self.textClippingNode.insertSubnode(bubbles, belowSubnode: self.textNode)
        }
        // Words that do not belong to this text draw nothing; the node keeps its decoded cache.
        let words = bubbles.words(entry: entry, text: shownText) ?? []
        bubbles.frame = self.textNode.frame
        bubbles.update(words: words, textNode: self.textNode, color: color, size: self.textNode.frame.size)
    }

    /// The word under a point of this node's view, if bubbles are shown there.
    func ggWord(at point: CGPoint) -> GGTranscriptionWord? {
        guard let bubbles = self.ggWordBubblesNode, bubbles.supernode != nil, self.textClippingNode.supernode != nil else {
            return nil
        }
        return bubbles.word(at: self.view.convert(point, to: bubbles.view))
    }
}

/// The text stored by the last transcription (either engine).
private func ggTranscriptionText(of message: EngineRawMessage) -> String? {
    for attribute in message.attributes {
        if let attribute = attribute as? AudioTranscriptionMessageAttribute, !attribute.text.isEmpty {
            return attribute.text
        }
    }
    return nil
}
