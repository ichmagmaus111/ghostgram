import Foundation
import GGCore

// Every setting of the Interface zone (chat list, folders, tab bar, input panel, icons, the
// Settings tab), declared once. Defaults live here and nowhere else; user toggles are off.
// Keys: `interface.<feature>.<key>` (strings use the same `interface` namespace).

/// Geometry of the chat input panel (input bar editor). Zero = upstream layout.
struct GGInputBarGeometry: Codable, Equatable, GGSettingValue {
    /// Extra height of the text field, pt (0…100).
    var heightPadding: Double
    /// Insets of the text field from the left / right edge, pt (0…160).
    var leftMargin: Double
    var rightMargin: Double
    /// Lift of the whole panel above the bottom edge, pt (0…220).
    var bottomOffset: Double
    /// Free offsets of the attachment, emoji (accessory) and send / record buttons, pt.
    var attachX: Double
    var attachY: Double
    var accessoryX: Double
    var accessoryY: Double
    var sendX: Double
    var sendY: Double

    static let zero = GGInputBarGeometry(heightPadding: 0.0, leftMargin: 0.0, rightMargin: 0.0, bottomOffset: 0.0, attachX: 0.0, attachY: 0.0, accessoryX: 0.0, accessoryY: 0.0, sendX: 0.0, sendY: 0.0)

    var isZero: Bool {
        return self == GGInputBarGeometry.zero
    }

    static let heightPaddingRange: ClosedRange<Double> = 0.0 ... 100.0
    static let marginRange: ClosedRange<Double> = 0.0 ... 160.0
    static let bottomOffsetRange: ClosedRange<Double> = 0.0 ... 220.0
    static let buttonXRange: ClosedRange<Double> = -120.0 ... 120.0
    static let buttonYRange: ClosedRange<Double> = -80.0 ... 80.0

    /// Clamped to the editor's ranges (an imported file may hold anything).
    var clamped: GGInputBarGeometry {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            return min(range.upperBound, max(range.lowerBound, value))
        }
        return GGInputBarGeometry(
            heightPadding: clamp(self.heightPadding, GGInputBarGeometry.heightPaddingRange),
            leftMargin: clamp(self.leftMargin, GGInputBarGeometry.marginRange),
            rightMargin: clamp(self.rightMargin, GGInputBarGeometry.marginRange),
            bottomOffset: clamp(self.bottomOffset, GGInputBarGeometry.bottomOffsetRange),
            attachX: clamp(self.attachX, GGInputBarGeometry.buttonXRange),
            attachY: clamp(self.attachY, GGInputBarGeometry.buttonYRange),
            accessoryX: clamp(self.accessoryX, GGInputBarGeometry.buttonXRange),
            accessoryY: clamp(self.accessoryY, GGInputBarGeometry.buttonYRange),
            sendX: clamp(self.sendX, GGInputBarGeometry.buttonXRange),
            sendY: clamp(self.sendY, GGInputBarGeometry.buttonYRange)
        )
    }
}

/// A row pinned to Telegram's Settings tab («Ярлыки»).
struct GGSettingsShortcut: Codable, Equatable, GGSettingValue {
    enum Kind: String, Codable {
        case chat
        case miniApp
        case site
    }

    /// `chat:<peer>`, `miniApp:<peer>` or `site:<normalized url>`. Unique within the list.
    var id: String
    var kind: Kind
    var peer: GGPeerKey?
    /// Normalized absolute http(s) URL for sites.
    var url: String?
    /// User title for sites; chats and mini apps always show the peer's current name.
    var title: String?
}

enum InterfaceSettings {
    // MARK: Chat list (chatlist_tweaks, SG-B1…B5)

