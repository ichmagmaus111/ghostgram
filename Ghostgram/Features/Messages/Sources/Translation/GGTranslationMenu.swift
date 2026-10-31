import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import TranslateUI
import GGCore
import GGHooks
import GGSettingsUI
import GGFeaturesShared

/// The service choice of the «Перевод» tab. Google is a third-party service: before it is used the
/// user sees what is sent where and confirms; declining keeps Telegram. A Google choice migrated
/// from the old client asks once at launch (nothing goes to Google until then).
enum GGTranslationMenu {
    static func register() {
        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGTranslationMenu.askMigratedConsentIfNeeded(context: context)
        })
    }

    static func serviceTitle(_ kind: GGTranslationServiceKind) -> String {
        switch kind {
        case .telegram:
            return GGStrings.Translation.Menu.serviceTelegram
        case .google:
            return GGStrings.Translation.Menu.serviceGoogle
        case .system:
            return GGStrings.Translation.Menu.serviceSystem
        }
    }

    static func chooseService(menuContext: GGMenuContext) {
        let context = menuContext.context
        ggPresentActionSheet(context: context, title: GGStrings.Translation.Menu.service, actions: [
            (GGTranslationMenu.serviceTitle(.telegram), false, {
                GGMessagesSettings.translationService.set(GGTranslationServiceKind.telegram.rawValue)
            }),
            (GGTranslationMenu.serviceTitle(.google), false, {
                GGTranslationMenu.confirmGoogle(context: context, present: { menuContext.present($0) })
            }),
            (GGTranslationMenu.serviceTitle(.system), false, {
                if #available(iOS 18.0, *) {
                    GGMessagesSettings.translationService.set(GGTranslationServiceKind.system.rawValue)
                } else {
                    menuContext.presentToast(GGStrings.Translation.systemUnavailable)
                }
            })
        ], present: { menuContext.present($0) })
    }

    static func confirmGoogle(context: AccountContext, present: @escaping (ViewController) -> Void) {
        if GGMessagesSettings.translationThirdPartyAccepted.value {
            GGMessagesSettings.translationService.set(GGTranslationServiceKind.google.rawValue)
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        present(textAlertController(context: context, title: GGStrings.Translation.Consent.title, text: GGStrings.Translation.Consent.text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: GGStrings.Translation.Consent.accept, action: {
                GGMessagesSettings.translationThirdPartyAccepted.set(true)
                GGMessagesSettings.translationService.set(GGTranslationServiceKind.google.rawValue)
            })
        ]))
    }

    private static var askedMigratedConsent = false

    private static func askMigratedConsentIfNeeded(context: AccountContext) {
        if GGTranslationMenu.askedMigratedConsent {
            return
        }
        GGTranslationMenu.askedMigratedConsent = true
        guard GGMessagesSettings.translationService.value == GGTranslationServiceKind.google.rawValue, !GGMessagesSettings.translationThirdPartyAccepted.value else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let alert = textAlertController(context: context, title: GGStrings.Translation.Consent.title, text: GGStrings.Translation.Consent.text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                GGMessagesSettings.translationService.set(GGTranslationServiceKind.telegram.rawValue)
            }),
            TextAlertAction(type: .defaultAction, title: GGStrings.Translation.Consent.accept, action: {
                GGMessagesSettings.translationThirdPartyAccepted.set(true)
            })
        ])
        context.sharedContext.mainWindow?.present(alert, on: .root)
    }

    /// Languages for «Язык отправки»: popular first, then every supported one, named in the
    /// language of the interface.
    static func languageOptions() -> [GGMenuChoiceOption] {
        var codes: [String] = []
        var seen = Set<String>()
        for code in popularTranslationLanguages + supportedTranslationLanguages where seen.insert(code).inserted {
            codes.append(code)
        }
        return codes.map { code in
            return GGMenuChoiceOption(value: code, title: {
                return GGTranslationMenu.languageName(code)
            })
        }
    }

    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: GGLocalization.shared.languageCode)
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
