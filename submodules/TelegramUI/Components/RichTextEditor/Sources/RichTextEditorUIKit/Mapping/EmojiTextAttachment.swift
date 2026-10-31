#if canImport(UIKit)
import UIKit
import RichTextEditorCore

/// An INVISIBLE `NSTextAttachment` that only reserves a square box scaled to the run's font, and
/// carries the `EmojiRef` so the renderer can pool/position the host-provided view (the only visual)
/// and `characterAttributes(from:)` can round-trip the emoji. Draws nothing of its own.
///
/// Sizing: `S = (font.ascender + |font.descender|) * scale`, with the box's baseline offset
/// `y = font.descender`, so the square spans descender→ascender and sits on the baseline like a glyph.
///
/// `renderBoost` enlarges only the VISIBLE host view (see `BlockLayout.attachmentBox`) by that many points,
/// centered on the glyph box — it does NOT touch `attachmentBounds`, so the line height stays put and the
/// extra size bleeds into the line's leading. Used to render body emoji a touch larger than their glyph box.
/// Ungated (iOS 7+): a plain `NSTextAttachment` subclass that works under BOTH layout engines. TextKit 2
/// calls the `location:`-bearing `attachmentBounds` variant (iOS 16+, takes an `NSTextLocation`); TextKit 1
/// calls the classic `characterIndex:` variant. Both reserve the same square box, so the line height matches
/// regardless of engine.
final class EmojiTextAttachment: NSTextAttachment {
    let ref: EmojiRef
    let scale: CGFloat
    let renderBoost: CGFloat

    /// A 1×1 clear image ensures TextKit calls `attachmentBounds(...)` and reserves layout space (an
    /// image-less attachment can be laid out as zero-width). It's identical for every emoji and renders
    /// nothing visible, so it's shared (a fresh render per attachment would cost on every reload).
    private static let spacerImage: UIImage =
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    init(ref: EmojiRef, scale: CGFloat, renderBoost: CGFloat = 0) {
        self.ref = ref
        self.scale = scale
        self.renderBoost = renderBoost
        super.init(data: nil, ofType: nil)
        self.image = Self.spacerImage
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// The square box for a given run font: `S = (ascender + |descender|) * scale`, baseline offset
    /// `y = descender`, so it spans descender→ascender and sits on the baseline like a glyph.
    private func box(for font: UIFont?) -> CGRect {
        let f = font ?? UIFont.preferredFont(forTextStyle: .body)
        let side = (f.ascender - f.descender) * scale   // descender is negative → ascender + |descender|
        return CGRect(x: 0, y: f.descender, width: side, height: side)
    }

    /// TextKit 2 variant (the base takes `NSTextLocation`, iOS 15+). The run font arrives in `attributes`.
    @available(iOS 15.0, *)
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        box(for: attributes[.font] as? UIFont)
    }

    /// TextKit 1 variant (iOS 7+). No `attributes` are passed, so read the run font from the layout
    /// manager's text storage at `charIndex`.
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let font = textContainer?.layoutManager?.textStorage?
            .attribute(.font, at: charIndex, effectiveRange: nil) as? UIFont
        return box(for: font)
    }
}
#endif
