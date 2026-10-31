import Foundation
import Postbox
import TelegramCore
import GGCore

/// Keys of the voice zone in a message's locally derived data (`DerivedDataMessageAttribute`).
public enum GGVoiceDerivedDataKeys {
    /// Exact word timings of an Apple Speech transcription (`GGTranscriptionWords`, GGVoiceTranscription).
    public static let words = "gg.voiceWords"
    /// The caption the auto-transcription wrote (`GGVoiceAutoCaptionMark`).
    public static let autoCaption = "gg.autoTranscribed"
}

/// Written before the auto-transcription edits the caption of an own voice message, with that caption.
public struct GGVoiceAutoCaptionMark: Codable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// Keeps the transcription of a voice message / round video across edits of its caption, and hides the
/// «edited» mark that the auto-transcription's own edit would add.
///
/// - Upstream drops local attributes when the server sends an edit. For a caption edit the audio is the
///   same, so the transcription text and this zone's derived entries (word timings, the caption mark) are
///   carried over — only when the media is unchanged.
/// - The auto-transcription's edit arrives with exactly the caption in the mark: its `EditedMessageAttribute`
///   is stored hidden (the same `isHidden` upstream uses for edits the server marks as hidden). A later edit
///   by the user has another text, so its mark shows as usual.
/// - When the server stores the message again (`mergeAttributes`), a hidden edit mark of the same edit date
///   stays hidden.
///
/// Runs inside Postbox transactions: reads attributes only, no I/O. Registered in every process (the
/// notification service applies edits too).
enum GGVoiceMessageAttributes {
    static func register() {
        GGUpdateHooks.messageWillBeEdited.register({ request, attributes in
            return GGVoiceMessageAttributes.edited(request: request, attributes: attributes)
        }, order: 900)
        GGMessageAttributeHooks.mergeAttributes.register({ previous, updated in
            GGVoiceMessageAttributes.merge(previous: previous, updated: &updated)
        }, order: 900)
    }

    private static func voiceFileId(_ media: [Media]) -> MediaId? {
        for item in media {
            if let file = item as? TelegramMediaFile, file.isVoice || file.isInstantVideo {
                return file.fileId
            }
        }
        return nil
    }

    private static func zoneEntries(_ attributes: [MessageAttribute]) -> [String: CodableEntry] {
        guard let derived = attributes.first(where: { $0 is DerivedDataMessageAttribute }) as? DerivedDataMessageAttribute else {
            return [:]
        }
        var result: [String: CodableEntry] = [:]
        for key in [GGVoiceDerivedDataKeys.words, GGVoiceDerivedDataKeys.autoCaption] {
            if let entry = derived.data[key] {
                result[key] = entry
            }
        }
        return result
    }

    private static func edited(request: GGMessageEditRequest, attributes: [MessageAttribute]) -> [MessageAttribute] {
        guard let previousFileId = GGVoiceMessageAttributes.voiceFileId(request.previous.media), previousFileId == GGVoiceMessageAttributes.voiceFileId(request.updatedMedia) else {
            return attributes
        }
        var result = attributes
        if !result.contains(where: { $0 is AudioTranscriptionMessageAttribute }), let transcription = request.previous.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) {
            result.append(transcription)
        }
        let carried = GGVoiceMessageAttributes.zoneEntries(request.previous.attributes)
        if !carried.isEmpty {
            var data: [String: CodableEntry] = [:]
            if let index = result.firstIndex(where: { $0 is DerivedDataMessageAttribute }) {
                data = (result[index] as? DerivedDataMessageAttribute)?.data ?? [:]
                result.remove(at: index)
            }
            for (key, entry) in carried where data[key] == nil {
                data[key] = entry
            }
            result.append(DerivedDataMessageAttribute(data: data))
        }
        if let entry = carried[GGVoiceDerivedDataKeys.autoCaption], let mark = entry.get(GGVoiceAutoCaptionMark.self), mark.text == request.updatedText {
            if let index = result.firstIndex(where: { $0 is EditedMessageAttribute }), let edited = result[index] as? EditedMessageAttribute, !edited.isHidden {
                result[index] = EditedMessageAttribute(date: edited.date, isHidden: true)
            }
        }
        return result
    }

    private static func merge(previous: [MessageAttribute], updated: inout [MessageAttribute]) {
        guard let previousEdited = previous.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute, previousEdited.isHidden else {
            return
        }
        guard !GGVoiceMessageAttributes.zoneEntries(previous).isEmpty || !GGVoiceMessageAttributes.zoneEntries(updated).isEmpty else {
            return
        }
        guard let index = updated.firstIndex(where: { $0 is EditedMessageAttribute }), let edited = updated[index] as? EditedMessageAttribute, !edited.isHidden, edited.date == previousEdited.date else {
            return
        }
        updated[index] = EditedMessageAttribute(date: edited.date, isHidden: true)
    }
}
