import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import GGFeaturesShared

/// One recognized word: its place in the transcription text (UTF-16) and in the audio (seconds).
public struct GGTranscriptionWord: Codable, Equatable {
    public var location: Int
    public var length: Int
    public var start: Double
    public var duration: Double

    public init(location: Int, length: Int, start: Double, duration: Double) {
        self.location = location
        self.length = length
        self.start = start
        self.duration = duration
    }

    public var range: NSRange {
        return NSRange(location: self.location, length: self.length)
    }
}

/// Exact word timings of a transcription made by Apple Speech, kept in the message's locally derived
/// data (`DerivedDataMessageAttribute`, merged by upstream when the server rewrites the message). Bound
/// to the text they were made for: a different text (a new transcription) makes them invalid.
/// Telegram's server transcription has no timings and never gets words: no invented timings.
public struct GGTranscriptionWords: Codable, Equatable {
    public var textLength: Int
    public var words: [GGTranscriptionWord]

    public init(textLength: Int, words: [GGTranscriptionWord]) {
        self.textLength = textLength
        self.words = words
    }

    public static let derivedDataKey = GGVoiceDerivedDataKeys.words

    /// The raw stored entry (cheap: no decoding), for caching by the bubble node.
    public static func storedEntry(in message: Message) -> Data? {
        for attribute in message.attributes {
            if let attribute = attribute as? DerivedDataMessageAttribute {
                return attribute.data[GGTranscriptionWords.derivedDataKey]?.data
            }
        }
        return nil
    }

    /// The words of a stored entry that belong to `text`, or nil.
    public static func decode(_ entry: Data, text: String) -> [GGTranscriptionWord]? {
        guard let value = CodableEntry(data: entry).get(GGTranscriptionWords.self) else {
            return nil
        }
        guard value.textLength == (text as NSString).length, !value.words.isEmpty else {
            return nil
        }
        return value.words
    }

    /// The words that belong to `text` of this message, or nil.
    public static func stored(in message: Message, text: String) -> [GGTranscriptionWord]? {
        guard let entry = GGTranscriptionWords.storedEntry(in: message) else {
            return nil
        }
        return GGTranscriptionWords.decode(entry, text: text)
    }
}

extension GGTranscriptionWords {
    /// Writes (or with nil removes) the words of a message, keeping the other derived entries.
    static func store(_ value: GGTranscriptionWords?, messageId: MessageId, engine: TelegramEngine) -> Signal<Never, NoError> {
        return engine.messages.updateLocallyDerivedData(messageId: messageId, update: { data in
            var data = data
            if let value, let entry = CodableEntry(value) {
                data[GGTranscriptionWords.derivedDataKey] = entry
            } else {
                data.removeValue(forKey: GGTranscriptionWords.derivedDataKey)
            }
            return data
        })
    }
}