    /// SG-B1: smaller rows and avatars.
    static let compactList = GGSetting<Bool>("interface.chatList.compact", default: false)
    /// SG-B2: lines of message preview, "1" / "2" / "3". "2" is Telegram's layout.
    static let previewLines = GGSetting<String>("interface.chatList.previewLines", default: "2")
    /// Row height in percent of Telegram's ("80" … "130").
    static let rowScale = GGSetting<String>("interface.chatList.rowScale", default: "100")
    /// Avatar size in percent of Telegram's ("70" … "120").
    static let avatarScale = GGSetting<String>("interface.chatList.avatarScale", default: "100")
    static let hideEmojiStatus = GGSetting<Bool>("interface.chatList.hideEmojiStatus", default: false)
    static let hideSearchField = GGSetting<Bool>("interface.chatList.hideSearchField", default: false)
    /// A small avatar of the sender before the preview text (groups).
    static let senderAvatars = GGSetting<Bool>("interface.chatList.senderAvatars", default: false)
    static let hidePreview = GGSetting<Bool>("interface.chatList.hidePreview", default: false)
    /// "all" or "selected" (the chats in `hidePreviewPeers`).
    static let hidePreviewScope = GGSetting<String>("interface.chatList.hidePreviewScope", default: "all")
    static let hidePreviewPeers = GGAccountSetting<Set<GGPeerKey>>("interface.chatList.hidePreviewPeers", default: [])
    /// SG-B3: "all" (Telegram), "noDelete", "none".
    static let swipeActions = GGSetting<String>("interface.chatList.swipeActions", default: "all")
    /// SG-B4.
    static let disableStoryCameraSwipe = GGSetting<Bool>("interface.chatList.disableStoryCameraSwipe", default: false)
    /// SG-B5: no stories strip above the list.
    static let hideStories = GGSetting<Bool>("interface.chatList.hideStories", default: false)
    /// No story rings around the avatars of the rows.
    static let hideStoryRings = GGSetting<Bool>("interface.chatList.hideStoryRings", default: false)
    static let hideProxySponsor = GGSetting<Bool>("interface.chatList.hideProxySponsor", default: false)
    /// Only the spinner while connecting, no «Соединение…» text.
    static let hideConnectionText = GGSetting<Bool>("interface.chatList.hideConnectionText", default: false)
    /// A numeric query in the chat list search also looks the id up. On by default: Swiftgram does it
    /// always (W6-SGD, owner's decision 2026-10-29).
    static let searchById = GGSetting<Bool>("interface.chatList.searchById", default: true)

    // MARK: Avatars (square_avatars)

    /// «Скругление углов»: "0" = Telegram's circle, "25"…"100" = how far from a circle the shape
    /// goes (`GGAvatarCorners`). Replaced «Квадратные аватары» + its level on 2026-10-27.
    static let avatarCorners = GGSetting<String>("interface.avatars.corners", default: GGAvatarCorners.round)
    static let roundAvatarsInForums = GGSetting<Bool>("interface.avatars.roundInForums", default: false)
    /// "" = the theme's colors, otherwise "RRGGBB".
    static let storyRingColor = GGSetting<String>("interface.avatars.storyRingColor", default: "")

    // MARK: Folders (folders_tweaks, SG-A5…A9)

    /// SG-A5: the folder strip above the tab bar (`GGChatListFolderStrip.atBottom`).
    static let foldersAtBottom = GGSetting<Bool>("interface.folders.atBottom", default: false)
    /// Service: the old client's `ExperimentalUISettings.foldersTabAtBottom` was read once.
    static let foldersAtBottomImported = GGSetting<Bool>("interface.folders.atBottomImported", default: false, flags: [.noExport])
    static let hideAllChats = GGSetting<Bool>("interface.folders.hideAllChats", default: false)
    static let compactFolderTabs = GGSetting<Bool>("interface.folders.compactTabs", default: false)
    /// "default" (Telegram's «Все») or "long" («Все чаты»).
    static let allChatsTitle = GGSetting<String>("interface.folders.allChatsTitle", default: "default")
    static let rememberLastFolder = GGSetting<Bool>("interface.folders.rememberLast", default: false)
    /// The folder the list showed last, per account: 0 = «Все чаты», otherwise the filter id.
    static let lastFolder = GGAccountSetting<Int32>("interface.folders.lastFolder", default: 0, flags: [.noExport])
    /// Extra height of the folder tab strip, pt (0…24).
    static let folderBarHeightOffset = GGSetting<Double>("interface.folders.barHeightOffset", default: 0.0)

    // MARK: Tab bar (tabbar_tweaks, SG-A1…A4)

    /// Order of the tab ids: "contacts", "calls", "chats", "settings".
    static let tabOrder = GGSetting<[String]>("interface.tabBar.order", default: GGTabBarLayout.defaultOrder)
    /// Own labels by tab id.
    static let tabTitles = GGSetting<[String: String]>("interface.tabBar.titles", default: [:])
    /// Tabs taken out of the bar ("contacts", "calls"); the chat list and Settings always stay.
    static let hiddenTabs = GGSetting<[String]>("interface.tabBar.hidden", default: [])
    static let hideTabTitles = GGSetting<Bool>("interface.tabBar.hideTitles", default: false)
    static let wideTabBar = GGSetting<Bool>("interface.tabBar.wide", default: false)
    static let hideTabBar = GGSetting<Bool>("interface.tabBar.hide", default: false)
    /// Extra height of the bar and its lift above the bottom edge, pt.
    static let tabBarHeightOffset = GGSetting<Double>("interface.tabBar.heightOffset", default: 0.0)
    static let tabBarBottomOffset = GGSetting<Double>("interface.tabBar.bottomOffset", default: 0.0)

