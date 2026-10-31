import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import ItemListUI
import TranslateUI
import GGCore
import GGSettingsUI
import GGFeaturesShared

/// Menu rows of the zone (PLAN §2.2): «Сообщения» › «Обходы ограничений», «Отправка», «Перевод»,
/// «Меню и жесты» and the «Чаты» / «Уведомления» sections of the category screen.
/// Order is sparse (step 100); titles are evaluated at display time.
enum GGMessagesMenu {
    static let rulesTab = GGMenuTabID("sending.rules")
    static let keywordsTab = GGMenuTabID("chats.keywords")
    static let localCreatorTab = GGMenuTabID("chats.localCreator")
    static let exceptionsTab = GGMenuTabID("notifications.exceptions")

    static let sendingTextSection = GGMenuSectionID("sending.text")
    static let sendingRepliesSection = GGMenuSectionID("sending.replies")
    static let sendingInputSection = GGMenuSectionID("sending.input")
    static let translationServiceSection = GGMenuSectionID("translation.service")
    static let gesturesSection = GGMenuSectionID("gestures.main")
    static let notificationsSection = GGMenuSectionID("notifications.main")

    static func register() {
        GGMessagesMenu.registerRestrictions()
        GGMessagesMenu.registerSending()
        GGMessagesMenu.registerTranslation()
        GGMessagesMenu.registerMenuAndGestures()
        GGMessagesMenu.registerChats()
        GGMessagesMenu.registerNotifications()
    }

    private static func toggle(_ id: String, section: GGMenuSectionID, order: Int, setting: GGSetting<Bool>, title: @escaping () -> String, subtitle: (() -> String)? = nil, isVisible: ((GGMenuContext) -> Bool)? = nil, keywords: @escaping () -> [String] = { [] }) -> GGMenuRow {
        return GGMenuRow(id: id, section: section, order: order, title: title, subtitle: subtitle, kind: .toggle(.global(setting)), isVisible: isVisible, searchKeywords: keywords)
    }

    // MARK: Restrictions

    private static func registerRestrictions() {
        let section = GGMenuSectionID.main(of: .messagesRestrictions)
        GGMenuRegistry.register(toggle("restrictions.copyProtection", section: section, order: 100, setting: GGMessagesSettings.copyProtectionBypass, title: { GGStrings.Restrictions.Menu.copyProtection }, subtitle: { GGStrings.Restrictions.Menu.copyProtectionInfo }, keywords: { [GGStrings.Restrictions.Menu.keywordForward] }))
        GGMenuRegistry.register(toggle("restrictions.forwardAttribution", section: section, order: 200, setting: GGMessagesSettings.forwardAttribution, title: { GGStrings.Restrictions.Menu.forwardAttribution }, subtitle: { GGStrings.Restrictions.Menu.forwardAttributionInfo }, isVisible: { _ in GGMessagesSettings.copyProtectionBypass.value }))
        GGMenuRegistry.register(toggle("restrictions.keepSelfDestructing", section: section, order: 300, setting: GGMessagesSettings.keepSelfDestructingMedia, title: { GGStrings.Restrictions.Menu.keepSelfDestructing }, subtitle: { GGStrings.Restrictions.Menu.keepSelfDestructingInfo }, keywords: { [GGStrings.Restrictions.Menu.keywordViewOnce] }))
        GGMenuRegistry.register(toggle("restrictions.screenshots", section: section, order: 400, setting: GGMessagesSettings.screenshotBypass, title: { GGStrings.Restrictions.Menu.screenshots }, subtitle: { GGStrings.Restrictions.Menu.screenshotsInfo }, keywords: { [GGStrings.Restrictions.Menu.keywordScreenshot] }))
        GGMenuRegistry.register(toggle("restrictions.blockAds", section: section, order: 500, setting: GGMessagesSettings.blockAds, title: { GGStrings.Restrictions.Menu.blockAds }, subtitle: { GGStrings.Restrictions.Menu.blockAdsInfo }))
        GGMenuRegistry.register(toggle("restrictions.contentRestrictions", section: section, order: 600, setting: GGMessagesSettings.contentRestrictionsBypass, title: { GGStrings.Restrictions.Menu.contentRestrictions }, subtitle: { GGStrings.Restrictions.Menu.contentRestrictionsInfo }))
        GGMenuRegistry.register(toggle("restrictions.revealSpoilers", section: section, order: 700, setting: GGMessagesSettings.revealSpoilers, title: { GGStrings.Restrictions.Menu.revealSpoilers }, subtitle: { GGStrings.Restrictions.Menu.revealSpoilersInfo }))
    }

