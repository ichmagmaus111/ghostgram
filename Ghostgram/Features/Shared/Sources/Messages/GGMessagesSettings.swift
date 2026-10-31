import Foundation
import GGCore

// Settings of the «Сообщения» zone (W2-3). Declared here, in the light shared module, because
// upstream modules below the feature layer (TranslateUI, ChatPresentationInterfaceState, the chat
// nodes, TelegramUI) and the notification service read some of them. Each is declared once.
// Toggles default to off; `messageMenu.*` children only matter while their master is on.

public enum GGTranslationServiceKind: String {
    case telegram
    case google
    case system
}

public enum GGNotificationDeliveryMode: String {
    case standard = "default"
    case silent
    case disabled
}

public enum GGMessagesSettings {
    // MARK: Restrictions («Обходы ограничений»)
    public static let copyProtectionBypass = GGSetting<Bool>("restrictions.copyProtectionBypass", default: false)
    public static let forwardAttribution = GGSetting<Bool>("restrictions.forwardAttribution", default: false)
    public static let keepSelfDestructingMedia = GGSetting<Bool>("restrictions.keepSelfDestructingMedia", default: false)
    public static let screenshotBypass = GGSetting<Bool>("restrictions.screenshotBypass", default: false)
    public static let blockAds = GGSetting<Bool>("restrictions.blockAds", default: false)
    public static let contentRestrictionsBypass = GGSetting<Bool>("restrictions.contentRestrictionsBypass", default: false)
    public static let revealSpoilers = GGSetting<Bool>("restrictions.revealSpoilers", default: false)

    // MARK: Sending («Отправка»)
    public static let wordReplacement = GGSetting<Bool>("sending.wordReplacement", default: false)
    public static let antiCaps = GGSetting<Bool>("sending.antiCaps", default: false)
    public static let hyperlinkSpoof = GGSetting<Bool>("sending.hyperlinkSpoof", default: false)
    /// The profile every outgoing text links to; per account (a peer of that account).
    public static let hyperlinkTarget = GGAccountSetting<GGPeerKey?>("sending.hyperlinkTarget", default: nil)
    public static let autoQuoteReply = GGSetting<Bool>("sending.autoQuoteReply", default: false)
    /// Sub-option of the quote: comments under channel posts are answered without a quote.
    public static let autoQuoteSkipComments = GGSetting<Bool>("sending.autoQuoteSkipComments", default: true)
    public static let anonymousStickers = GGSetting<Bool>("sending.anonymousStickers", default: false)
    public static let sendWithoutViaBot = GGSetting<Bool>("sending.sendWithoutViaBot", default: false)
    /// Sub-option: keep the bot's caption when the result is re-sent as a normal message.
    public static let keepInlineBotCaption = GGSetting<Bool>("sending.keepInlineBotCaption", default: true)
    public static let sendOnReturn = GGSetting<Bool>("sending.sendOnReturn", default: false)
    public static let hideSendAsButton = GGSetting<Bool>("sending.hideSendAsButton", default: false)

    // MARK: Translation («Перевод»)
    public static let translationService = GGSetting<String>("translation.service", default: GGTranslationServiceKind.telegram.rawValue)
    /// The user saw and accepted the notice that texts go to a third-party service.
    public static let translationThirdPartyAccepted = GGSetting<Bool>("translation.thirdPartyAccepted", default: false, flags: [.noExport])
    public static let quickTranslateButton = GGSetting<Bool>("translation.quickButton", default: false)
    public static let translateBeforeSending = GGSetting<Bool>("translation.beforeSending", default: false)
    public static let translateBeforeSendingLanguage = GGSetting<String>("translation.beforeSendingLanguage", default: "en")
    /// Outgoing language per chat (peer key → language code); per account.
    public static let outgoingLanguages = GGAccountSetting<[String: String]>("translation.outgoingLanguages", default: [:])
    public static let photoTranslation = GGSetting<Bool>("translation.photo", default: false)

    // MARK: Message menu and gestures («Меню и жесты»)
    // Defaults follow Swiftgram (W6-SGD, owner's decision 2026-10-29): its menu always has «В Избранное»,
    // «Без автора» and «Ограничить» (`contextShow…` = true), so the custom menu and these items are on;
    // Telegram's own items stay shown. Turned-off items are hidden — no «Ghostgram» submenu, and no
    // «Выбрать от автора» (both removed by the owner, 2026-10-29).
    public static let customMessageMenu = GGSetting<Bool>("messageMenu.custom", default: true)
    public static let menuShowReply = GGSetting<Bool>("messageMenu.reply", default: true)
    public static let menuShowPin = GGSetting<Bool>("messageMenu.pin", default: true)
    public static let menuShowReport = GGSetting<Bool>("messageMenu.report", default: true)
    public static let menuShowRestrict = GGSetting<Bool>("messageMenu.restrict", default: true)
    public static let menuShowSaveMedia = GGSetting<Bool>("messageMenu.saveMedia", default: true)
    public static let menuShowReplies = GGSetting<Bool>("messageMenu.replies", default: true)
    public static let menuSaveToCloud = GGSetting<Bool>("messageMenu.saveToCloud", default: true)
    public static let menuForwardWithoutAuthor = GGSetting<Bool>("messageMenu.forwardWithoutAuthor", default: true)
    public static let doubleTapToEdit = GGSetting<Bool>("gestures.doubleTapToEdit", default: false)
    public static let disableVideoPipSwipe = GGSetting<Bool>("gestures.disableVideoPipSwipe", default: false)

