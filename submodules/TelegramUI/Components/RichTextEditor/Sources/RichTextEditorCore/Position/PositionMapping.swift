import Foundation

public extension PositionResolver {
    struct TextPosition: Equatable {
        public let ref: TextNodeRef
        public let offset: Int   // UTF-16 offset within that text node
    }

    /// If `pos` lands inside a `.text` node, returns which model text node and the offset.
    /// Returns nil at structural boundaries (between blocks, before/after atoms).
    static func textPosition(at pos: Int, in root: DocNode) -> TextPosition? {
        // Walk like resolve, but return the text child the position falls within (inclusive of
        // both ends, so a caret at the very start/end of a text node maps into it).
        func walk(_ node: DocNode, _ contentStart: Int) -> TextPosition? {
            var acc = 0
            for child in node.children {
                let childStart = acc
                let childEnd = acc + child.nodeSize
                let offsetInContent = pos - contentStart
                if case .text(_, let ref) = child {
                    if offsetInContent >= childStart && offsetInContent <= childEnd {
                        return TextPosition(ref: ref, offset: offsetInContent - childStart)
                    }
                } else if !child.isLeaf {
                    let childContentStart = contentStart + childStart + 1
                    if pos >= childContentStart - 1 && pos <= childContentStart + childContentSize(child) + 1 {
                        if let found = walk(child, childContentStart) { return found }
                    }
                }
                acc = childEnd
            }
            return nil
        }
        return walk(root, 0)
    }

    /// Inverse: the global position for an offset within a model text node.
    static func globalPosition(of ref: TextNodeRef, offset: Int, in root: DocNode) -> Int? {
        func walk(_ node: DocNode, _ contentStart: Int) -> Int? {
            var acc = 0
            for child in node.children {
                let childStart = acc
                if case .text(_, let r) = child, r == ref {
                    return contentStart + childStart + offset
                } else if !child.isLeaf {
                    if let found = walk(child, contentStart + childStart + 1) { return found }
                }
                acc += child.nodeSize
            }
            return nil
        }
        return walk(root, 0)
    }

    private static func childContentSize(_ node: DocNode) -> Int {
        node.children.reduce(0) { $0 + $1.nodeSize }
    }
}
