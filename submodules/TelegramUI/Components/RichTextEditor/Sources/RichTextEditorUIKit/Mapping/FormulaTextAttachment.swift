#if canImport(UIKit)
import UIKit

@available(iOS 13.0, *)
public struct RichTextFormulaRenderContext {
    public let latex: String
    public let fontSize: CGFloat
    public let textColor: UIColor

    public init(latex: String, fontSize: CGFloat, textColor: UIColor) {
        self.latex = latex
        self.fontSize = fontSize
        self.textColor = textColor
    }
}

@available(iOS 13.0, *)
public struct RichTextFormulaRenderResult {
    public let image: UIImage
    public let size: CGSize
    public let ascent: CGFloat
    public let descent: CGFloat

    public init(image: UIImage, size: CGSize, ascent: CGFloat, descent: CGFloat) {
        self.image = image
        self.size = size
        self.ascent = ascent
        self.descent = descent
    }
}

/// A rendered formula atom. The editor owns only the neutral image + baseline metrics; math rendering is
/// injected by the host so this package stays free of formula-rendering dependencies.
@available(iOS 13.0, *)
final class FormulaTextAttachment: NSTextAttachment {
    let latex: String
    let renderResult: RichTextFormulaRenderResult

    init(latex: String, renderResult: RichTextFormulaRenderResult) {
        self.latex = latex
        self.renderResult = renderResult
        super.init(data: nil, ofType: nil)
        self.image = renderResult.image
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    private func box() -> CGRect {
        let width = max(1.0, renderResult.size.width)
        let height = max(1.0, renderResult.size.height)
        return CGRect(x: 0.0, y: -renderResult.descent, width: width, height: height)
    }

    @available(iOS 15.0, *)
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        return box()
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        return box()
    }
}
#endif
