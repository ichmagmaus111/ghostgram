import Foundation
import GGCore

// Settings of the Swiftgram-parity features (W5-SG). Declared in the light shared module because the
// upstream modules below the feature layer read them in their GHOST call sites (GGExtrasPolicy) and
// the notification service reads `hideAccountInNotifications`. Off = upstream behaviour.
// Defaults follow Swiftgram (owner's decision 2026-10-29, W6-SGD): what Swiftgram does always (or by a
// server flag that is on by default: `ytPip`, `qrLogin`) is on here too, the switch stays; what Swiftgram
// keeps off (`forceSystemSharing`, `hideAccountInNotifications`, the «В историю» tile shown) stays off.
public enum GGExtrasSettings {
    // MARK: Сообщения › Уведомления
    /// 4 h, 8 h and 1 day in the profile's «Уведомления» sheet, besides 1 h and 2 days.
    public static let extraMuteDurations = GGSetting<Bool>("extras.extraMuteDurations", default: true)
    /// A push never names the account it was delivered to, even with several accounts.
    public static let hideAccountInNotifications = GGSetting<Bool>("extras.hideAccountInNotifications", default: false, scope: .appGroup, flags: [.extensions])

    // MARK: Сообщения › Чаты
    /// An in-chat search the server found nothing for looks for the text inside words of the
    /// messages already on this device.
    public static let searchPartialWords = GGSetting<Bool>("extras.searchPartialWords", default: true)

    // MARK: Отправка › Ввод
    /// A long press on a mention suggestion inserts it followed by « @», so the next list opens.
    public static let mentionChain = GGSetting<Bool>("extras.mentionChain", default: true)
    /// No «Удерживайте, чтобы записать» tooltip after a tap on the microphone / camera button.
    public static let noRecordTooltip = GGSetting<Bool>("extras.noRecordTooltip", default: true)

    // MARK: Меню и жесты › Ссылки и «Поделиться»
    /// A tap on the picture of a link preview opens the picture, not the link.
    public static let linkPreviewOpensMedia = GGSetting<Bool>("extras.linkPreviewOpensMedia", default: true)
    /// «Переслать» and «Поделиться» in the menu of a long-pressed link.
    public static let linkMenuShare = GGSetting<Bool>("extras.linkMenuShare", default: true)
    /// Links in the description of a profile are tappable without Premium.
    public static let bioLinks = GGSetting<Bool>("extras.bioLinks", default: true)
    /// «Safari в приложении» and «Системный браузер» in Telegram's «Браузер» settings.
    public static let moreBrowsers = GGSetting<Bool>("extras.moreBrowsers", default: true)
    /// Every «Поделиться» opens the iOS share sheet at once (where the content may leave the app).
    public static let systemShareSheet = GGSetting<Bool>("extras.systemShareSheet", default: false)
    /// No «В историю» tile in the share sheet.
    public static let hideRepostToStory = GGSetting<Bool>("extras.hideRepostToStory", default: false)

    // MARK: Меню и жесты › Меню и выделение
    // «Данные сообщения (JSON)» was removed (owner, 2026-10-29); its stored value goes
    // (`extras.messageJson.removed.v1`).
    /// «В Избранное» and «Переслать без автора» on the selection panel.
    public static let selectionPanelButtons = GGSetting<Bool>("extras.selectionPanelButtons", default: true)

    // MARK: Сообщения › Группы и каналы
    /// «Администраторы» and «Подписчики» for every admin of a channel, «Администраторы» and
    /// «Участники» for every admin of a group (Telegram asks for the right to ban).
    public static let adminListsForAllAdmins = GGSetting<Bool>("extras.adminListsForAllAdmins", default: true)
    /// «Недавние действия» in a channel's profile and in the «…» menu of groups and channels.
    public static let recentActionsShortcut = GGSetting<Bool>("extras.recentActionsShortcut", default: true)
    /// «Администраторы» in the «…» menu of every group, for every member.
    public static let administratorsMenuItem = GGSetting<Bool>("extras.administratorsMenuItem", default: true)
    /// «Показать закреп» in the «…» menu: brings back a pinned message bar that was closed.
    public static let hiddenPinnedMenuItem = GGSetting<Bool>("extras.hiddenPinnedMenuItem", default: true)
    /// A custom restriction («Ограничить до…») picks a date and a time, not just a day.
    public static let restrictUntilTime = GGSetting<Bool>("extras.restrictUntilTime", default: true)
    /// The text of a restricted chat or message ends with its code («porn-ios»).
    public static let restrictionReasonCode = GGSetting<Bool>("extras.restrictionReasonCode", default: true)
    /// «Обсуждение» in the header of a channel with direct messages, next to «Сообщение» (upstream
    /// shows only «Сообщение» there).
    public static let discussionButton = GGSetting<Bool>("extras.discussionButton", default: true)

