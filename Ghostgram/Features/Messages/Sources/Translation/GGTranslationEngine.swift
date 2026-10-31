import Foundation
import NaturalLanguage
import SwiftSignalKit
import TelegramCore
import GGCore
import GGFeaturesShared

/// Translation by a service other than Telegram's server: Google's JSON endpoint (`gtx`, the one
/// upstream's TranslateUI already uses, never an HTML page) or Apple's on-device translation.
///
/// Formatting survives: the text is cut at protected entities (custom emoji, code, links,
/// mentions, commands…), only the plain segments are translated — all of them in one request —
/// and the protected parts and the entities that cover whole segments are put back around the
/// translation. Nothing about the user goes into a request; `GGNetwork` follows the user's proxy.
enum GGTranslationEngine {
    /// One text of a request, split for translation.
    struct Prepared {
        enum Piece {
            case fixed(String)
            case translatable(String)
        }

        let pieces: [Piece]
        /// Entities and the indexes of the pieces they start / end at (exclusive end).
        let entities: [(entity: MessageTextEntity, startPiece: Int, endPiece: Int)]
    }

    static func isFixed(_ type: MessageTextEntityType) -> Bool {
        switch type {
        case .Mention, .Hashtag, .BotCommand, .Url, .Email, .Code, .Pre, .TextUrl, .TextMention, .PhoneNumber, .BankCard, .TonAddress, .CustomEmoji, .FormattedDate:
            return true
        case .Unknown, .Bold, .Italic, .Strikethrough, .BlockQuote, .Underline, .Spoiler, .Custom:
            return false
        }
    }

    static func prepare(text: String, entities: [MessageTextEntity]) -> Prepared {
        let units = Array(text.utf16)
        let length = units.count
        var fixedRanges: [Range<Int>] = []
        // Every entity boundary: a fixed region is cut there, so each entity in it keeps its own
        // bounds (custom emoji side by side, an emoji inside a link, a bold run ending in a link).
        var cutSet = Set<Int>()
        for entity in entities {
            let lower = max(0, min(length, entity.range.lowerBound))
            let upper = max(lower, min(length, entity.range.upperBound))
            cutSet.insert(lower)
            cutSet.insert(upper)
            if upper > lower && GGTranslationEngine.isFixed(entity.type) {
                fixedRanges.append(lower ..< upper)
            }
        }
        let cuts = cutSet.sorted()
        fixedRanges.sort(by: { $0.lowerBound < $1.lowerBound })
        var merged: [Range<Int>] = []
        for range in fixedRanges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        // Boundaries of the pieces in UTF-16 offsets.
        var pieces: [Prepared.Piece] = []
        var bounds: [Int] = [0]
        func substring(_ range: Range<Int>) -> String {
            return String(decoding: units[range], as: UTF16.self)
        }
        var cursor = 0
        for range in merged {
            if range.lowerBound > cursor {
                pieces.append(.translatable(substring(cursor ..< range.lowerBound)))
                bounds.append(range.lowerBound)
            }
            var start = range.lowerBound
            for cut in cuts where cut > range.lowerBound && cut < range.upperBound {
                pieces.append(.fixed(substring(start ..< cut)))
                bounds.append(cut)
                start = cut
            }
            pieces.append(.fixed(substring(start ..< range.upperBound)))
            bounds.append(range.upperBound)
            cursor = range.upperBound
        }
        if cursor < length {
            pieces.append(.translatable(substring(cursor ..< length)))
            bounds.append(length)
        }
        var mapped: [(entity: MessageTextEntity, startPiece: Int, endPiece: Int)] = []
        for entity in entities {
            guard let start = bounds.firstIndex(of: entity.range.lowerBound), let end = bounds.firstIndex(of: entity.range.upperBound), end > start else {
                // Covers part of a segment: the translation can not keep it.
                continue
            }
            mapped.append((entity, start, end))
        }
        return Prepared(pieces: pieces, entities: mapped)
    }

    static func assemble(_ prepared: Prepared, translations: [String]) -> (String, [MessageTextEntity]) {
        var result = ""
        var offsets: [Int] = [0]
        var translationIndex = 0
        for piece in prepared.pieces {
            switch piece {
            case let .fixed(text):
                result += text
            case let .translatable(text):
                if translationIndex < translations.count {
                    result += GGTranslationEngine.keepingOuterSpaces(of: text, translation: translations[translationIndex])
                } else {
                    result += text
                }
                translationIndex += 1
            }
            offsets.append((result as NSString).length)
        }
        var entities: [MessageTextEntity] = []
        for item in prepared.entities where item.endPiece < offsets.count {
            let range = offsets[item.startPiece] ..< offsets[item.endPiece]
            if !range.isEmpty {
                entities.append(MessageTextEntity(range: range, type: item.entity.type))
            }
        }
        return (result, entities)
    }