    // MARK: Sending

    private static func registerSending() {
        let screen = GGMenuScreenID.tab(.messagesSending)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGMessagesMenu.sendingTextSection, screen: screen, order: 300, header: { GGStrings.Sending.Menu.textHeader }, footer: { _ in GGStrings.Sending.Menu.textFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGMessagesMenu.sendingRepliesSection, screen: screen, order: 400, header: { GGStrings.Sending.Menu.repliesHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGMessagesMenu.sendingInputSection, screen: screen, order: 500, header: { GGStrings.Sending.Menu.inputHeader }))

        GGMenuRegistry.register(GGMenuRow(id: "sending.preview", section: .preview(of: .messagesSending), order: 100, title: { "" }, kind: .preview(.miniChat(GGMiniChatConfiguration(scope: "sending", height: 150.0, content: { context in
            return GGSendingPreview.content(context)
        })))))

        let text = GGMessagesMenu.sendingTextSection
        GGMenuRegistry.register(toggle("sending.wordReplacement", section: text, order: 100, setting: GGMessagesSettings.wordReplacement, title: { GGStrings.Sending.Menu.wordReplacement }, subtitle: { GGStrings.Sending.Menu.wordReplacementInfo }, keywords: { [GGStrings.Sending.Menu.keywordText] }))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGMessagesMenu.rulesTab, parent: screen, title: { GGStrings.Sending.Rules.title }, makeScreen: { context in
            return ggMakeReplacementRulesScreen(menuContext: context)
        }))
        GGMenuRegistry.register(GGMenuRow(id: "sending.rules", section: text, order: 200, title: { GGStrings.Sending.Menu.rules }, kind: .tab(GGMessagesMenu.rulesTab), isVisible: { _ in GGMessagesSettings.wordReplacement.value }, label: { _ in
            return GGStrings.Sending.Menu.rulesCount(count: GGOutgoingPipeline.replacementRules.value.count)
        }))
        GGMenuRegistry.register(toggle("sending.antiCaps", section: text, order: 300, setting: GGMessagesSettings.antiCaps, title: { GGStrings.Sending.Menu.antiCaps }, subtitle: { GGStrings.Sending.Menu.antiCapsInfo }))
        GGMenuRegistry.register(toggle("sending.hyperlink", section: text, order: 600, setting: GGMessagesSettings.hyperlinkSpoof, title: { GGStrings.Sending.Menu.hyperlink }, subtitle: { GGStrings.Sending.Menu.hyperlinkInfo }))
        GGMenuRegistry.register(GGMenuRow(id: "sending.hyperlinkTarget", section: text, order: 700, title: { GGStrings.Sending.Menu.hyperlinkTarget }, kind: .action({ context in
            GGHyperlinkTarget.edit(menuContext: context)
        }), isVisible: { _ in GGMessagesSettings.hyperlinkSpoof.value }, label: { context in
            return GGHyperlinkTarget.label(menuContext: context)
        }))

        let replies = GGMessagesMenu.sendingRepliesSection
        GGMenuRegistry.register(toggle("sending.autoQuote", section: replies, order: 100, setting: GGMessagesSettings.autoQuoteReply, title: { GGStrings.Sending.Menu.autoQuote }, subtitle: { GGStrings.Sending.Menu.autoQuoteInfo }))
        GGMenuRegistry.register(toggle("sending.autoQuoteSkipComments", section: replies, order: 200, setting: GGMessagesSettings.autoQuoteSkipComments, title: { GGStrings.Sending.Menu.autoQuoteSkipComments }, isVisible: { _ in GGMessagesSettings.autoQuoteReply.value }))
        GGMenuRegistry.register(toggle("sending.anonymousStickers", section: replies, order: 300, setting: GGMessagesSettings.anonymousStickers, title: { GGStrings.Sending.Menu.anonymousStickers }, subtitle: { GGStrings.Sending.Menu.anonymousStickersInfo }))
        GGMenuRegistry.register(toggle("sending.withoutVia", section: replies, order: 400, setting: GGMessagesSettings.sendWithoutViaBot, title: { GGStrings.Sending.Menu.withoutVia }, subtitle: { GGStrings.Sending.Menu.withoutViaInfo }))
        GGMenuRegistry.register(toggle("sending.keepCaption", section: replies, order: 500, setting: GGMessagesSettings.keepInlineBotCaption, title: { GGStrings.Sending.Menu.keepCaption }, isVisible: { _ in GGMessagesSettings.sendWithoutViaBot.value }))

        let input = GGMessagesMenu.sendingInputSection
        GGMenuRegistry.register(toggle("sending.sendOnReturn", section: input, order: 100, setting: GGMessagesSettings.sendOnReturn, title: { GGStrings.Sending.Menu.sendOnReturn }, subtitle: { GGStrings.Sending.Menu.sendOnReturnInfo }))
        GGMenuRegistry.register(toggle("sending.hideSendAs", section: input, order: 200, setting: GGMessagesSettings.hideSendAsButton, title: { GGStrings.Sending.Menu.hideSendAs }))
    }

    // MARK: Translation

    private static func registerTranslation() {
        let screen = GGMenuScreenID.tab(.messagesTranslation)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGMessagesMenu.translationServiceSection, screen: screen, order: 300, footer: { _ in GGStrings.Translation.Menu.serviceFooter }))

        // An incoming message in another language shows the quick translate button (when it is on),
        // the outgoing one the translation before sending.
        GGMenuRegistry.register(GGMenuRow(id: "translation.preview", section: .preview(of: .messagesTranslation), order: 100, title: { "" }, kind: .preview(.miniChat(GGMiniChatConfiguration(scope: "translation", height: 200.0, content: { _ in
            return GGMiniChatContent(header: nil, messages: [
                GGPreviewMessage(id: 1, isOutgoing: false, text: GGStrings.Translation.Preview.incoming, ageSeconds: 120),
                GGPreviewMessage(id: 2, isOutgoing: true, text: GGStrings.Translation.Preview.result, reply: GGPreviewReply(author: GGStrings.Translation.Preview.input, text: GGStrings.Translation.Preview.source), ageSeconds: 60)
            ])
        })))))

        GGMenuRegistry.register(GGMenuRow(id: "translation.service", section: GGMessagesMenu.translationServiceSection, order: 100, title: { GGStrings.Translation.Menu.service }, kind: .action({ context in
            GGTranslationMenu.chooseService(menuContext: context)
        }), searchKeywords: { [GGStrings.Translation.Menu.keyword] }, label: { _ in
            return GGTranslationMenu.serviceTitle(GGTranslationServiceKind(rawValue: GGMessagesSettings.translationService.value) ?? .telegram)
        }))

        let main = GGMenuSectionID.main(of: .messagesTranslation)
        GGMenuRegistry.register(toggle("translation.quickButton", section: main, order: 100, setting: GGMessagesSettings.quickTranslateButton, title: { GGStrings.Translation.Menu.quickButton }, subtitle: { GGStrings.Translation.Menu.quickButtonInfo }))
        GGMenuRegistry.register(toggle("translation.beforeSending", section: main, order: 200, setting: GGMessagesSettings.translateBeforeSending, title: { GGStrings.Translation.Menu.beforeSending }, subtitle: { GGStrings.Translation.Menu.beforeSendingInfo }))
        GGMenuRegistry.register(GGMenuRow(id: "translation.beforeSendingLanguage", section: main, order: 300, title: { GGStrings.Translation.Menu.beforeSendingLanguage }, kind: .choice(.global(GGMessagesSettings.translateBeforeSendingLanguage), options: GGTranslationMenu.languageOptions()), isVisible: { _ in GGMessagesSettings.translateBeforeSending.value }))
        GGMenuRegistry.register(toggle("translation.photo", section: main, order: 400, setting: GGMessagesSettings.photoTranslation, title: { GGStrings.Translation.Menu.photo }, subtitle: { GGStrings.Translation.Menu.photoInfo }))
        GGMenuRegistry.register(GGMenuRow(id: "translation.telegramSettings", section: main, order: 500, title: { GGStrings.Translation.Menu.telegramSettings }, subtitle: { GGStrings.Translation.Menu.telegramSettingsInfo }, kind: .action({ context in
            if let make = GGSettingsUIEnvironment.shared.makeTelegramLanguageController {
                context.push(make(context.context))
            }
        }), isVisible: { _ in GGSettingsUIEnvironment.shared.makeTelegramLanguageController != nil }))
    }

    // MARK: Menu and gestures

    private static func registerMenuAndGestures() {
        let main = GGMenuSectionID.main(of: .messagesMenuGestures)
        let children: [GGMenuRow] = [
            toggle("messageMenu.reply", section: main, order: 100, setting: GGMessagesSettings.menuShowReply, title: { GGStrings.MessageMenu.Menu.reply }),
            toggle("messageMenu.pin", section: main, order: 200, setting: GGMessagesSettings.menuShowPin, title: { GGStrings.MessageMenu.Menu.pin }),
            toggle("messageMenu.report", section: main, order: 300, setting: GGMessagesSettings.menuShowReport, title: { GGStrings.MessageMenu.Menu.report }),
            toggle("messageMenu.saveMedia", section: main, order: 400, setting: GGMessagesSettings.menuShowSaveMedia, title: { GGStrings.MessageMenu.Menu.saveMedia }),
            toggle("messageMenu.replies", section: main, order: 500, setting: GGMessagesSettings.menuShowReplies, title: { GGStrings.MessageMenu.Menu.replies }),
            toggle("messageMenu.restrict", section: main, order: 600, setting: GGMessagesSettings.menuShowRestrict, title: { GGStrings.MessageMenu.Menu.restrict }),
            toggle("messageMenu.saveToCloud", section: main, order: 700, setting: GGMessagesSettings.menuSaveToCloud, title: { GGStrings.MessageMenu.Menu.saveToCloud }),
            toggle("messageMenu.forwardWithoutAuthor", section: main, order: 800, setting: GGMessagesSettings.menuForwardWithoutAuthor, title: { GGStrings.MessageMenu.Menu.forwardWithoutAuthor })
        ]
        GGMenuRegistry.register(GGMenuRow(id: "messageMenu.custom", section: main, order: 100, title: { GGStrings.MessageMenu.Menu.custom }, subtitle: { GGStrings.MessageMenu.Menu.customInfo }, kind: .expandableGroup(master: .global(GGMessagesSettings.customMessageMenu), children: children)))

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGMessagesMenu.gesturesSection, screen: .tab(.messagesMenuGestures), order: 300, header: { GGStrings.Gestures.Menu.header }))
        GGMenuRegistry.register(toggle("gestures.doubleTapToEdit", section: GGMessagesMenu.gesturesSection, order: 100, setting: GGMessagesSettings.doubleTapToEdit, title: { GGStrings.Gestures.Menu.doubleTapToEdit }, subtitle: { GGStrings.Gestures.Menu.doubleTapToEditInfo }))
        GGMenuRegistry.register(toggle("gestures.disableVideoPipSwipe", section: GGMessagesMenu.gesturesSection, order: 200, setting: GGMessagesSettings.disableVideoPipSwipe, title: { GGStrings.Gestures.Menu.disableVideoPipSwipe }, subtitle: { GGStrings.Gestures.Menu.disableVideoPipSwipeInfo }))
    }

    // MARK: Chats

    private static func registerChats() {
        let section = GGMenuSectionID.messagesChats
        GGMenuRegistry.register(toggle("chats.unlimitedSearch", section: section, order: 200, setting: GGMessagesSettings.unlimitedSearchHistory, title: { GGStrings.Chats.Menu.unlimitedSearch }, subtitle: { GGStrings.Chats.Menu.unlimitedSearchInfo }))
        GGMenuRegistry.register(toggle("chats.hideGreeting", section: section, order: 300, setting: GGMessagesSettings.hideGreetingSticker, title: { GGStrings.Chats.Menu.hideGreeting }, subtitle: { GGStrings.Chats.Menu.hideGreetingInfo }))
        GGMenuRegistry.register(toggle("chats.keywordFilter", section: section, order: 400, setting: GGMessagesSettings.keywordFilter, title: { GGStrings.Chats.Menu.keywordFilter }, subtitle: { GGStrings.Chats.Menu.keywordFilterInfo }))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGMessagesMenu.keywordsTab, parent: .category(.messages), title: { GGStrings.Chats.Keywords.title }, makeScreen: { context in
            return ggMakeKeywordsScreen(menuContext: context)
        }))
        GGMenuRegistry.register(GGMenuRow(id: "chats.keywords", section: section, order: 500, title: { GGStrings.Chats.Menu.keywords }, kind: .tab(GGMessagesMenu.keywordsTab), isVisible: { _ in GGMessagesSettings.keywordFilter.value }, label: { _ in
            return GGStrings.Chats.Menu.keywordsCount(count: GGMessagesSettings.keywords.value.count)
        }))
        GGMenuRegistry.register(toggle("chats.hideChannelButton", section: section, order: 600, setting: GGMessagesSettings.hideChannelBottomButton, title: { GGStrings.Chats.Menu.hideChannelButton }, subtitle: { GGStrings.Chats.Menu.hideChannelButtonInfo }))
        // One switch for channels and forum topics (2026-10-27).
        GGMenuRegistry.register(toggle("chats.noNext", section: section, order: 700, setting: GGMessagesSettings.disableScrollToNext, title: { GGStrings.Chats.Menu.noNext }, subtitle: { GGStrings.Chats.Menu.noNextInfo }))
        GGMenuRegistry.register(toggle("chats.noDeleteEffect", section: section, order: 900, setting: GGMessagesSettings.disableDeleteEffect, title: { GGStrings.Chats.Menu.noDeleteEffect }, subtitle: { GGStrings.Chats.Menu.noDeleteEffectInfo }))
        GGMenuRegistry.register(toggle("chats.hideRecordButton", section: section, order: 1000, setting: GGMessagesSettings.hideRecordButton, title: { GGStrings.Chats.Menu.hideRecordButton }, subtitle: { GGStrings.Chats.Menu.hideRecordButtonInfo }))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGMessagesMenu.localCreatorTab, parent: .category(.messages), title: { GGStrings.Chats.LocalCreator.title }, makeScreen: { context in
            return ggMakeLocalCreatorScreen(menuContext: context)
        }))
        GGMenuRegistry.register(GGMenuRow(id: "chats.localCreator", section: section, order: 1100, title: { GGStrings.Chats.Menu.localCreator }, subtitle: { GGStrings.Chats.Menu.localCreatorInfo }, kind: .tab(GGMessagesMenu.localCreatorTab), label: { context in
            return GGStrings.Chats.Menu.localCreatorCount(count: GGMessagesSettings.localCreatorChannels.value(for: context.accountID).count)
        }))
        // «Безлимитные закрепы» have no switch (always on, owner's decision 2026-10-22). The section
        // ends with what the user has to know about them: where they work and that the pins beyond
        // Telegram's limit stay on this device. Found by search as «закрепы».
        GGMenuRegistry.register(GGMenuRow(id: "chats.unlimitedPins", section: section, order: 10000, title: { GGStrings.Chats.Menu.unlimitedPins }, subtitle: { GGStrings.Chats.Menu.unlimitedPinsInfo }, kind: .custom({ context in
            return ItemListTextItem(presentationData: context.itemListPresentationData, text: .plain(GGStrings.Chats.Menu.unlimitedPinsInfo), sectionId: context.sectionId)
        }), searchKeywords: { [GGStrings.Chats.Menu.keywordPins] }))
    }

    // MARK: Notifications

    private static func registerNotifications() {
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGMessagesMenu.notificationsSection, screen: .category(.messages), order: 400, header: { GGStrings.Notifications.Menu.header }, footer: { _ in GGStrings.Notifications.Menu.footer }))
        let options = [
            GGMenuChoiceOption(value: GGNotificationDeliveryMode.standard.rawValue, title: { GGStrings.Notifications.Menu.modeStandard }),
            GGMenuChoiceOption(value: GGNotificationDeliveryMode.silent.rawValue, title: { GGStrings.Notifications.Menu.modeSilent }),
            GGMenuChoiceOption(value: GGNotificationDeliveryMode.disabled.rawValue, title: { GGStrings.Notifications.Menu.modeDisabled })
        ]
        let section = GGMessagesMenu.notificationsSection
        GGMenuRegistry.register(GGMenuRow(id: "notifications.pinned", section: section, order: 100, title: { GGStrings.Notifications.Menu.pinned }, kind: .choice(.global(GGMessagesSettings.pinnedNotifications), options: options)))
        GGMenuRegistry.register(GGMenuRow(id: "notifications.mentions", section: section, order: 200, title: { GGStrings.Notifications.Menu.mentions }, kind: .choice(.global(GGMessagesSettings.mentionNotifications), options: options)))
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: GGMessagesMenu.exceptionsTab, parent: .category(.messages), title: { GGStrings.Notifications.Exceptions.title }, makeScreen: { context in
            return ggMakeNotificationExceptionsScreen(menuContext: context)
        }))
        GGMenuRegistry.register(GGMenuRow(id: "notifications.exceptions", section: section, order: 300, title: { GGStrings.Notifications.Menu.exceptions }, kind: .tab(GGMessagesMenu.exceptionsTab), label: { context in
            return GGStrings.Notifications.Menu.exceptionsCount(count: GGNotificationExceptions.peerKeys(accountId: context.accountID).count)
        }))
    }
}

/// «было → станет» on a real bubble: the sample text run through the enabled stages.
enum GGSendingPreview {
    static func content(_ context: GGMenuContext) -> GGMiniChatContent {
        let sample = GGStrings.Sending.Preview.sample
        let configuration = GGOutgoingPipeline.configuration(accountId: context.accountID)
        let pipelineContext = GGTextPipelineContext(isBot: false, isSavedMessages: false, isVerbatim: false)
        let result = GGOutgoingPipeline.run(GGOutgoingText(text: sample, entities: []), configuration: configuration, context: pipelineContext, hyperlinkTarget: nil)
        return GGMiniChatContent(header: nil, messages: [
            GGPreviewMessage(id: 1, isOutgoing: true, text: result.text, reply: GGPreviewReply(author: GGStrings.Sending.Preview.before, text: sample), ageSeconds: 60)
        ])
    }
}
