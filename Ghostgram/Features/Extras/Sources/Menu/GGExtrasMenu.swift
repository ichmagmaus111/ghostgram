import Foundation
import SwiftSignalKit
import GGCore
import GGHooks
import GGSettingsUI
import GGFeaturesShared

/// Where the Swiftgram-parity features live in the Ghostgram menu (W5-SG): next to the similar rows
/// of each tab, in a few sections of their own. No new tab: every feature found its place.
enum GGExtrasMenu {
    // Own sections.
    static let linksSection = GGMenuSectionID("extras.links")
    static let messageToolsSection = GGMenuSectionID("extras.messageTools")
    static let groupsSection = GGMenuSectionID("extras.groups")
    static let chatListMenuSection = GGMenuSectionID("extras.chatListMenu")
    static let languageSection = GGMenuSectionID("extras.language")
    static let cacheSection = GGMenuSectionID("extras.cache")
    static let sessionsSection = GGMenuSectionID("extras.sessions")
    /// Right under «Уведомления» (no header of its own: the zone's footer speaks of chat exceptions).
    static let notificationsSection = GGMenuSectionID("extras.notifications")
    static let videoSection = GGMenuSectionID("extras.video")

    // Sections of other zones the rows join (at the end, after their own rows).
    static let sendingInputSection = GGMenuSectionID("sending.input")
    static let passcodeOptionsSection = GGMenuSectionID("security.passcode.options")
    /// W2-5's «Таббар» section of «Панели».
    static let panelsTabBarSection = GGMenuSectionID("appearance.panels.tabBar")

    static func register() {
        GGExtrasMenu.registerSections()
        GGExtrasMenu.registerMessages()
        GGExtrasMenu.registerGroups()
        GGExtrasMenu.registerAppearance()
        GGExtrasMenu.registerMedia()
        GGExtrasMenu.registerSecurity()
    }

