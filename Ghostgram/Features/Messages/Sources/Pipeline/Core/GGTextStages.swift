import Foundation

// The three text stages of the outgoing pipeline and their fixed order. Each stage is pure:
// (text + entities, protected ranges) -> edits. Translation before sending is not here: it is a
// UI step that runs before the message is enqueued (see GGTranslateBeforeSending).

public enum GGTextStageKind: String, CaseIterable {
    /// User rules, whole words, one pass (no chains).
    case wordReplacement
    /// ALL CAPS → normal case outside links, mentions, commands and code.
    case antiCaps
    /// A mention of the chosen profile over the plain text (never over links or code).
    case hyperlink
}

/// What the pipeline knows about the chat and the message.
public struct GGTextPipelineContext: Equatable {
    public var isBot: Bool
    public var isSavedMessages: Bool
    /// Copies (forward fallback) and service sends: never transformed.
    public var isVerbatim: Bool

    public init(isBot: Bool, isSavedMessages: Bool, isVerbatim: Bool) {
        self.isBot = isBot
        self.isSavedMessages = isSavedMessages
        self.isVerbatim = isVerbatim
    }
}

public struct GGTextReplacementRule: Codable, Equatable {
    public var source: String
    public var replacement: String
    /// Match only whole words (default): «да» does not turn «давай» into «нетвай».
    public var wholeWord: Bool
    public var caseSensitive: Bool

    public init(source: String, replacement: String, wholeWord: Bool = true, caseSensitive: Bool = false) {
        self.source = source
        self.replacement = replacement
        self.wholeWord = wholeWord
        self.caseSensitive = caseSensitive
    }
}

public struct GGTextPipelineConfiguration: Equatable {
    public var replacementRules: [GGTextReplacementRule]
    public var antiCaps: Bool
    public var hyperlink: Bool

    public init(replacementRules: [GGTextReplacementRule] = [], antiCaps: Bool = false, hyperlink: Bool = false) {
        self.replacementRules = replacementRules
        self.antiCaps = antiCaps
        self.hyperlink = hyperlink
    }

    public var isEmpty: Bool {
        return self.replacementRules.isEmpty && !self.antiCaps && !self.hyperlink
    }
}

public enum GGTextPipeline {
    /// The order is part of the contract (tested): rules see what the user typed, case is fixed
    /// after them, and the mention overlay is added last over the final text. «Язык бурмалды» and
    /// «Антипоиск» were removed by the owner on 2026-10-27.
    public static let order: [GGTextStageKind] = [.wordReplacement, .antiCaps, .hyperlink]

    /// Stages that make sense for this chat and message.
    public static func enabledStages(configuration: GGTextPipelineConfiguration, context: GGTextPipelineContext, text: String) -> [GGTextStageKind] {
        if context.isVerbatim || configuration.isEmpty {
            return []
        }
        if context.isBot {
            // Bots get exactly what was typed: commands, button texts, codes.
            return []
        }
        let isCommand = text.hasPrefix("/")
        var result: [GGTextStageKind] = []
        for stage in GGTextPipeline.order {
            switch stage {
            case .wordReplacement:
                if !configuration.replacementRules.isEmpty {
                    result.append(stage)
                }
            case .antiCaps:
                if configuration.antiCaps && !isCommand {
                    result.append(stage)
                }
            case .hyperlink:
                if configuration.hyperlink && !isCommand && !context.isSavedMessages {
                    result.append(stage)
                }
            }
        }
        return result
    }

    public static func run(_ input: GGPipelineText, configuration: GGTextPipelineConfiguration, context: GGTextPipelineContext) -> GGPipelineText {
        var current = input
        for stage in GGTextPipeline.enabledStages(configuration: configuration, context: context, text: input.text) {
            current = GGTextPipeline.apply(stage, to: current, configuration: configuration)
        }
        return current
    }

    public static func apply(_ stage: GGTextStageKind, to text: GGPipelineText, configuration: GGTextPipelineConfiguration) -> GGPipelineText {
        if text.text.isEmpty {
            return text
        }
        let protected = GGProtectedRanges.compute(text)
        switch stage {
        case .wordReplacement:
            return text.applying(GGWordReplacementStage.edits(text.text, rules: configuration.replacementRules, protected: protected))
        case .antiCaps:
            return text.applying(GGAntiCapsStage.edits(text.text, protected: protected))
        case .hyperlink:
            return GGHyperlinkStage.apply(text)
        }
    }
}

// MARK: - Word replacement

enum GGWordReplacementStage {
    private struct Match {
        let range: Range<Int>
        let replacement: String
    }