    // MARK: Input panel (input_bar_editor, typing_animation, SG-F11, SG-G9)

    static let inputBarGeometry = GGSetting<GGInputBarGeometry>("interface.inputBar.geometry", default: .zero)
    static let characterCounter = GGSetting<Bool>("interface.inputBar.characterCounter", default: false)
    /// SG-F11: the formatting toolbar above the keyboard, in every composer.
    static let formattingToolbar = GGSetting<Bool>("interface.inputBar.formattingToolbar", default: false)
    static let autoFormatting = GGSetting<Bool>("interface.inputBar.autoFormatting", default: false)
    /// "bold", "italic", "monospace", "strikethrough", "underline", "spoiler", "quote", "code".
    static let autoFormattingStyle = GGSetting<String>("interface.inputBar.autoFormattingStyle", default: "bold")
    /// SG-G9.
    static let emojiTabFirst = GGSetting<Bool>("interface.inputBar.emojiTabFirst", default: false)
    static let standardEmojiFirst = GGSetting<Bool>("interface.inputBar.standardEmojiFirst", default: false)

    static let typingAnimation = GGSetting<Bool>("interface.typingAnimation.enabled", default: false)
    /// "pulse", "wave", "panelWave", "neon", "shake", "custom".
    static let typingAnimationPreset = GGSetting<String>("interface.typingAnimation.preset", default: "wave")
    static let typingAnimationIntensity = GGSetting<Double>("interface.typingAnimation.intensity", default: 55.0)
    static let typingAnimationSpeed = GGSetting<Double>("interface.typingAnimation.speed", default: 55.0)
    static let typingAnimationScale = GGSetting<Double>("interface.typingAnimation.scale", default: 45.0)
    static let typingAnimationOffset = GGSetting<Double>("interface.typingAnimation.offset", default: 45.0)
    static let typingAnimationGlow = GGSetting<Double>("interface.typingAnimation.glow", default: 55.0)

    // MARK: Quick buttons in a chat (bind_buttons)

    static let bindButtons = GGSetting<Bool>("interface.bindButtons.enabled", default: false)
    /// Action ids switched off by the user (all registered actions show by default once the
    /// master switch is on — the master is the feature toggle and is off by default).
    static let bindButtonsHidden = GGSetting<[String]>("interface.bindButtons.hidden", default: [])
    /// Where each button stands: action id → [x, y], its centre in the chat's free area, 0…1
    /// (`GGQuickButtonsLayout`). A button without an entry stands in the column on the right.
    /// Written by «Расположение и размер» (`GGQuickButtonsEditorController`).
    static let bindButtonsPositions = GGSetting<[String: [Double]]>("interface.bindButtons.positions", default: [:])
    /// Size of every button, pt (`GGQuickButtonsLayout.sideRange`).
    static let bindButtonsWidth = GGSetting<Double>("interface.bindButtons.width", default: GGQuickButtonsLayout.defaultSide)
    static let bindButtonsHeight = GGSetting<Double>("interface.bindButtons.height", default: GGQuickButtonsLayout.defaultSide)

    // MARK: Custom recent reactions (custom_recent_reactions)

    static let customReactions = GGSetting<Bool>("interface.customReactions.enabled", default: false)
    /// "e:<emoji>" for builtin reactions, "doc:<file id>" for custom emoji (the old wire format).
    static let customReactionsList = GGSetting<[String]>("interface.customReactions.list", default: GGCustomReactions.defaultList)
    /// Telegram's own top reactions after the custom set.
    static let customReactionsAppendStandard = GGSetting<Bool>("interface.customReactions.appendStandard", default: false)

    // MARK: Icon packs (icon_packs)

    /// Enabled packs, highest priority first. Empty = Telegram's icons.
    static let iconPacks = GGSetting<[String]>("interface.iconPacks.enabled", default: [])

    // MARK: Badge under the cutout (app_icons_badges, SG-I2)

    /// On by default, as in the old client: the Ghostgram badge takes the place of Telegram's,
    /// which is never shown (`GGIslandBadge`).
    static let islandBadge = GGSetting<Bool>("interface.islandBadge.enabled", default: true)
    /// "ghostgram" (bundled) or the id of a studio badge.
    static let islandBadgeSelection = GGSetting<String>("interface.islandBadge.selection", default: "ghostgram")