    private static func registerSections() {
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.linksSection, screen: .tab(.messagesMenuGestures), order: 400, header: { GGStrings.Extras.Menu.linksHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.messageToolsSection, screen: .tab(.messagesMenuGestures), order: 500, header: { GGStrings.Extras.Menu.messageToolsHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.groupsSection, screen: .category(.messages), order: 350, header: { GGStrings.Extras.Menu.groupsHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.chatListMenuSection, screen: .tab(.appearanceChatList), order: 700, header: { GGStrings.Extras.Menu.chatListMenuHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.languageSection, screen: .tab(.appearanceProfileSettings), order: 600, header: { GGStrings.Extras.Menu.languageHeader }, footer: { _ in GGStrings.Extras.Menu.languageFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.cacheSection, screen: .tab(.mediaDownloads), order: 700, header: { GGStrings.Extras.Menu.cacheHeader }, footer: { _ in GGStrings.Extras.Menu.cacheFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.sessionsSection, screen: .tab(.securityAccounts), order: 400, header: { GGStrings.Extras.Menu.sessionsHeader }, footer: { _ in GGStrings.Extras.Menu.sessionsFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.notificationsSection, screen: .category(.messages), order: 410))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGExtrasMenu.videoSection, screen: .tab(.mediaDownloads), order: 650, header: { GGStrings.Extras.Menu.videoHeader }))
    }

    // MARK: Сообщения

    private static func registerMessages() {
        // Under «Уведомления» (category screen).
        GGMenuRegistry.register(toggle("extras.extraMuteDurations", section: GGExtrasMenu.notificationsSection, order: 100, setting: GGExtrasSettings.extraMuteDurations, title: { GGStrings.Extras.Menu.extraMuteDurations }, subtitle: { GGStrings.Extras.Menu.extraMuteDurationsInfo }))
        GGMenuRegistry.register(toggle("extras.hideAccountInNotifications", section: GGExtrasMenu.notificationsSection, order: 200, setting: GGExtrasSettings.hideAccountInNotifications, title: { GGStrings.Extras.Menu.hideAccountInNotifications }, subtitle: { GGStrings.Extras.Menu.hideAccountInNotificationsInfo }))

        // «Чаты» (category screen).
        GGMenuRegistry.register(toggle("extras.searchPartialWords", section: .messagesChats, order: 1200, setting: GGExtrasSettings.searchPartialWords, title: { GGStrings.Extras.Menu.searchPartialWords }, subtitle: { GGStrings.Extras.Menu.searchPartialWordsInfo }))

        // «Отправка» › «Ввод».
        GGMenuRegistry.register(toggle("extras.mentionChain", section: GGExtrasMenu.sendingInputSection, order: 9000, setting: GGExtrasSettings.mentionChain, title: { GGStrings.Extras.Menu.mentionChain }, subtitle: { GGStrings.Extras.Menu.mentionChainInfo }))
        GGMenuRegistry.register(toggle("extras.noRecordTooltip", section: GGExtrasMenu.sendingInputSection, order: 9100, setting: GGExtrasSettings.noRecordTooltip, title: { GGStrings.Extras.Menu.noRecordTooltip }, subtitle: { GGStrings.Extras.Menu.noRecordTooltipInfo }))

        // «Меню и жесты» › «Ссылки и «Поделиться»».
        let links = GGExtrasMenu.linksSection
        GGMenuRegistry.register(toggle("extras.linkPreviewOpensMedia", section: links, order: 100, setting: GGExtrasSettings.linkPreviewOpensMedia, title: { GGStrings.Extras.Menu.linkPreviewOpensMedia }, subtitle: { GGStrings.Extras.Menu.linkPreviewOpensMediaInfo }))
        GGMenuRegistry.register(toggle("extras.linkMenuShare", section: links, order: 200, setting: GGExtrasSettings.linkMenuShare, title: { GGStrings.Extras.Menu.linkMenuShare }, subtitle: { GGStrings.Extras.Menu.linkMenuShareInfo }))
        GGMenuRegistry.register(toggle("extras.bioLinks", section: links, order: 300, setting: GGExtrasSettings.bioLinks, title: { GGStrings.Extras.Menu.bioLinks }, subtitle: { GGStrings.Extras.Menu.bioLinksInfo }))
        GGMenuRegistry.register(toggle("extras.moreBrowsers", section: links, order: 400, setting: GGExtrasSettings.moreBrowsers, title: { GGStrings.Extras.Menu.moreBrowsers }, subtitle: { GGStrings.Extras.Menu.moreBrowsersInfo }))
        GGMenuRegistry.register(toggle("extras.systemShareSheet", section: links, order: 500, setting: GGExtrasSettings.systemShareSheet, title: { GGStrings.Extras.Menu.systemShareSheet }, subtitle: { GGStrings.Extras.Menu.systemShareSheetInfo }))
        GGMenuRegistry.register(toggle("extras.hideRepostToStory", section: links, order: 600, setting: GGExtrasSettings.hideRepostToStory, title: { GGStrings.Extras.Menu.hideRepostToStory }, subtitle: { GGStrings.Extras.Menu.hideRepostToStoryInfo }))

        // «Меню и жесты» › «Меню и выделение».
        let tools = GGExtrasMenu.messageToolsSection
        GGMenuRegistry.register(toggle("extras.selectionPanelButtons", section: tools, order: 200, setting: GGExtrasSettings.selectionPanelButtons, title: { GGStrings.Extras.Menu.selectionPanelButtons }, subtitle: { GGStrings.Extras.Menu.selectionPanelButtonsInfo }))
    }

    // MARK: Сообщения › Группы и каналы

    private static func registerGroups() {
        let section = GGExtrasMenu.groupsSection
        GGMenuRegistry.register(toggle("extras.adminListsForAllAdmins", section: section, order: 100, setting: GGExtrasSettings.adminListsForAllAdmins, title: { GGStrings.Extras.Menu.adminListsForAllAdmins }, subtitle: { GGStrings.Extras.Menu.adminListsForAllAdminsInfo }))
        GGMenuRegistry.register(toggle("extras.recentActionsShortcut", section: section, order: 200, setting: GGExtrasSettings.recentActionsShortcut, title: { GGStrings.Extras.Menu.recentActionsShortcut }, subtitle: { GGStrings.Extras.Menu.recentActionsShortcutInfo }))
        GGMenuRegistry.register(toggle("extras.administratorsMenuItem", section: section, order: 300, setting: GGExtrasSettings.administratorsMenuItem, title: { GGStrings.Extras.Menu.administratorsMenuItem }, subtitle: { GGStrings.Extras.Menu.administratorsMenuItemInfo }))
        GGMenuRegistry.register(toggle("extras.hiddenPinnedMenuItem", section: section, order: 400, setting: GGExtrasSettings.hiddenPinnedMenuItem, title: { GGStrings.Extras.Menu.hiddenPinnedMenuItem }, subtitle: { GGStrings.Extras.Menu.hiddenPinnedMenuItemInfo }))
        GGMenuRegistry.register(toggle("extras.restrictUntilTime", section: section, order: 500, setting: GGExtrasSettings.restrictUntilTime, title: { GGStrings.Extras.Menu.restrictUntilTime }, subtitle: { GGStrings.Extras.Menu.restrictUntilTimeInfo }))
        GGMenuRegistry.register(toggle("extras.restrictionReasonCode", section: section, order: 600, setting: GGExtrasSettings.restrictionReasonCode, title: { GGStrings.Extras.Menu.restrictionReasonCode }, subtitle: { GGStrings.Extras.Menu.restrictionReasonCodeInfo }))
        GGMenuRegistry.register(toggle("extras.discussionButton", section: section, order: 700, setting: GGExtrasSettings.discussionButton, title: { GGStrings.Extras.Menu.discussionButton }, subtitle: { GGStrings.Extras.Menu.discussionButtonInfo }))
    }

    // MARK: Оформление

    private static func registerAppearance() {
        let chatList = GGExtrasMenu.chatListMenuSection
        GGMenuRegistry.register(toggle("extras.archiveInChatMenu", section: chatList, order: 100, setting: GGExtrasSettings.archiveInChatMenu, title: { GGStrings.Extras.Menu.archiveInChatMenu }, subtitle: { GGStrings.Extras.Menu.archiveInChatMenuInfo }))
        GGMenuRegistry.register(toggle("extras.hidePremiumOffers", section: chatList, order: 200, setting: GGExtrasSettings.hidePremiumOffers, title: { GGStrings.Extras.Menu.hidePremiumOffers }, subtitle: { GGStrings.Extras.Menu.hidePremiumOffersInfo }))

        // «Панели» › tab bar (W2-5's section).

        GGMenuRegistry.register(toggle("extras.extraLanguages", section: GGExtrasMenu.languageSection, order: 100, setting: GGExtrasSettings.extraLanguages, title: { GGStrings.Extras.Menu.extraLanguages }, subtitle: { GGStrings.Extras.Menu.extraLanguagesInfo }))
    }

    // MARK: Медиа › Загрузки и качество

    private static func registerMedia() {
        GGMenuRegistry.register(toggle("extras.youTubePictureInPicture", section: GGExtrasMenu.videoSection, order: 100, setting: GGExtrasSettings.youTubePictureInPicture, title: { GGStrings.Extras.Menu.youTubePictureInPicture }, subtitle: { GGStrings.Extras.Menu.youTubePictureInPictureInfo }))
        GGMenuRegistry.register(toggle("extras.extraCacheOptions", section: GGExtrasMenu.cacheSection, order: 100, setting: GGExtrasSettings.extraCacheOptions, title: { GGStrings.Extras.Menu.extraCacheOptions }, subtitle: { GGStrings.Extras.Menu.extraCacheOptionsInfo }))
    }

    // MARK: Безопасность

    private static func registerSecurity() {
        GGMenuRegistry.register(toggle("extras.autolockFiveSeconds", section: GGExtrasMenu.passcodeOptionsSection, order: 9000, setting: GGExtrasSettings.autolockFiveSeconds, title: { GGStrings.Extras.Menu.autolockFiveSeconds }, subtitle: { GGStrings.Extras.Menu.autolockFiveSecondsInfo }))
        let sessions = GGExtrasMenu.sessionsSection
        GGMenuRegistry.register(toggle("extras.sessionDetails", section: sessions, order: 100, setting: GGExtrasSettings.sessionDetails, title: { GGStrings.Extras.Menu.sessionDetails }, subtitle: { GGStrings.Extras.Menu.sessionDetailsInfo }))
        GGMenuRegistry.register(toggle("extras.qrLoginAlways", section: sessions, order: 200, setting: GGExtrasSettings.qrLoginAlways, title: { GGStrings.Extras.Menu.qrLoginAlways }, subtitle: { GGStrings.Extras.Menu.qrLoginAlwaysInfo }))
        GGMenuRegistry.register(toggle("extras.logoutReason", section: sessions, order: 300, setting: GGExtrasSettings.logoutReason, title: { GGStrings.Extras.Menu.logoutReason }, subtitle: { GGStrings.Extras.Menu.logoutReasonInfo }))
        // «Аккаунты» (W3-4's tab), after its own rows.
        GGMenuRegistry.register(toggle("extras.addAccountRow", section: GGMenuSectionID.main(of: GGMenuTabID.securityAccounts), order: 9000, setting: GGExtrasSettings.addAccountRow, title: { GGStrings.Extras.Menu.addAccountRow }, subtitle: { GGStrings.Extras.Menu.addAccountRowInfo }))
        // The row is built with the Settings tab, which Telegram rebuilds only when its own data
        // changes: the switch rebuilds it at once.
        GGExtrasMenu.addAccountRowDisposable = (GGExtrasSettings.addAccountRow.signal
        |> deliverOnMainQueue).start(next: { _ in
            GGSettingsTabHooks.invalidate()
        })
    }

    private static var addAccountRowDisposable: Disposable?

    private static func toggle(_ id: String, section: GGMenuSectionID, order: Int, setting: GGSetting<Bool>, title: @escaping () -> String, subtitle: (() -> String)? = nil) -> GGMenuRow {
        return GGMenuRow(id: id, section: section, order: order, title: title, subtitle: subtitle, kind: .toggle(.global(setting)))
    }
}