    static func isWordCharacter(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            // Surrogate halves belong to emoji and other symbols, not to words.
            return false
        }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    static func edits(_ text: String, rules: [GGTextReplacementRule], protected: [Range<Int>]) -> [GGTextEdit] {
        let string = text as NSString
        let units = Array(text.utf16)
        var matches: [Match] = []
        for rule in rules {
            let source = rule.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty {
                continue
            }
            var options: NSString.CompareOptions = []
            if !rule.caseSensitive {
                options.insert(.caseInsensitive)
            }
            var searchRange = NSRange(location: 0, length: string.length)
            while searchRange.length > 0 {
                let found = string.range(of: source, options: options, range: searchRange)
                if found.location == NSNotFound || found.length == 0 {
                    break
                }
                let range = found.location ..< (found.location + found.length)
                searchRange = NSRange(location: range.upperBound, length: string.length - range.upperBound)
                if rule.wholeWord {
                    if range.lowerBound > 0, GGWordReplacementStage.isWordCharacter(units[range.lowerBound - 1]) {
                        continue
                    }
                    if range.upperBound < units.count, GGWordReplacementStage.isWordCharacter(units[range.upperBound]) {
                        continue
                    }
                }
                if GGProtectedRanges.intersects(range, protected) {
                    continue
                }
                let matched = string.substring(with: found)
                let replacement = rule.caseSensitive ? rule.replacement : GGWordReplacementStage.adaptCase(of: matched, to: rule.replacement)
                matches.append(Match(range: range, replacement: replacement))
            }
        }
        // One pass over the original text: earliest match first, the longest wins a tie, no
        // replacement is fed into another rule.
        matches.sort(by: { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.range.count > rhs.range.count
        })
        var result: [GGTextEdit] = []
        var lastEnd = 0
        for match in matches {
            if match.range.lowerBound < lastEnd {
                continue
            }
            result.append(GGTextEdit(range: match.range, replacement: match.replacement))
            lastEnd = match.range.upperBound
        }
        return result
    }

    static func adaptCase(of matched: String, to replacement: String) -> String {
        let letters = matched.filter { $0.isLetter }
        if letters.count > 1 && letters.allSatisfy({ $0.isUppercase }) {
            return replacement.uppercased()
        }
        if let first = letters.first, first.isUppercase, let replacementFirst = replacement.first {
            return String(replacementFirst).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}

// MARK: - Anti-caps

enum GGAntiCapsStage {
    static func edits(_ text: String, protected: [Range<Int>]) -> [GGTextEdit] {
        let items = GGCharacterWalker.items(text)
        var letters = 0
        var uppercase = 0
        var lowercase = 0
        for item in items where item.character.isLetter && !GGProtectedRanges.intersects(item.range, protected) {
            letters += 1
            if item.character.isUppercase {
                uppercase += 1
            } else if item.character.isLowercase {
                lowercase += 1
            }
        }
        guard letters >= 4 else {
            return []
        }
        guard lowercase == 0 || Double(uppercase) / Double(letters) >= 0.8 else {
            return []
        }
        var result: [GGTextEdit] = []
        var sentenceStart = true
        for item in items {
            let character = item.character
            let isProtected = GGProtectedRanges.intersects(item.range, protected)
            if character.isLetter {
                if !isProtected {
                    let updated = sentenceStart ? String(character).uppercased() : String(character).lowercased()
                    if updated != String(character) {
                        result.append(GGTextEdit(range: item.range, replacement: updated))
                    }
                }
                sentenceStart = false
            } else if character == "." || character == "!" || character == "?" || character == "…" || character.isNewline {
                sentenceStart = true
            } else if character.isNumber || isProtected {
                sentenceStart = false
            }
        }
        return result
    }
}

// MARK: - Hyperlink (mention overlay)

enum GGHyperlinkStage {
    /// Adds overlay entities over the parts of the text not covered by links, mentions or code.
    /// Existing entities are kept (bold stays bold under the link).
    static func apply(_ text: GGPipelineText) -> GGPipelineText {
        let length = text.utf16Count
        let covered = GGProtectedRanges.merged(text.entities.filter { $0.excludesOverlay }.map { $0.range })
        var gaps: [Range<Int>] = []
        var cursor = 0
        for range in covered {
            if range.lowerBound > cursor {
                gaps.append(cursor ..< range.lowerBound)
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < length {
            gaps.append(cursor ..< length)
        }
        var result = text
        for gap in gaps {
            if let trimmed = GGHyperlinkStage.trimmed(gap, in: text) {
                result.entities.append(GGPipelineEntity(range: trimmed, isProtected: true, excludesOverlay: true, tag: GGPipelineEntity.addedOverlay))
            }
        }
        return result
    }

    private static func trimmed(_ range: Range<Int>, in text: GGPipelineText) -> Range<Int>? {
        let units = Array(text.text.utf16)
        var lower = range.lowerBound
        var upper = range.upperBound
        func isSpace(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else {
                return false
            }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while lower < upper && isSpace(units[lower]) {
            lower += 1
        }
        while upper > lower && isSpace(units[upper - 1]) {
            upper -= 1
        }
        if lower >= upper {
            return nil
        }
        return lower ..< upper
    }
}
