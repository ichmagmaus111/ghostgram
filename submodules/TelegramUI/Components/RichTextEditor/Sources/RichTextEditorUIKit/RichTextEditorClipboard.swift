#if canImport(UIKit)
import Foundation
import RichTextEditorCore

/// Public façade for serializing a `Document` into the editor's pasteboard representations, so a host
/// (e.g. a chat "Copy" action on a rich message) can put rich content on the clipboard in the SAME three
/// formats the editor itself writes — without reaching through the internal copy responder. The editor's
/// own `writeSelectionToPasteboard` is a thin caller of `pasteboardItem(for:)`, so the format can't drift.
public enum RichTextEditorClipboard {
    /// Private pasteboard UTI carrying a JSON-encoded `Document` (full within-app fidelity, incl. between
    /// composers). The richest of the three representations the editor reads on paste, ahead of RTF and plain.
    public static let fragmentUTI = "org.telegram.richtexteditor.fragment"

    /// The pasteboard item for a whole `Document`: the private fragment UTI (JSON, lossless), `public.rtf`
    /// (cross-app), and `public.utf8-plain-text`. Assign as a single pasteboard item, e.g.
    /// `UIPasteboard.general.items = [RichTextEditorClipboard.pasteboardItem(for: document)]`.
    /// `plain` defaults to `externalChecklistPlainText(document.blocks)` — top-level blocks joined by "\n",
    /// with an emoji checkbox prefix (⬜/✅) on checklist paragraphs for external share.
    public static func pasteboardItem(for document: Document, plain: String? = nil) -> [String: Any] {
        var item: [String: Any] = [:]
        if let data = try? DocumentCodec.encode(document) { item[fragmentUTI] = data }
        if let rtf = RTFConversion.rtfData(from: document) { item["public.rtf"] = rtf }
        item["public.utf8-plain-text"] = plain ?? externalChecklistPlainText(document.blocks)
        return item
    }
}
#endif