    /// Services trim the spaces around a fragment; the text around fixed parts needs them back.
    static func keepingOuterSpaces(of source: String, translation: String) -> String {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = String(source.prefix(while: { $0.isWhitespace || $0.isNewline }))
        let trailing = String(String(source.reversed()).prefix(while: { $0.isWhitespace || $0.isNewline }).reversed())
        if trimmed.isEmpty {
            return source
        }
        return leading + trimmed + trailing
    }

    static func needsTranslation(_ text: String) -> Bool {
        return text.contains(where: { $0.isLetter })
    }

    // MARK: Requests

    /// Translates texts with entities to `toLang` by the given service (not Telegram).
    static func translate(_ texts: [(String, [MessageTextEntity])], toLang: String, service: GGTranslationServiceKind) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
        let prepared = texts.map { GGTranslationEngine.prepare(text: $0.0, entities: $0.1) }
        var fragments: [String] = []
        for item in prepared {
            for piece in item.pieces {
                if case let .translatable(text) = piece {
                    fragments.append(text)
                }
            }
        }
        let fragmentsSignal: Signal<[String], TranslationError>
        switch service {
        case .google:
            fragmentsSignal = GGGoogleTranslate.translate(fragments, toLang: toLang)
        case .system:
            fragmentsSignal = GGSystemTranslate.translate(fragments, toLang: toLang)
        case .telegram:
            fragmentsSignal = .fail(.generic)
        }
        return fragmentsSignal
        |> map { translated -> [(String, [MessageTextEntity])] in
            var cursor = 0
            var result: [(String, [MessageTextEntity])] = []
            for item in prepared {
                var own: [String] = []
                for piece in item.pieces {
                    if case .translatable = piece {
                        own.append(cursor < translated.count ? translated[cursor] : "")
                        cursor += 1
                    }
                }
                result.append(GGTranslationEngine.assemble(item, translations: own))
            }
            return result
        }
    }
}

// MARK: - Google (gtx JSON)

enum GGGoogleTranslate {
    /// URL length stays well below what proxies and the endpoint accept.
    static let maximumQueryLength = 6000

    static func translate(_ fragments: [String], toLang: String) -> Signal<[String], TranslationError> {
        if fragments.isEmpty {
            return .single([])
        }
        // Fragments without letters are not sent at all. A fragment longer than one request may be
        // (the text travels in the URL; the endpoint answers 400 to a long one) is sent in parts.
        var parts: [String] = []
        var owners: [(fragment: Int, parts: Range<Int>)] = []
        var requestIndexes: [Int] = []
        for (index, fragment) in fragments.enumerated() where GGTranslationEngine.needsTranslation(fragment) {
            let fragmentParts = GGGoogleTranslate.split(fragment, maximumLength: GGGoogleTranslate.maximumQueryLength, length: { GGGoogleTranslate.encoded($0).count })
            owners.append((index, parts.count ..< parts.count + fragmentParts.count))
            for part in fragmentParts {
                if GGTranslationEngine.needsTranslation(part) {
                    requestIndexes.append(parts.count)
                }
                parts.append(part)
            }
        }
        var batches: [[Int]] = []
        var current: [Int] = []
        var currentLength = 0
        for index in requestIndexes {
            let length = GGGoogleTranslate.encoded(parts[index]).count
            if !current.isEmpty && currentLength + length > GGGoogleTranslate.maximumQueryLength {
                batches.append(current)
                current = []
                currentLength = 0
            }
            current.append(index)
            currentLength += length
        }
        if !current.isEmpty {
            batches.append(current)
        }
        let signals = batches.map { batch -> Signal<[(Int, String)], TranslationError> in
            return GGGoogleTranslate.request(batch.map { parts[$0] }, toLang: toLang)
            |> map { translated -> [(Int, String)] in
                return zip(batch, translated).map { ($0, $1) }
            }
        }
        return combineLatest(signals)
        |> map { results -> [String] in
            var translatedParts = parts
            for batch in results {
                for (index, text) in batch {
                    translatedParts[index] = text
                }
            }
            var output = fragments
            for owner in owners {
                if owner.parts.count == 1 {
                    output[owner.fragment] = translatedParts[owner.parts.lowerBound]
                } else {
                    output[owner.fragment] = owner.parts.map { index in
                        return GGTranslationEngine.keepingOuterSpaces(of: parts[index], translation: translatedParts[index])
                    }.joined()
                }
            }
            return output
        }
    }

    /// Cuts a text into parts no longer than `maximumLength` (as `length` counts) whose
    /// concatenation is the text: at line ends first, then at sentence ends, then at spaces; a word
    /// longer than a part is cut between characters.
    static func split(_ text: String, maximumLength: Int, length: (String) -> Int) -> [String] {
        return GGGoogleTranslate.split(text, level: 0, maximumLength: max(1, maximumLength), length: length)
    }