    // MARK: Chats («Чаты»)
    // «Безлимитные закрепы» have no setting: always on (owner's decision 2026-10-22); their per-account
    // state lives in the account's Postbox (GGMessages, `GGPinnedTailStore`).
    public static let unlimitedSearchHistory = GGSetting<Bool>("chats.unlimitedSearchHistory", default: false)
    public static let hideGreetingSticker = GGSetting<Bool>("chats.hideGreetingSticker", default: false)
    public static let keywordFilter = GGSetting<Bool>("chats.keywordFilter", default: false)
    public static let keywords = GGSetting<[String]>("chats.keywords", default: [])
    public static let hideChannelBottomButton = GGSetting<Bool>("chats.hideChannelBottomButton", default: false)
    /// «Без перехода к следующему каналу и теме»: one switch since 2026-10-27 (was one per channel / topic).
    public static let disableScrollToNext = GGSetting<Bool>("chats.disableScrollToNext", default: false)
    public static let disableDeleteEffect = GGSetting<Bool>("chats.disableDeleteEffect", default: false)
    public static let hideRecordButton = GGSetting<Bool>("chats.hideRecordButton", default: false)
    /// Channels shown as if the user created them («локальный режим»); per account.
    public static let localCreatorChannels = GGAccountSetting<Set<GGPeerKey>>("chats.localCreatorChannels", default: [])

    // MARK: Notifications («Уведомления», read by the notification service)
    public static let pinnedNotifications = GGSetting<String>("notifications.pinned", default: GGNotificationDeliveryMode.standard.rawValue, scope: .appGroup, flags: [.extensions])
    public static let mentionNotifications = GGSetting<String>("notifications.mentions", default: GGNotificationDeliveryMode.standard.rawValue, scope: .appGroup, flags: [.extensions])
    /// Per chat (peer key → mode), per account.
    public static let pinnedNotificationExceptions = GGAccountSetting<[String: String]>("notifications.pinnedExceptions", default: [:], flags: [.extensions])
    public static let mentionNotificationExceptions = GGAccountSetting<[String: String]>("notifications.mentionExceptions", default: [:], flags: [.extensions])

    /// Touches every declaration so the registry knows them before export, search and migrations.
    static func declare() {
        let _ = GGMessagesSettings.copyProtectionBypass
        let _ = GGMessagesSettings.forwardAttribution
        let _ = GGMessagesSettings.keepSelfDestructingMedia
        let _ = GGMessagesSettings.screenshotBypass
        let _ = GGMessagesSettings.blockAds
        let _ = GGMessagesSettings.contentRestrictionsBypass
        let _ = GGMessagesSettings.revealSpoilers
        let _ = GGMessagesSettings.wordReplacement
        let _ = GGMessagesSettings.antiCaps
        let _ = GGMessagesSettings.hyperlinkSpoof
        let _ = GGMessagesSettings.hyperlinkTarget
        let _ = GGMessagesSettings.autoQuoteReply
        let _ = GGMessagesSettings.autoQuoteSkipComments
        let _ = GGMessagesSettings.anonymousStickers
        let _ = GGMessagesSettings.sendWithoutViaBot
        let _ = GGMessagesSettings.keepInlineBotCaption
        let _ = GGMessagesSettings.sendOnReturn
        let _ = GGMessagesSettings.hideSendAsButton
        let _ = GGMessagesSettings.translationService
        let _ = GGMessagesSettings.translationThirdPartyAccepted
        let _ = GGMessagesSettings.quickTranslateButton
        let _ = GGMessagesSettings.translateBeforeSending
        let _ = GGMessagesSettings.translateBeforeSendingLanguage
        let _ = GGMessagesSettings.outgoingLanguages
        let _ = GGMessagesSettings.photoTranslation
        let _ = GGMessagesSettings.customMessageMenu
        let _ = GGMessagesSettings.menuShowReply
        let _ = GGMessagesSettings.menuShowPin
        let _ = GGMessagesSettings.menuShowReport
        let _ = GGMessagesSettings.menuShowRestrict
        let _ = GGMessagesSettings.menuShowSaveMedia
        let _ = GGMessagesSettings.menuShowReplies
        let _ = GGMessagesSettings.menuSaveToCloud
        let _ = GGMessagesSettings.menuForwardWithoutAuthor
        let _ = GGMessagesSettings.doubleTapToEdit
        let _ = GGMessagesSettings.disableVideoPipSwipe
        let _ = GGMessagesSettings.unlimitedSearchHistory
        let _ = GGMessagesSettings.hideGreetingSticker
        let _ = GGMessagesSettings.keywordFilter
        let _ = GGMessagesSettings.keywords
        let _ = GGMessagesSettings.hideChannelBottomButton
        let _ = GGMessagesSettings.disableScrollToNext
        let _ = GGMessagesSettings.disableDeleteEffect
        let _ = GGMessagesSettings.hideRecordButton
        let _ = GGMessagesSettings.localCreatorChannels
        let _ = GGMessagesSettings.pinnedNotifications
        let _ = GGMessagesSettings.mentionNotifications
        let _ = GGMessagesSettings.pinnedNotificationExceptions
        let _ = GGMessagesSettings.mentionNotificationExceptions
    }
}
