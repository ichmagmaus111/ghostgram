import Foundation
import GGCore

// The fixed part of the menu (PLAN §2, FOUNDATION_SPEC §5.1): six categories, every tab with its
// «кнопка с подписью», and the sections features register their rows into. Each tab gets two
// sections: `<tab>.preview` (order 100) and `<tab>.main` (order 200); features add more as needed.

extension GGMenuCategory {
    public var title: String {
        switch self {
        case .privacy:
            return GGStrings.Menu.Category.privacy
        case .messages:
            return GGStrings.Menu.Category.messages
        case .media:
            return GGStrings.Menu.Category.media
        case .appearance:
            return GGStrings.Menu.Category.appearance
        case .security:
            return GGStrings.Menu.Category.security
        case .more:
            return GGStrings.Menu.Category.more
        }
    }

    public var subtitle: String {
        switch self {
        case .privacy:
            return GGStrings.Menu.Category.privacyInfo
        case .messages:
            return GGStrings.Menu.Category.messagesInfo
        case .media:
            return GGStrings.Menu.Category.mediaInfo
        case .appearance:
            return GGStrings.Menu.Category.appearanceInfo
        case .security:
            return GGStrings.Menu.Category.securityInfo
        case .more:
            return GGStrings.Menu.Category.moreInfo
        }
    }

    public var icon: GGMenuIcon {
        switch self {
        case .privacy:
            return .ghost
        case .messages:
            return .bundle("Chat/Context Menu/Message")
        case .media:
            return .bundle("Chat/Context Menu/Image")
        case .appearance:
            return .bundle("Chat/Context Menu/Customize")
        case .security:
            return .bundle("Chat/Context Menu/Lock")
        case .more:
            return .bundle("Chat/Context Menu/More")
        }
    }
}

extension GGMenuTabID {
    // Privacy
    public static let privacyGhostExceptions = GGMenuTabID("privacy.ghostExceptions")
    public static let privacySendDelay = GGMenuTabID("privacy.sendDelay")
    public static let privacySpoofing = GGMenuTabID("privacy.spoofing")
    public static let privacyAnonymousMode = GGMenuTabID("privacy.anonymousMode")
    // Messages
    public static let messagesAntiDelete = GGMenuTabID("messages.antiDelete")
    public static let messagesRestrictions = GGMenuTabID("messages.restrictions")
    public static let messagesSending = GGMenuTabID("messages.sending")
    public static let messagesTranslation = GGMenuTabID("messages.translation")
    public static let messagesMenuGestures = GGMenuTabID("messages.menuGestures")
    public static let messagesExport = GGMenuTabID("messages.export")
    // Media and calls
    public static let mediaVoice = GGMenuTabID("media.voice")
    public static let mediaCameraVideoMessages = GGMenuTabID("media.cameraVideoMessages")
    public static let mediaCalls = GGMenuTabID("media.calls")
    public static let mediaDownloads = GGMenuTabID("media.downloads")
    // Appearance
    public static let appearanceMessages = GGMenuTabID("appearance.messages")
    public static let appearanceChatList = GGMenuTabID("appearance.chatList")
    public static let appearancePanels = GGMenuTabID("appearance.panels")
    public static let appearanceThemeBackground = GGMenuTabID("appearance.themeBackground")
    public static let appearanceIcons = GGMenuTabID("appearance.icons")
    public static let appearanceProfileSettings = GGMenuTabID("appearance.profileSettings")
    // Security
    public static let securityChatProtection = GGMenuTabID("security.chatProtection")
    public static let securityPasscode = GGMenuTabID("security.passcode")
    public static let securityAccounts = GGMenuTabID("security.accounts")
    // More
    public static let moreVpn = GGMenuTabID("more.vpn")
    public static let moreNickBadge = GGMenuTabID("more.nickBadge")
    public static let moreFakeGifts = GGMenuTabID("more.fakeGifts")
    public static let moreGhostgramSettings = GGMenuTabID("more.ghostgramSettings")
    public static let moreAbout = GGMenuTabID("more.about")
}