    private static func split(_ text: String, level: Int, maximumLength: Int, length: (String) -> Int) -> [String] {
        if length(text) <= maximumLength {
            return [text]
        }
        let tokens: [String]
        switch level {
        case 0:
            tokens = GGGoogleTranslate.tokens(text, cutAfter: { character, _ in
                return character.isNewline
            })
        case 1:
            tokens = GGGoogleTranslate.tokens(text, cutAfter: { character, next in
                guard let next, next.isWhitespace else {
                    return false
                }
                return [".", "!", "?", "…", "。", "！", "？"].contains(character)
            })
        case 2:
            tokens = GGGoogleTranslate.tokens(text, cutAfter: { character, next in
                guard let next else {
                    return false
                }
                return character.isWhitespace && !next.isWhitespace
            })
        default:
            tokens = text.map { String($0) }
        }
        if tokens.count <= 1 && level < 3 {
            return GGGoogleTranslate.split(text, level: level + 1, maximumLength: maximumLength, length: length)
        }
        var result: [String] = []
        var current = ""
        var currentLength = 0
        for token in tokens {
            let tokenLength = length(token)
            if tokenLength > maximumLength {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                    currentLength = 0
                }
                if level < 3 {
                    result.append(contentsOf: GGGoogleTranslate.split(token, level: level + 1, maximumLength: maximumLength, length: length))
                } else {
                    // One character longer than a part: nothing to cut any more.
                    result.append(token)
                }
                continue
            }
            if !current.isEmpty && currentLength + tokenLength > maximumLength {
                result.append(current)
                current = ""
                currentLength = 0
            }
            current += token
            currentLength += tokenLength
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// The text in pieces, cut after every character `cutAfter` accepts (given the next one).
    private static func tokens(_ text: String, cutAfter: (Character, Character?) -> Bool) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if cutAfter(character, next) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func encoded(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func request(_ texts: [String], toLang: String) -> Signal<[String], TranslationError> {
        var query = "client=gtx&sl=auto&tl=" + GGGoogleTranslate.encoded(toLang) 
        for text in texts {
            query += "&q=" + GGGoogleTranslate.encoded(text)
        }
        guard let url = URL(string: "https://translate.googleapis.com/translate_a/t?" + query) else {
            return .fail(.generic)
        }
        return GGNetwork.shared.fetch(GGNetworkRequest(url: url, maxBytes: 2 * 1024 * 1024))
        |> mapError { error -> TranslationError in
            if case .http(429) = error {
                return .limitExceeded
            }
            return .generic
        }
        |> mapToSignal { response -> Signal<[String], TranslationError> in
            guard let data = response.data, let parsed = GGGoogleTranslate.parse(data, count: texts.count) else {
                return .fail(.generic)
            }
            return .single(parsed)
        }
    }

    /// `translate_a/t` answers a JSON array aligned with the `q` parameters; with `sl=auto` each
    /// element is `[translation, detectedLanguage]`. A single text may come back as a bare value
    /// or as one `[translation, detectedLanguage]` pair.
    static func parse(_ data: Data, count: Int) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        func text(_ value: Any) -> String? {
            if let string = value as? String {
                return string
            }
            if let array = value as? [Any], let string = array.first as? String {
                return string
            }
            return nil
        }
        if let array = object as? [Any] {
            let values = array.compactMap(text)
            if values.count == count {
                return values
            }
        }
        if count == 1, let single = text(object) {
            return [single]
        }
        return nil
    }
}

// MARK: - System (Apple Translation, iOS 18+)

enum GGSystemTranslate {
    private static let recognizer = NLLanguageRecognizer()
    private static let recognizerLock = NSLock()

    static func detectLanguage(_ text: String) -> String? {
        GGSystemTranslate.recognizerLock.lock()
        defer {
            GGSystemTranslate.recognizerLock.unlock()
        }
        GGSystemTranslate.recognizer.reset()
        GGSystemTranslate.recognizer.processString(String(text.prefix(512)))
        return GGSystemTranslate.recognizer.dominantLanguage?.rawValue
    }

    /// Upstream's own system translation service (`engineExperimentalInternalTranslationService`,
    /// installed by the chat screen). Without it the request falls back to an error, and the
    /// caller shows the usual failure.
    static func translate(_ fragments: [String], toLang: String) -> Signal<[String], TranslationError> {
        guard let service = engineExperimentalInternalTranslationService else {
            return .fail(.generic)
        }
        let joined = fragments.joined(separator: "\n")
        guard let fromLang = GGSystemTranslate.detectLanguage(joined), fromLang != toLang else {
            return .single(fragments)
        }
        var texts: [AnyHashable: String] = [:]
        for (index, fragment) in fragments.enumerated() where GGTranslationEngine.needsTranslation(fragment) {
            texts[AnyHashable(index)] = fragment
        }
        if texts.isEmpty {
            return .single(fragments)
        }
        return service.translate(texts: texts, fromLang: fromLang, toLang: toLang)
        |> castError(TranslationError.self)
        |> mapToSignal { result -> Signal<[String], TranslationError> in
            guard let result else {
                return .fail(.generic)
            }
            var output = fragments
            for (index, _) in fragments.enumerated() {
                if let value = result[AnyHashable(index)] {
                    output[index] = value
                }
            }
            return .single(output)
        }
    }
}
