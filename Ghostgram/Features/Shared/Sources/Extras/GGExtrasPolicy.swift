import Foundation
import TelegramCore
import GGCore

/// What the upstream GHOST call sites of the Swiftgram-parity features ask (W5-SG). Every answer is
/// a read of a settings snapshot (no disk, no locks); with the setting off it is upstream's value.
public enum GGExtrasPolicy {
    // MARK: Notifications

    /// Extra «Отключить на…» intervals (seconds) for the profile's notification sheet: 4 h, 8 h, 1 day.
    /// Empty when the setting is off.
    public static var extraMuteIntervals: [Int32] {
        if !GGExtrasSettings.extraMuteDurations.value {
            return []
        }
        return [4 * 60 * 60, 8 * 60 * 60, 1 * 24 * 60 * 60]
    }

    /// The notification service never adds «→ account» to a push.
    public static var hidesRecipientAccountInNotifications: Bool {
        return GGExtrasSettings.hideAccountInNotifications.value
    }

    // MARK: Chats and input

    public static var hidesRecordingTooltip: Bool {
        return GGExtrasSettings.noRecordTooltip.value
    }

    public static var showsArchiveInChatMenu: Bool {
        return GGExtrasSettings.archiveInChatMenu.value
    }

    public static var hidesPremiumOffers: Bool {
        return GGExtrasSettings.hidePremiumOffers.value
    }


    // MARK: Links and sharing

    /// A tap on a link preview's picture opens the picture instead of the link.
    public static var linkPreviewOpensMedia: Bool {
        return GGExtrasSettings.linkPreviewOpensMedia.value
    }

    /// Profile descriptions link every URL, not only Telegram's own, without Premium.
    public static var clickableBioLinks: Bool {
        return GGExtrasSettings.bioLinks.value
    }

    /// «Safari в приложении» and the system browser in Telegram's browser settings.
    public static var allowsMoreBrowsers: Bool {
        return GGExtrasSettings.moreBrowsers.value
    }

    /// The identifier Telegram's browser settings store for «Safari в приложении». Upstream already
    /// treats an unknown value as Safari, so a stale value is harmless once the setting is off.
    public static let inAppSafariBrowserIdentifier = "inApp"
    /// The identifier for the system's default browser. Telegram finds no app for it among its
    /// «Открыть в» options and hands the link to iOS, which opens it in the default browser.
    public static let systemBrowserIdentifier = "default"

    /// The share sheet opens the iOS sheet at once. Only where the caller allows sharing outside the
    /// app (`externalShare`), so protected content never leaves through it.
    public static func opensSystemShareSheet(externalShare: Bool) -> Bool {
        return externalShare && GGExtrasSettings.systemShareSheet.value
    }

    public static var hidesRepostToStory: Bool {
        return GGExtrasSettings.hideRepostToStory.value
    }

    // MARK: Message tools

    /// «В Избранное» and «Переслать без автора» on the selection panel.
    public static var showsSelectionPanelButtons: Bool {
        return GGExtrasSettings.selectionPanelButtons.value
    }

    // MARK: Groups and channels

    public static var adminListsForAllAdmins: Bool {
        return GGExtrasSettings.adminListsForAllAdmins.value
    }

    public static var showsDiscussionWithDirectMessages: Bool {
        return GGExtrasSettings.discussionButton.value
    }

    public static var showsRecentActionsInProfile: Bool {
        return GGExtrasSettings.recentActionsShortcut.value
    }

    /// «Ограничить до…» picks a date and a time.
    public static var restrictsUntilTime: Bool {
        return GGExtrasSettings.restrictUntilTime.value
    }

    // MARK: Media

    public static var forcesYouTubePictureInPicture: Bool {
        return GGExtrasSettings.youTubePictureInPicture.value
    }

    /// The cache size limits (gigabytes, `Int32.max` = no limit) with 1 GB in front.
    public static func maximumCacheSizeValues(_ values: [Int32]) -> [Int32] {
        if !GGExtrasSettings.extraCacheOptions.value || values.contains(1) {
            return values
        }
        return [1] + values
    }

    /// The «Хранить медиа» presets (seconds, `Int32.max` = forever) with 1 hour at the end.
    public static func keepMediaPresets(_ values: [Int32]) -> [Int32] {
        let hour: Int32 = 60 * 60
        if !GGExtrasSettings.extraCacheOptions.value || values.contains(hour) {
            return values
        }
        return values + [hour]
    }

    /// The smallest cache limit Telegram's screen may store (it clamps to 5 GB upstream).
    public static var minimumCacheSizeLimit: Int32 {
        return GGExtrasSettings.extraCacheOptions.value ? 1 : 5
    }

    // MARK: Sessions and lock

    /// How often the app lock renews its «last active» mark while the app is in front. With the
    /// 5-second auto-lock the upstream 5 s step would lock on a quick return. Only when that option
    /// is the chosen one: the switch is on by default (W6-SGD), and every other timeout keeps
    /// upstream's 5 s step (each step writes the lock state file).
    public static func appLockActivityRenewInterval(autolockTimeout: Int32?) -> Double {
        if GGExtrasSettings.autolockFiveSeconds.value, let autolockTimeout, autolockTimeout > 0, autolockTimeout <= 5 {
            return 2.5
        }
        return 5.0
    }

    public static var showsSessionDetails: Bool {
        return GGExtrasSettings.sessionDetails.value
    }