extension GGMenuSectionID {
    // Category screens
    public static let privacyPreview = GGMenuSectionID("privacy.preview")
    public static let privacyGhostMode = GGMenuSectionID("privacy.ghostMode")
    public static let privacyTabs = GGMenuSectionID("privacy.tabs")
    public static let privacyTraces = GGMenuSectionID("privacy.traces")
    public static let messagesPreview = GGMenuSectionID("messages.preview")
    public static let messagesTabs = GGMenuSectionID("messages.tabs")
    public static let messagesChats = GGMenuSectionID("messages.chats")
    public static let mediaTabs = GGMenuSectionID("media.tabs")
    public static let appearanceTabs = GGMenuSectionID("appearance.tabs")
    public static let securityTabs = GGMenuSectionID("security.tabs")
    public static let moreTabs = GGMenuSectionID("more.tabs")
    // «Настройки Ghostgram» and «О приложении»
    public static let ghostgramSettingsLanguage = GGMenuSectionID("more.ghostgramSettings.language")
    public static let ghostgramSettingsData = GGMenuSectionID("more.ghostgramSettings.data")
    public static let aboutInfo = GGMenuSectionID("more.about.info")
    public static let aboutLinks = GGMenuSectionID("more.about.links")
    public static let aboutLicense = GGMenuSectionID("more.about.license")

    /// `<tab>.preview`, order 100 on the tab screen.
    public static func preview(of tab: GGMenuTabID) -> GGMenuSectionID {
        return GGMenuSectionID(tab.rawValue + ".preview")
    }

    /// `<tab>.main`, order 200 on the tab screen.
    public static func main(of tab: GGMenuTabID) -> GGMenuSectionID {
        return GGMenuSectionID(tab.rawValue + ".main")
    }
}

private struct GGSkeletonTab {
    let id: GGMenuTabID
    let section: GGMenuSectionID
    let order: Int
    let title: () -> String
    let info: () -> String
    let icon: GGMenuIcon
    let emoji: String
}

