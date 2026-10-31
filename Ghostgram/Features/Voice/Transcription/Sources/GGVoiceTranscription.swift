import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import GGCore
import GGFeaturesShared

/// Transcription of voice messages and round videos (owner's decision 2026-10-21, no switches):
/// the account has Telegram Premium → Telegram's own server transcription; otherwise Apple Speech, for
/// voice messages and round videos alike. The choice is made at the moment of the request from the
/// account's live `isPremium`, so a Premium that appears or ends switches the engine on the fly; text
/// that is already there stays, new transcriptions go to the new engine.
public enum GGVoiceTranscription {
    /// The transcribe button is shown to everyone.
    public static func showsTranscribeButton() -> Bool {
        return true
    }

    /// True → Apple Speech (`transcribeWithAppleSpeech`), false → `engine.messages.transcribeAudio`.
    public static func usesAppleSpeech(context: AccountContext) -> Bool {
        return !context.isPremium
    }

    public static var wordBubblesEnabled: Bool {
        return GGVoiceSettings.wordBubbles.value
    }

    public enum Outcome {
        /// Text (and words) stored in the message; the bubble redraws from the message update.
        case stored
        /// Nothing usable: an error is stored, the bubble shows upstream's «could not transcribe».
        case failed
        /// Speech recognition is not allowed: nothing is stored, the caller explains it.
        case notAuthorized
    }

    /// Apple Speech for one message: downloads the file first (never a silent refusal), recognizes,
    /// stores the text with `storeLocallyTranscribedAudio` and the exact word timings in the message's
    /// derived data. The result is written to the message, not to the bubble: whoever shows the message
    /// redraws from the update (the bubble, the auto-transcription).
    public static func transcribeWithAppleSpeech(context: AccountContext, message: Message) -> Signal<Outcome, NoError> {
        let engine = context.engine
        let messageId = message.id
        return GGVoiceTranscription.recognize(context: context, message: message)
        |> map { transcript -> GGSpeechTranscript? in
            return transcript
        }
        |> `catch` { error -> Signal<GGSpeechTranscript?, GGSpeechError> in
            switch error {
            case .notAuthorized:
                return .fail(.notAuthorized)
            default:
                return .single(nil)
            }
        }
        |> mapToSignal { transcript -> Signal<Outcome, GGSpeechError> in
            return Signal { subscriber in
                let store: Signal<Never, NoError>
                if let transcript {
                    let words = GGTranscriptionWords(textLength: (transcript.text as NSString).length, words: transcript.words)
                    store = GGTranscriptionWords.store(words, messageId: messageId, engine: engine)
                    |> then(engine.messages.storeLocallyTranscribedAudio(messageId: messageId, text: transcript.text, isFinal: true, error: nil))
                } else {
                    store = GGTranscriptionWords.store(nil, messageId: messageId, engine: engine)
                    |> then(engine.messages.storeLocallyTranscribedAudio(messageId: messageId, text: "", isFinal: true, error: .generic))
                }
                return store.start(completed: {
                    subscriber.putNext(transcript == nil ? .failed : .stored)
                    subscriber.putCompletion()
                })
            }
        }
        |> `catch` { _ -> Signal<Outcome, NoError> in
            return .single(.notAuthorized)
        }
    }

    /// Recognition only (no storing): used by the auto-transcription of own messages.
    public static func recognize(context: AccountContext, message: Message) -> Signal<GGSpeechTranscript, GGSpeechError> {
        guard let file = GGVoiceTranscription.transcribableFile(in: message) else {
            return .fail(.noSpeech)
        }
        let interfaceLanguage = context.sharedContext.currentPresentationData.with({ $0 }).strings.baseLanguageCode
        return GGSpeechRecognition.authorize()
        |> castError(GGSpeechError.self)
        |> mapToSignal { authorized -> Signal<String, GGSpeechError> in
            if !authorized {
                return .fail(.notAuthorized)
            }
            return GGVoiceTranscription.downloadedPath(context: context, message: message, file: file)
        }
        |> mapToSignal { path -> Signal<GGSpeechTranscript, GGSpeechError> in
            return GGSpeechRecognition.recognize(path: path, interfaceLanguage: interfaceLanguage)
        }
    }

    /// The voice message or round video of a message.
    public static func transcribableFile(in message: Message) -> TelegramMediaFile? {
        for media in message.media {
            if let file = media as? TelegramMediaFile, file.isVoice || file.isInstantVideo {
                return file
            }
        }
        return nil
    }

    /// The local path of the complete file, fetching it if it is not downloaded yet.
    private static func downloadedPath(context: AccountContext, message: Message, file: TelegramMediaFile) -> Signal<String, GGSpeechError> {
        let mediaBox = context.account.postbox.mediaBox
        let reference = FileMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource)
        let fetch = fetchedMediaResource(mediaBox: mediaBox, userLocation: .peer(message.id.peerId), userContentType: file.isInstantVideo ? .audioVideoMessage : .audio, reference: reference)
        return Signal { subscriber in
            let fetchDisposable = fetch.start(error: { _ in
                subscriber.putError(.failed)
            })
            let dataDisposable = (mediaBox.resourceData(file.resource)
            |> filter { $0.complete }
            |> take(1)).start(next: { data in
                subscriber.putNext(data.path)
                subscriber.putCompletion()
            })
            return ActionDisposable {
                fetchDisposable.dispose()
                dataDisposable.dispose()
            }
        }
    }
}