    // MARK: Telegram's Settings tab (settings_structure)

    /// Telegram rows hidden from the Settings tab (`GGSettingsTabItem.rawValue`).
    static let hiddenSettingsItems = GGSetting<[String]>("interface.settingsTab.hidden", default: [])
    /// Order of Telegram's rows inside their sections; empty = Telegram's order.
    static let settingsItemsOrder = GGSetting<[String]>("interface.settingsTab.order", default: [])
    static let settingsShortcuts = GGAccountSetting<[GGSettingsShortcut]>("interface.settingsTab.shortcuts", default: [])

    /// Called from `GGInterfaceModule.register()`: the registry must know every setting before
    /// export, search and migrations run.
    static func declare() {
        let _ = InterfaceSettings.compactList
        let _ = InterfaceSettings.previewLines
        let _ = InterfaceSettings.rowScale
        let _ = InterfaceSettings.avatarScale
        let _ = InterfaceSettings.hideEmojiStatus
        let _ = InterfaceSettings.hideSearchField
        let _ = InterfaceSettings.senderAvatars
        let _ = InterfaceSettings.hidePreview
        let _ = InterfaceSettings.hidePreviewScope
        let _ = InterfaceSettings.hidePreviewPeers
        let _ = InterfaceSettings.swipeActions
        let _ = InterfaceSettings.disableStoryCameraSwipe
        let _ = InterfaceSettings.hideStories
        let _ = InterfaceSettings.hideStoryRings
        let _ = InterfaceSettings.hideProxySponsor
        let _ = InterfaceSettings.hideConnectionText
        let _ = InterfaceSettings.searchById

        let _ = InterfaceSettings.avatarCorners
        let _ = InterfaceSettings.roundAvatarsInForums
        let _ = InterfaceSettings.storyRingColor

        let _ = InterfaceSettings.foldersAtBottom
        let _ = InterfaceSettings.foldersAtBottomImported
        let _ = InterfaceSettings.hideAllChats
        let _ = InterfaceSettings.compactFolderTabs
        let _ = InterfaceSettings.allChatsTitle
        let _ = InterfaceSettings.rememberLastFolder
        let _ = InterfaceSettings.lastFolder
        let _ = InterfaceSettings.folderBarHeightOffset

        let _ = InterfaceSettings.tabOrder
        let _ = InterfaceSettings.tabTitles
        let _ = InterfaceSettings.hiddenTabs
        let _ = InterfaceSettings.hideTabTitles
        let _ = InterfaceSettings.wideTabBar
        let _ = InterfaceSettings.hideTabBar
        let _ = InterfaceSettings.tabBarHeightOffset
        let _ = InterfaceSettings.tabBarBottomOffset

        let _ = InterfaceSettings.inputBarGeometry
        let _ = InterfaceSettings.characterCounter
        let _ = InterfaceSettings.formattingToolbar
        let _ = InterfaceSettings.autoFormatting
        let _ = InterfaceSettings.autoFormattingStyle
        let _ = InterfaceSettings.emojiTabFirst
        let _ = InterfaceSettings.standardEmojiFirst

        let _ = InterfaceSettings.typingAnimation
        let _ = InterfaceSettings.typingAnimationPreset
        let _ = InterfaceSettings.typingAnimationIntensity
        let _ = InterfaceSettings.typingAnimationSpeed
        let _ = InterfaceSettings.typingAnimationScale
        let _ = InterfaceSettings.typingAnimationOffset
        let _ = InterfaceSettings.typingAnimationGlow

        let _ = InterfaceSettings.bindButtons
        let _ = InterfaceSettings.bindButtonsHidden
        let _ = InterfaceSettings.bindButtonsPositions
        let _ = InterfaceSettings.bindButtonsWidth
        let _ = InterfaceSettings.bindButtonsHeight

        let _ = InterfaceSettings.customReactions
        let _ = InterfaceSettings.customReactionsList
        let _ = InterfaceSettings.customReactionsAppendStandard

        let _ = InterfaceSettings.iconPacks

        let _ = InterfaceSettings.islandBadge
        let _ = InterfaceSettings.islandBadgeSelection

        let _ = InterfaceSettings.hiddenSettingsItems
        let _ = InterfaceSettings.settingsItemsOrder
        let _ = InterfaceSettings.settingsShortcuts
    }
}