private func ggSkeletonTabs() -> [GGSkeletonTab] {
    return [
        GGSkeletonTab(id: .privacyGhostExceptions, section: .privacyTabs, order: 100, title: { GGStrings.Menu.Tab.Privacy.ghostExceptions }, info: { GGStrings.Menu.Tab.Privacy.ghostExceptionsInfo }, icon: .bundle("Chat/Context Menu/Eye"), emoji: "👥"),
        GGSkeletonTab(id: .privacySendDelay, section: .privacyTabs, order: 200, title: { GGStrings.Menu.Tab.Privacy.sendDelay }, info: { GGStrings.Menu.Tab.Privacy.sendDelayInfo }, icon: .bundle("Chat/Context Menu/Schedule"), emoji: "⏳"),
        GGSkeletonTab(id: .privacySpoofing, section: .privacyTabs, order: 300, title: { GGStrings.Menu.Tab.Privacy.spoofing }, info: { GGStrings.Menu.Tab.Privacy.spoofingInfo }, icon: .bundle("Chat/Context Menu/Replace"), emoji: "🎭"),
        GGSkeletonTab(id: .privacyAnonymousMode, section: .privacyTabs, order: 400, title: { GGStrings.Menu.Tab.Privacy.anonymousMode }, info: { GGStrings.Menu.Tab.Privacy.anonymousModeInfo }, icon: .bundle("Chat/Context Menu/EyeLocked"), emoji: "🕶"),

        GGSkeletonTab(id: .messagesAntiDelete, section: .messagesTabs, order: 100, title: { GGStrings.Menu.Tab.Messages.antiDelete }, info: { GGStrings.Menu.Tab.Messages.antiDeleteInfo }, icon: .bundle("Chat/Context Menu/Delete"), emoji: "🗑"),
        GGSkeletonTab(id: .messagesRestrictions, section: .messagesTabs, order: 200, title: { GGStrings.Menu.Tab.Messages.restrictions }, info: { GGStrings.Menu.Tab.Messages.restrictionsInfo }, icon: .bundle("Chat/Context Menu/Copy"), emoji: "🔓"),
        GGSkeletonTab(id: .messagesSending, section: .messagesTabs, order: 300, title: { GGStrings.Menu.Tab.Messages.sending }, info: { GGStrings.Menu.Tab.Messages.sendingInfo }, icon: .bundle("Chat/Context Menu/FormatText"), emoji: "✉️"),
        GGSkeletonTab(id: .messagesTranslation, section: .messagesTabs, order: 400, title: { GGStrings.Menu.Tab.Messages.translation }, info: { GGStrings.Menu.Tab.Messages.translationInfo }, icon: .bundle("Chat/Context Menu/Translate"), emoji: "🌐"),
        GGSkeletonTab(id: .messagesMenuGestures, section: .messagesTabs, order: 500, title: { GGStrings.Menu.Tab.Messages.menuGestures }, info: { GGStrings.Menu.Tab.Messages.menuGesturesInfo }, icon: .bundle("Chat/Context Menu/List"), emoji: "👆"),
        GGSkeletonTab(id: .messagesExport, section: .messagesTabs, order: 600, title: { GGStrings.Menu.Tab.Messages.export }, info: { GGStrings.Menu.Tab.Messages.exportInfo }, icon: .bundle("Chat/Context Menu/Share"), emoji: "📦"),

        GGSkeletonTab(id: .mediaVoice, section: .mediaTabs, order: 100, title: { GGStrings.Menu.Tab.Media.voice }, info: { GGStrings.Menu.Tab.Media.voiceInfo }, icon: .bundle("Chat/Context Menu/VoiceChat"), emoji: "🎙"),
        GGSkeletonTab(id: .mediaCameraVideoMessages, section: .mediaTabs, order: 200, title: { GGStrings.Menu.Tab.Media.cameraVideoMessages }, info: { GGStrings.Menu.Tab.Media.cameraVideoMessagesInfo }, icon: .bundle("Chat/Context Menu/Camera"), emoji: "📹"),
        GGSkeletonTab(id: .mediaCalls, section: .mediaTabs, order: 300, title: { GGStrings.Menu.Tab.Media.calls }, info: { GGStrings.Menu.Tab.Media.callsInfo }, icon: .bundle("Chat/Context Menu/PhoneCall"), emoji: "📞"),
        GGSkeletonTab(id: .mediaDownloads, section: .mediaTabs, order: 400, title: { GGStrings.Menu.Tab.Media.downloads }, info: { GGStrings.Menu.Tab.Media.downloadsInfo }, icon: .bundle("Chat/Context Menu/Download"), emoji: "⚡️"),

        GGSkeletonTab(id: .appearanceMessages, section: .appearanceTabs, order: 100, title: { GGStrings.Menu.Tab.Appearance.messages }, info: { GGStrings.Menu.Tab.Appearance.messagesInfo }, icon: .bundle("Chat/Context Menu/MessageBubble"), emoji: "💬"),
        GGSkeletonTab(id: .appearanceChatList, section: .appearanceTabs, order: 200, title: { GGStrings.Menu.Tab.Appearance.chatList }, info: { GGStrings.Menu.Tab.Appearance.chatListInfo }, icon: .bundle("Chat/Context Menu/Chats"), emoji: "📋"),
        GGSkeletonTab(id: .appearancePanels, section: .appearanceTabs, order: 300, title: { GGStrings.Menu.Tab.Appearance.panels }, info: { GGStrings.Menu.Tab.Appearance.panelsInfo }, icon: .bundle("Chat/Context Menu/AlignBottom"), emoji: "🧩"),
        GGSkeletonTab(id: .appearanceThemeBackground, section: .appearanceTabs, order: 400, title: { GGStrings.Menu.Tab.Appearance.themeBackground }, info: { GGStrings.Menu.Tab.Appearance.themeBackgroundInfo }, icon: .bundle("Chat/Context Menu/ApplyTheme"), emoji: "🎨"),
        GGSkeletonTab(id: .appearanceIcons, section: .appearanceTabs, order: 500, title: { GGStrings.Menu.Tab.Appearance.icons }, info: { GGStrings.Menu.Tab.Appearance.iconsInfo }, icon: .bundle("Chat/Context Menu/Apps"), emoji: "🖼"),
        GGSkeletonTab(id: .appearanceProfileSettings, section: .appearanceTabs, order: 600, title: { GGStrings.Menu.Tab.Appearance.profileSettings }, info: { GGStrings.Menu.Tab.Appearance.profileSettingsInfo }, icon: .bundle("Chat/Context Menu/User"), emoji: "🪪"),

        GGSkeletonTab(id: .securityChatProtection, section: .securityTabs, order: 100, title: { GGStrings.Menu.Tab.Security.chatProtection }, info: { GGStrings.Menu.Tab.Security.chatProtectionInfo }, icon: .bundle("Chat/Context Menu/Lock"), emoji: "🔐"),
        GGSkeletonTab(id: .securityPasscode, section: .securityTabs, order: 300, title: { GGStrings.Menu.Tab.Security.passcode }, info: { GGStrings.Menu.Tab.Security.passcodeInfo }, icon: .bundle("Chat/Context Menu/FaceId"), emoji: "🔢"),
        GGSkeletonTab(id: .securityAccounts, section: .securityTabs, order: 400, title: { GGStrings.Menu.Tab.Security.accounts }, info: { GGStrings.Menu.Tab.Security.accountsInfo }, icon: .bundle("Chat/Context Menu/AddUser"), emoji: "👤"),

        GGSkeletonTab(id: .moreVpn, section: .moreTabs, order: 100, title: { GGStrings.Menu.Tab.More.vpn }, info: { GGStrings.Menu.Tab.More.vpnInfo }, icon: .bundle("Chat/Context Menu/Globe"), emoji: "🛡"),
        GGSkeletonTab(id: .moreNickBadge, section: .moreTabs, order: 200, title: { GGStrings.Menu.Tab.More.nickBadge }, info: { GGStrings.Menu.Tab.More.nickBadgeInfo }, icon: .bundle("Chat/Context Menu/Tag"), emoji: "🏷"),
        GGSkeletonTab(id: .moreFakeGifts, section: .moreTabs, order: 300, title: { GGStrings.Menu.Tab.More.fakeGifts }, info: { GGStrings.Menu.Tab.More.fakeGiftsInfo }, icon: .bundle("Chat/Context Menu/Gift"), emoji: "🎁"),
        GGSkeletonTab(id: .moreGhostgramSettings, section: .moreTabs, order: 400, title: { GGStrings.Menu.Tab.More.ghostgramSettings }, info: { GGStrings.Menu.Tab.More.ghostgramSettingsInfo }, icon: .bundle("Chat/Context Menu/Settings"), emoji: "⚙️"),
        GGSkeletonTab(id: .moreAbout, section: .moreTabs, order: 500, title: { GGStrings.Menu.Tab.More.about }, info: { GGStrings.Menu.Tab.More.aboutInfo }, icon: .bundle("Chat/Context Menu/Info"), emoji: "👻")
    ]
}

