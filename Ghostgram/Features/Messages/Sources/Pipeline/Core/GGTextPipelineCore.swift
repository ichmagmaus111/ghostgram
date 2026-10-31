import Foundation

// The outgoing text pipeline without TelegramCore: plain text + entities with UTF-16 ranges (the
// unit Telegram's MessageTextEntity uses). The host test compiles this directory on its own
// (//Ghostgram/Features/Messages:GGMessagesTests), so nothing here may import app modules.
//
// Every stage produces a list of non-overlapping edits; `GGPipelineText.applying(_:)` rewrites the
// text once and moves every entity with it, so formatting and custom emoji survive any stage.

/// One entity of the text, reduced to what the pipeline needs.
public struct GGPipelineEntity: Equatable {
    /// UTF-16 range in the text.
    public var range: Range<Int>
    /// The stages never change the text under it: links, mentions, commands, hashtags, code,
    /// custom emoji (their alt text must stay the emoji), phone numbers, cards.
    public var isProtected: Bool
    /// Link-like or code: a mention overlay (hyperlink stage) is never put over it.
    public var excludesOverlay: Bool
    /// Index of the original entity in the caller's array, or `GGPipelineEntity.addedOverlay`.
    public var tag: Int

    public static let addedOverlay: Int = -1

    public init(range: Range<Int>, isProtected: Bool, excludesOverlay: Bool, tag: Int) {
        self.range = range
        self.isProtected = isProtected
        self.excludesOverlay = excludesOverlay
        self.tag = tag
    }
}

/// A replacement of one UTF-16 range of the current text.
public struct GGTextEdit: Equatable {
    public let range: Range<Int>
    public let replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public struct GGPipelineText: Equatable {
    public var text: String
    public var entities: [GGPipelineEntity]

    public init(text: String, entities: [GGPipelineEntity]) {
        self.text = text
        self.entities = entities
    }

    public var utf16Count: Int {
        return self.text.utf16.count
    }

    /// Applies non-overlapping edits (any order) and moves the entities:
    /// - an entity boundary outside every edit shifts by the length change of the edits before it;
    /// - a start inside an edit moves to the edit's new start, an end inside an edit to its new end;
    /// - entities that end up empty are dropped.
    public func applying(_ edits: [GGTextEdit]) -> GGPipelineText {
        let length = self.utf16Count
        var sorted = edits.filter { edit in
            return edit.range.lowerBound >= 0 && edit.range.upperBound <= length
        }
        sorted.sort(by: { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.range.upperBound < rhs.range.upperBound
        })
        var accepted: [GGTextEdit] = []
        var lastEnd = 0
        for edit in sorted {
            if edit.range.lowerBound < lastEnd {
                continue
            }
            let original = self.substring(edit.range)
            if original == edit.replacement {
                continue
            }
            accepted.append(edit)
            lastEnd = edit.range.upperBound
        }
        if accepted.isEmpty {
            return self
        }

        let source = Array(self.text.utf16)
        var result: [UInt16] = []
        result.reserveCapacity(source.count + 16)
        // New bounds of every edit, for the entity mapping.
        var mapped: [(old: Range<Int>, new: Range<Int>)] = []
        var cursor = 0
        for edit in accepted {
            if cursor < edit.range.lowerBound {
                result.append(contentsOf: source[cursor ..< edit.range.lowerBound])
            }
            let newStart = result.count
            result.append(contentsOf: Array(edit.replacement.utf16))
            mapped.append((old: edit.range, new: newStart ..< result.count))
            cursor = edit.range.upperBound
        }
        if cursor < source.count {
            result.append(contentsOf: source[cursor ..< source.count])
        }

        func map(_ position: Int, isStart: Bool) -> Int {
            var delta = 0
            for item in mapped {
                let old = item.old
                let change = item.new.count - old.count
                if old.upperBound < position {
                    delta += change
                } else if old.upperBound == position {
                    if old.isEmpty {
                        // A pure insertion at an entity boundary stays outside the entity.
                        if isStart {
                            delta += change
                        }
                    } else {
                        delta += change
                    }
                } else if old.lowerBound < position {
                    return isStart ? item.new.lowerBound : item.new.upperBound
                } else {
                    break
                }
            }
            return position + delta
        }

        var entities: [GGPipelineEntity] = []
        for entity in self.entities {
            let start = map(entity.range.lowerBound, isStart: true)
            let end = map(entity.range.upperBound, isStart: false)
            if end > start {
                var updated = entity
                updated.range = start ..< end
                entities.append(updated)
            }
        }
        let text = String(decoding: result, as: UTF16.self)
        return GGPipelineText(text: text, entities: entities)
    }

    public func substring(_ range: Range<Int>) -> String {
        let utf16 = self.text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count, !range.isEmpty else {
            return ""
        }
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(start, offsetBy: range.count)
        return String(utf16[start ..< end]) ?? ""
    }
}

/// Ranges the stages must not touch: protected entities plus what the server would detect itself
/// in plain text (links and domains, e-mails, @usernames, /commands, #hashtags, $cashtags).
public enum GGProtectedRanges {
    private static let expressions: [NSRegularExpression] = {
        let patterns = [
            // Links with a scheme or www.
            "(?i)\\b(?:https?://|tg://|www\\.)[^\\s]+",
            // Bare domains, incl. IDN labels; TLD in Latin or a few Cyrillic ones.
            "(?i)(?<![\\p{L}\\p{N}_@])(?:[\\p{L}\\p{N}](?:[\\p{L}\\p{N}-]{0,61}[\\p{L}\\p{N}])?\\.)+(?:[a-z]{2,24}|рф|бел|укр|срб|мкд|қаз)\\b(?:[/?#][^\\s]*)?",
            // E-mail addresses.
            "[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)+",
            // @username.
            "(?<![\\p{L}\\p{N}_@])@[A-Za-z0-9_]{3,32}",
            // /command and /command@bot.
            "(?<![\\p{L}\\p{N}_/])/[A-Za-z0-9_]{1,64}(?:@[A-Za-z0-9_]{3,32})?",
            // #hashtag and $CASHTAG.
            "(?<![\\p{L}\\p{N}_#])#[\\p{L}\\p{N}_]+",
            "(?<![\\p{L}\\p{N}_$])\\$[A-Z]{1,8}\\b"
        ]
        return patterns.compactMap { pattern in
            return try? NSRegularExpression(pattern: pattern, options: [])
        }
    }()

    public static func compute(_ text: GGPipelineText) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for entity in text.entities where entity.isProtected {
            result.append(entity.range)
        }
        let string = text.text as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        for expression in GGProtectedRanges.expressions {
            for match in expression.matches(in: text.text, options: [], range: fullRange) {
                if match.range.location != NSNotFound && match.range.length > 0 {
                    result.append(match.range.location ..< (match.range.location + match.range.length))
                }
            }
        }
        return GGProtectedRanges.merged(result)
    }

    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
        var result: [Range<Int>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    public static func intersects(_ range: Range<Int>, _ protected: [Range<Int>]) -> Bool {
        for item in protected {
            if item.lowerBound >= range.upperBound {
                break
            }
            if item.overlaps(range) {
                return true
            }
        }
        return false
    }
}

/// Walks the Characters of a text with their UTF-16 ranges.
struct GGCharacterWalker {
    struct Item {
        let character: Character
        let range: Range<Int>
    }

    static func items(_ text: String) -> [Item] {
        var result: [Item] = []
        var offset = 0
        for character in text {
            let length = character.utf16.count
            result.append(Item(character: character, range: offset ..< (offset + length)))
            offset += length
        }
        return result
    }
}