    // MARK: Оформление
    /// «Архивировать» / «Вернуть из архива» in the menu of a long-pressed chat.
    public static let archiveInChatMenu = GGSetting<Bool>("extras.archiveInChatMenu", default: true)
    /// No Premium offers (gift, upgrade, annual price) above the chat list.
    public static let hidePremiumOffers = GGSetting<Bool>("extras.hidePremiumOffers", default: true)
    /// Community translations of Telegram (Chinese variants, Japanese, Vietnamese, Hindi, Armenian)
    /// in the language list.
    public static let extraLanguages = GGSetting<Bool>("extras.extraLanguages", default: true)

    // MARK: Медиа › Загрузки и качество
    /// YouTube videos may go to picture-in-picture even when the server turns it off.
    public static let youTubePictureInPicture = GGSetting<Bool>("extras.youTubePictureInPicture", default: true)
    /// 1 GB cache limit and «1 час» for keeping media.
    public static let extraCacheOptions = GGSetting<Bool>("extras.extraCacheOptions", default: true)

    // MARK: Безопасность
    /// «Через 5 секунд» in the passcode auto-lock menu.
    public static let autolockFiveSeconds = GGSetting<Bool>("extras.autolockFiveSeconds", default: true)
    /// IP address and api_id in the details of a session.
    public static let sessionDetails = GGSetting<Bool>("extras.sessionDetails", default: true)
    /// «Подключить устройство» (QR login) even where the server hides it.
    public static let qrLoginAlways = GGSetting<Bool>("extras.qrLoginAlways", default: true)
    /// The alert about a session ended by the server names the likely reasons.
    public static let logoutReason = GGSetting<Bool>("extras.logoutReason", default: true)
    /// «Добавить аккаунт» in Settings with a single account too (upstream shows it from two).
    public static let addAccountRow = GGSetting<Bool>("extras.addAccountRow", default: true)

    static func declare() {
        let _ = GGExtrasSettings.extraMuteDurations
        let _ = GGExtrasSettings.hideAccountInNotifications
        let _ = GGExtrasSettings.searchPartialWords
        let _ = GGExtrasSettings.mentionChain
        let _ = GGExtrasSettings.noRecordTooltip
        let _ = GGExtrasSettings.linkPreviewOpensMedia
        let _ = GGExtrasSettings.linkMenuShare
        let _ = GGExtrasSettings.bioLinks
        let _ = GGExtrasSettings.moreBrowsers
        let _ = GGExtrasSettings.systemShareSheet
        let _ = GGExtrasSettings.hideRepostToStory
        let _ = GGExtrasSettings.selectionPanelButtons
        let _ = GGExtrasSettings.adminListsForAllAdmins
        let _ = GGExtrasSettings.recentActionsShortcut
        let _ = GGExtrasSettings.administratorsMenuItem
        let _ = GGExtrasSettings.hiddenPinnedMenuItem
        let _ = GGExtrasSettings.restrictUntilTime
        let _ = GGExtrasSettings.restrictionReasonCode
        let _ = GGExtrasSettings.archiveInChatMenu
        let _ = GGExtrasSettings.hidePremiumOffers
        let _ = GGExtrasSettings.extraLanguages
        let _ = GGExtrasSettings.youTubePictureInPicture
        let _ = GGExtrasSettings.extraCacheOptions
        let _ = GGExtrasSettings.autolockFiveSeconds
        let _ = GGExtrasSettings.sessionDetails
        let _ = GGExtrasSettings.qrLoginAlways
        let _ = GGExtrasSettings.logoutReason
        let _ = GGExtrasSettings.discussionButton
        let _ = GGExtrasSettings.addAccountRow
    }
}