func ggRegisterMenuSkeleton() {
    // Category screens.
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .privacyPreview, screen: .category(.privacy), order: 100))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .privacyGhostMode, screen: .category(.privacy), order: 200, header: { GGStrings.Menu.Section.Privacy.ghostMode }))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .privacyTabs, screen: .category(.privacy), order: 300))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .privacyTraces, screen: .category(.privacy), order: 400, header: { GGStrings.Menu.Section.Privacy.traces }))

    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .messagesPreview, screen: .category(.messages), order: 100))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .messagesTabs, screen: .category(.messages), order: 200))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .messagesChats, screen: .category(.messages), order: 300, header: { GGStrings.Menu.Section.Messages.chats }))

    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .mediaTabs, screen: .category(.media), order: 100))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .appearanceTabs, screen: .category(.appearance), order: 100))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .securityTabs, screen: .category(.security), order: 100))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .moreTabs, screen: .category(.more), order: 100))

    // Tabs, their links and their default sections.
    for tab in ggSkeletonTabs() {
        let emoji = tab.emoji
        let info = tab.info
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: tab.id,
                parent: GGMenuStorage.shared.sectionsById[tab.section]?.screen ?? .root,
                title: tab.title,
                topView: GGMenuTopView(content: .emoji(emoji), text: info),
                searchKeywords: { [info()] }
            ),
            linkIn: tab.section,
            order: tab.order,
            subtitle: info,
            icon: tab.icon
        )
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .preview(of: tab.id), screen: .tab(tab.id), order: 100))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .main(of: tab.id), screen: .tab(tab.id), order: 200))
    }

    // «Настройки Ghostgram» and «О приложении» carry W1-3's own rows (see GGSettingsDataScreens.swift).
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .ghostgramSettingsLanguage, screen: .tab(.moreGhostgramSettings), order: 300, header: { GGStrings.Menu.Settings.languageHeader }, footer: { _ in GGStrings.Menu.Settings.languageFooter }))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .ghostgramSettingsData, screen: .tab(.moreGhostgramSettings), order: 400, header: { GGStrings.Menu.Settings.dataHeader }, footer: { _ in GGStrings.Menu.Settings.dataFooter }))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .aboutInfo, screen: .tab(.moreAbout), order: 300))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .aboutLinks, screen: .tab(.moreAbout), order: 400, header: { GGStrings.Menu.Root.links }))
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .aboutLicense, screen: .tab(.moreAbout), order: 500, header: { GGStrings.Menu.About.licenseHeader }, footer: { _ in GGStrings.Menu.About.licenseFooter }))
}
