#if canImport(UIKit)
import XCTest
import UIKit
@testable import RichTextEditorUIKit
import RichTextEditorCore

/// The editor scrolls the caret into view when it MOVES (arrow keys, via the `selectedTextRange`
/// setter → `onSelectionChange`). It must do the same when EDITING moves the caret — typing, delete,
/// Enter, and IME composition commit — otherwise the caret can be typed off the visible area / behind
/// the keyboard without the view following it.
final class ScrollCaretOnEditTests: XCTestCase {

    // MARK: Canvas-level: every caret-moving edit fires the host's scroll hook.

    /// A paragraph "Hello" with the caret parked at its end (the setter fire is reset away first).
    private func canvasAtEnd() -> (DocumentCanvasView, () -> Bool, () -> Void) {
        let v = DocumentCanvasView()
        v.setBlocks([.paragraph(ParagraphBlock(id: BlockID("p"), runs: [TextRun(text: "Hello")]))], width: 300)
        v.frame = CGRect(x: 0, y: 0, width: 300, height: 400); v.layoutIfNeeded()
        let end = DocumentTextPosition(v.boxes[0].textStart + v.boxes[0].textLength)
        v.selectedTextRange = DocumentTextRange(end, end)   // fires onSelectionChange; observer set AFTER
        var fired = false
        v.onSelectionChange = { fired = true }
        return (v, { fired }, { fired = false })
    }

    func test_insertText_firesOnSelectionChange() {
        let (v, fired, _) = canvasAtEnd()
        v.insertText("X")
        XCTAssertTrue(fired(), "typing must notify the host to scroll the (possibly off-screen) caret into view")
    }

    func test_deleteBackward_firesOnSelectionChange() {
        let (v, fired, _) = canvasAtEnd()
        v.deleteBackward()
        XCTAssertTrue(fired(), "delete must notify the host to scroll the caret into view")
    }

    func test_enter_firesOnSelectionChange() {
        let (v, fired, _) = canvasAtEnd()
        v.insertText("\n")   // → insertParagraphBreak (the caret drops to a new line, possibly off-screen)
        XCTAssertTrue(fired(), "Enter must notify the host to scroll the new line's caret into view")
    }

    func test_markedTextCommit_firesOnSelectionChange() {
        let v = DocumentCanvasView()
        v.setBlocks([.paragraph(ParagraphBlock(id: BlockID("p"), runs: [TextRun(text: "Hi")]))], width: 300)
        v.frame = CGRect(x: 0, y: 0, width: 300, height: 400); v.layoutIfNeeded()
        let end = DocumentTextPosition(v.boxes[0].textStart + v.boxes[0].textLength)
        v.selectedTextRange = DocumentTextRange(end, end)
        // A composition (caret at END of the marked text — not a prediction). Committing it via insertText
        // takes the marked-text branch, which doesn't run through editing { }.
        v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        var fired = false
        v.onSelectionChange = { fired = true }
        v.insertText("\u{4F60}")   // commit "你"
        XCTAssertTrue(fired, "committing an IME composition must notify the host to scroll the caret into view")
    }

    func test_setMarkedText_growingComposition_firesOnSelectionChange() {
        // A CJK/IME composition grows provisional text and ADVANCES the caret (sel at END), so it can drift
        // the caret off-screen while composing. setMarkedText sets anchor/head itself (it doesn't route
        // through the selectedTextRange setter), so it must fire the host scroll hook directly.
        let v = DocumentCanvasView()
        v.setBlocks([.paragraph(ParagraphBlock(id: BlockID("p"), runs: [TextRun(text: "Hi")]))], width: 300)
        v.frame = CGRect(x: 0, y: 0, width: 300, height: 400); v.layoutIfNeeded()
        let end = DocumentTextPosition(v.boxes[0].textStart + v.boxes[0].textLength)
        v.selectedTextRange = DocumentTextRange(end, end)
        var fired = false
        v.onSelectionChange = { fired = true }
        v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))   // composition, caret at END
        XCTAssertTrue(fired, "a growing composition must notify the host to scroll the advancing caret into view")
    }

    func test_backspaceAtCellStart_movesCaret_firesOnSelectionChange() {
        // Backspace at a table cell's first-paragraph start MOVES the caret (to the previous cell's end)
        // without deleting — via setCaret, which bypasses editing { }. That move can land the caret in a
        // distant, off-screen row, so it must fire the host scroll hook too.
        let v = DocumentCanvasView()
        v.setBlocks([
            .table(TableBlock(id: BlockID("t"),
                columns: [ColumnSpec(width: 120), ColumnSpec(width: 120)],
                rows: [
                    Row(id: BlockID("r0"), isHeader: true, cells: [
                        Cell(id: BlockID("a"), blocks: [.paragraph(ParagraphBlock(id: BlockID("ap"), runs: [TextRun(text: "A")]))]),
                        Cell(id: BlockID("b"), blocks: [.paragraph(ParagraphBlock(id: BlockID("bp"), runs: [TextRun(text: "B")]))])]),
                    Row(id: BlockID("r1"), cells: [
                        Cell(id: BlockID("c"), blocks: [.paragraph(ParagraphBlock(id: BlockID("cp"), runs: [TextRun(text: "C")]))]),
                        Cell(id: BlockID("d"), blocks: [.paragraph(ParagraphBlock(id: BlockID("dp"), runs: [TextRun(text: "D")]))])])])),
        ], width: 300)
        v.frame = CGRect(x: 0, y: 0, width: 300, height: 400); v.layoutIfNeeded()
        let t = v.boxes[0] as! TableBlockBox
        let cellStart = t.cellTextStart(row: 1, column: 0)!     // start of cell C
        v.selectedTextRange = DocumentTextRange(DocumentTextPosition(cellStart), DocumentTextPosition(cellStart))
        var fired = false
        v.onSelectionChange = { fired = true }
        v.deleteBackward()
        XCTAssertNotEqual(v.head, cellStart, "precondition: Backspace at a cell start moves the caret (no-delete)")
        XCTAssertTrue(fired, "a setCaret-based caret move must notify the host to scroll it into view")
    }

    // MARK: Façade-level: typing actually scrolls an off-screen caret back into view.

    func test_typing_scrollsOffScreenCaretBackIntoView() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))   // short viewport
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let editor = RichTextEditorView(frame: window.bounds)
        window.addSubview(editor)
        // Tall document so the last line sits well below a 200pt viewport.
        let blocks = (0..<40).map {
            Block.paragraph(ParagraphBlock(id: BlockID("p\($0)"), runs: [TextRun(text: "Line \($0)")]))
        }
        editor.document = Document(blocks: blocks)
        editor.layoutIfNeeded()
        XCTAssertTrue(editor.becomeFirstResponder())

        // Put the caret at the end of the last paragraph's text (a renderable slot).
        let last = editor.canvas.boxes.last!
        let endPos = DocumentTextPosition(last.textStart + last.textLength)
        editor.canvas.selectedTextRange = DocumentTextRange(endPos, endPos)
        editor.layoutIfNeeded()

        // Simulate the caret being scrolled off-screen (e.g. the user scrolled up).
        editor.contentOffsetForTesting = .zero
        editor.layoutIfNeeded()
        XCTAssertEqual(editor.contentOffsetForTesting.y, 0, accuracy: 0.5, "precondition: scrolled to the top")

        // Typing at the (now off-screen) caret must scroll it back into view.
        editor.canvas.insertText("Z")
        editor.layoutIfNeeded()
        XCTAssertGreaterThan(editor.contentOffsetForTesting.y, 0,
                             "typing scrolls the off-screen caret back into the visible area")
    }
}
#endif