    /// «Приложение» of a session, with its api_id when the details are on.
    public static func sessionApplicationString(_ base: String, apiId: Int32, isCurrent: Bool) -> String {
        if isCurrent || !GGExtrasSettings.sessionDetails.value {
            return base
        }
        return base + " · api_id " + String(apiId)
    }

    public static var alwaysShowsAddAccount: Bool {
        return GGExtrasSettings.addAccountRow.value
    }

    public static var alwaysShowsQRLogin: Bool {
        return GGExtrasSettings.qrLoginAlways.value
    }

    /// The text of the alert shown when the server ended this session; with the setting on it
    /// starts with the likely reasons.
    public static func loggedOutAlertText(_ text: String, isDropAuth: Bool) -> String {
        if !isDropAuth || !GGExtrasSettings.logoutReason.value {
            return text
        }
        return GGStrings.Extras.Logout.reasons + "\n\n" + text
    }

    // MARK: Languages

    /// Community translations of Telegram offered next to the official languages. The language
    /// packs come from Telegram's own translation platform (`langpack.getLangPack`), as with a
    /// `t.me/setlanguage/<code>` link — no third-party server.
    public static var extraLocalizations: [LocalizationInfo] {
        if !GGExtrasSettings.extraLanguages.value {
            return []
        }
        return [
            LocalizationInfo(languageCode: "zhcncc", baseLanguageCode: "zh-hans-raw", customPluralizationCode: "zh", title: "Chinese (Simplified)", localizedTitle: "简体中文", isOfficial: true, totalStringCount: 7160, translatedStringCount: 7144, platformUrl: "https://translations.telegram.org/zhcncc/"),
            LocalizationInfo(languageCode: "taiwan", baseLanguageCode: "zh-hant-raw", customPluralizationCode: "zh", title: "Chinese (Taiwan)", localizedTitle: "正體中文", isOfficial: true, totalStringCount: 7160, translatedStringCount: 3761, platformUrl: "https://translations.telegram.org/taiwan/"),
            LocalizationInfo(languageCode: "hongkong", baseLanguageCode: "zh-hant-raw", customPluralizationCode: "zh", title: "Chinese (Hong Kong)", localizedTitle: "中文（香港）", isOfficial: true, totalStringCount: 7358, translatedStringCount: 6083, platformUrl: "https://translations.telegram.org/hongkong/"),
            LocalizationInfo(languageCode: "ja-raw", baseLanguageCode: "ja-raw", customPluralizationCode: "ja", title: "Japanese", localizedTitle: "日本語 (beta)", isOfficial: true, totalStringCount: 9697, translatedStringCount: 9683, platformUrl: "https://translations.telegram.org/ja/"),
            LocalizationInfo(languageCode: "vi-raw", baseLanguageCode: "vi-raw", customPluralizationCode: "vi", title: "Vietnamese", localizedTitle: "Tiếng Việt (beta)", isOfficial: true, totalStringCount: 7160, translatedStringCount: 3795, platformUrl: "https://translations.telegram.org/vi/"),
            LocalizationInfo(languageCode: "hi-raw", baseLanguageCode: "hi-raw", customPluralizationCode: "hi", title: "Hindi", localizedTitle: "हिन्दी (beta)", isOfficial: true, totalStringCount: 7358, translatedStringCount: 992, platformUrl: "https://translations.telegram.org/hi/"),
            LocalizationInfo(languageCode: "earmenian", baseLanguageCode: "earmenian", customPluralizationCode: "hy", title: "Armenian", localizedTitle: "Հայերեն", isOfficial: true, totalStringCount: 7358, translatedStringCount: 6384, platformUrl: "https://translations.telegram.org/earmenian/")
        ]
    }
}

/// «Цепочка упоминаний»: a long press on a mention suggestion asks the panel to put « @» after the
/// mention instead of a space. Main thread only: the suggestion list and the panel live there.
public enum GGExtrasMentionChain {
    private static var isRequested = false

    /// The suggestion was long-pressed; the panel's selection handler runs right after.
    public static func request() {
        assert(Thread.isMainThread)
        GGExtrasMentionChain.isRequested = true
    }

    /// Whether the selection being handled continues the chain; the request is used once.
    public static func consume() -> Bool {
        assert(Thread.isMainThread)
        let value = GGExtrasMentionChain.isRequested
        GGExtrasMentionChain.isRequested = false
        return value
    }

    /// Text that follows an inserted mention.
    public static func suffix() -> String {
        return GGExtrasMentionChain.consume() ? " @" : " "
    }
}

/// «Показать закреп»: a profile's menu asks the chat to show its pinned-message bar again. The chat
/// takes the request when it appears (the request lives 30 s, then it is forgotten). Main thread.
public enum GGExtrasPinnedRequests {
    private static var requests: [EnginePeer.Id: Double] = [:]
    private static let lifetime: Double = 30.0

    public static func request(peerId: EnginePeer.Id) {
        assert(Thread.isMainThread)
        GGExtrasPinnedRequests.requests[peerId] = CFAbsoluteTimeGetCurrent()
    }

    /// Whether the chat with `peerId` should clear its «closed pinned message» now.
    public static func take(peerId: EnginePeer.Id) -> Bool {
        assert(Thread.isMainThread)
        if GGExtrasPinnedRequests.requests.isEmpty {
            return false
        }
        guard let timestamp = GGExtrasPinnedRequests.requests.removeValue(forKey: peerId) else {
            return false
        }
        return CFAbsoluteTimeGetCurrent() - timestamp < GGExtrasPinnedRequests.lifetime
    }
}
