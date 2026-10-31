import Foundation

/// What a toolbar format applies to when nothing is selected: the word right before the caret
/// (whitespace between it and the caret skipped), as the old client did. Pure (Foundation only).
enum GGFormattingSelection {
    /// The UTF-16 range of the last word before `caret` in `text`, nil when there is none.
    static func lastWordRange(in text: NSString, caret: Int) -> NSRange? {
        let length = text.length
        if length == 0 || caret <= 0 {
            return nil
        }
        let boundaries = CharacterSet.whitespacesAndNewlines
        func isBoundary(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else {
                // A surrogate half belongs to a word (emoji, rare scripts).
                return false
            }
            return boundaries.contains(scalar)
        }
        var end = min(caret, length) - 1
        while end >= 0 && isBoundary(end) {
            end -= 1
        }
        if end < 0 {
            return nil
        }
        var start = end
        while start > 0 && !isBoundary(start - 1) {
            start -= 1
        }
        return NSRange(location: start, length: end - start + 1)
    }
}
