import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore
import GGHooks
import GGFeaturesShared

/// Answers Telegram's translation requests with the chosen service. Telegram (the default) answers
/// nil: upstream does the request. Google is used only after the user accepted the notice
/// (`GGMessagesPolicy.translationService`); system translation only on iOS 18+.
enum GGTranslationProviders {
    static func register() {
        GGTranslationHooks.translateTexts.register({ request in
            let service = GGMessagesPolicy.translationService
            if service == .telegram {
                return nil
            }
            return GGTranslationEngine.translate(request.texts, toLang: request.toLang, service: service)
        })
        GGTranslationHooks.translateMessages.register({ request in
            let service = GGMessagesPolicy.translationService
            if service == .telegram {
                return nil
            }
            return GGTranslationProviders.translateMessages(request, service: service)
        })
    }

    /// Like upstream: translates the stored messages and keeps the result in
    /// `TranslationMessageAttribute` (text, poll options and solution, voice transcription), through
    /// `GGStoredMessagesTranslation` (GGFeaturesShared), which the chat translation without Premium
    /// shares. Rich messages (an InstantPage body) are left to Telegram: `ggTranslateMessages`
    /// (GGHooks) sends them to Telegram's translation next to this one.
    static func translateMessages(_ request: GGMessagesTranslationRequest, service: GGTranslationServiceKind) -> Signal<Void, TranslationError> {
        let toLang = request.toLang
        return GGStoredMessagesTranslation.translate(postbox: request.account.postbox, messageIds: request.messageIds, toLang: toLang, translateTexts: { texts in
            return GGTranslationEngine.translate(texts, toLang: toLang, service: service)
        })
    }
}
