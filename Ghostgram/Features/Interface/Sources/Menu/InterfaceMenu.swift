import Foundation
import UIKit
import Display
import TelegramPresentationData
import AccountContext
import SettingsUI
import GGCore
import GGSettingsUI
import GGFeaturesShared

/// The zone's part of the menu: «Оформление › Список чатов / Панели / Иконки» and the Settings
/// half of «Профиль и Настройки». Every setting has one row; every row applies at once except the
/// app icon (iOS asks itself) — nothing here restarts the app.
enum InterfaceMenu {
    private static let chatListStories = GGMenuSectionID("appearance.chatList.stories")
    private static let chatListPreviews = GGMenuSectionID("appearance.chatList.previews")
    private static let chatListAvatars = GGMenuSectionID("appearance.chatList.avatars")
    private static let chatListFolders = GGMenuSectionID("appearance.chatList.folders")
    private static let panelsTabBarPreview = GGMenuSectionID("appearance.panels.tabBarPreview")
    private static let panelsTabBar = GGMenuSectionID("appearance.panels.tabBar")
    private static let panelsInput = GGMenuSectionID("appearance.panels.input")
    private static let panelsInputPreview = GGMenuSectionID("appearance.panels.inputPreview")
    private static let panelsTyping = GGMenuSectionID("appearance.panels.typing")
    private static let panelsButtons = GGMenuSectionID("appearance.panels.buttons")
    private static let panelsReactions = GGMenuSectionID("appearance.panels.reactions")
    private static let iconsBadge = GGMenuSectionID("appearance.icons.badge")
    private static let settingsTab = GGMenuSectionID("appearance.profileSettings.settingsTab")

    static func register() {
        InterfaceMenu.registerChatList()
        InterfaceMenu.registerPanels()
        InterfaceMenu.registerIcons()
        InterfaceMenu.registerSettingsTab()
    }

    private static func percent(_ value: Double) -> String {
        return GGStrings.Interface.Menu.percent(value: "\(Int(value.rounded()))")
    }

    private static func points(_ value: Double) -> String {
        return GGStrings.Interface.Menu.points(value: "\(Int(value.rounded()))")
    }

    private static func options(_ values: [String], title: @escaping (String) -> String) -> [GGMenuChoiceOption] {
        return values.map { value in
            return GGMenuChoiceOption(value: value, title: { title(value) })
        }
    }

    // MARK: Список чатов

    private static func registerChatList() {
        let tab = GGMenuTabID.appearanceChatList
        let main = GGMenuSectionID.main(of: tab)

        GGMenuRegistry.register(GGMenuRow(
            id: "interface.chatList.preview",
            section: .preview(of: tab),
            order: 100,
            title: { "" },
            kind: .preview(.miniChatList(GGMiniChatListConfiguration(scope: "interface.chatList", height: 228.0, rows: { _ in
                return GGPreviewChatListRow.samples()
            })))
        ))
        // Hidden previews show in the mini list the way they do in the real one.
        GGPreviewModifiers.registerChatListModifier(id: "interface.hidePreview", order: 100, { rows, context in
            guard context.previewScope == "interface.chatList", InterfaceSettings.hidePreview.value, InterfaceSettings.hidePreviewScope.value == "all" else {
                return
            }
            for index in rows.indices {
                rows[index].text = ""
                rows[index].authorName = nil
            }
        })

        let toggles: [(String, Int, () -> String, (() -> String)?, GGSetting<Bool>, () -> [String])] = [
            ("interface.chatList.compact", 200, { GGStrings.Interface.Menu.compactList }, { GGStrings.Interface.Menu.compactListInfo }, InterfaceSettings.compactList, { [] }),
            ("interface.chatList.senderAvatars", 600, { GGStrings.Interface.Menu.senderAvatars }, { GGStrings.Interface.Menu.senderAvatarsInfo }, InterfaceSettings.senderAvatars, { [] }),
            ("interface.chatList.hideEmojiStatus", 700, { GGStrings.Interface.Menu.hideEmojiStatus }, nil, InterfaceSettings.hideEmojiStatus, { [] }),
            ("interface.chatList.hideSearchField", 800, { GGStrings.Interface.Menu.hideSearchField }, { GGStrings.Interface.Menu.hideSearchFieldInfo }, InterfaceSettings.hideSearchField, { [] }),
            ("interface.chatList.searchById", 900, { GGStrings.Interface.Menu.searchById }, { GGStrings.Interface.Menu.searchByIdInfo }, InterfaceSettings.searchById, { [] }),
            ("interface.chatList.hideConnectionText", 1000, { GGStrings.Interface.Menu.hideConnectionText }, { GGStrings.Interface.Menu.hideConnectionTextInfo }, InterfaceSettings.hideConnectionText, { [] }),
            ("interface.chatList.hideProxySponsor", 1200, { GGStrings.Interface.Menu.hideProxySponsor }, { GGStrings.Interface.Menu.hideProxySponsorInfo }, InterfaceSettings.hideProxySponsor, { [] })
        ]
        for (id, order, title, subtitle, setting, keywords) in toggles {
            GGMenuRegistry.register(GGMenuRow(id: id, section: main, order: order, title: title, subtitle: subtitle, kind: .toggle(.global(setting)), searchKeywords: keywords))
        }
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.previewLines", section: main, order: 300, title: { GGStrings.Interface.Menu.previewLines }, kind: .discreteChoice(.global(InterfaceSettings.previewLines), options: InterfaceMenu.options(["1", "2", "3"], title: { GGStrings.Interface.Menu.number(value: $0) }))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.rowScale", section: main, order: 400, title: { GGStrings.Interface.Menu.rowScale }, kind: .choice(.global(InterfaceSettings.rowScale), options: InterfaceMenu.options(GGChatListFeature.rowScaleOptions, title: { InterfaceMenu.percent(Double($0) ?? 100.0) }))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.avatarScale", section: main, order: 500, title: { GGStrings.Interface.Menu.avatarScale }, kind: .choice(.global(InterfaceSettings.avatarScale), options: InterfaceMenu.options(GGChatListFeature.avatarScaleOptions, title: { InterfaceMenu.percent(Double($0) ?? 100.0) }))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.swipeActions", section: main, order: 1100, title: { GGStrings.Interface.Menu.swipeActions }, kind: .choice(.global(InterfaceSettings.swipeActions), options: [
            GGMenuChoiceOption(value: "all", title: { GGStrings.Interface.Menu.swipeAll }),
            GGMenuChoiceOption(value: "noDelete", title: { GGStrings.Interface.Menu.swipeNoDelete }),
            GGMenuChoiceOption(value: "none", title: { GGStrings.Interface.Menu.swipeNone })
        ])))

        // Stories
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.chatListStories, screen: .tab(tab), order: 300, header: { GGStrings.Interface.Menu.storiesHeader }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.hideStories", section: InterfaceMenu.chatListStories, order: 100, title: { GGStrings.Interface.Menu.hideStories }, kind: .toggle(.global(InterfaceSettings.hideStories))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.hideStoryRings", section: InterfaceMenu.chatListStories, order: 200, title: { GGStrings.Interface.Menu.hideStoryRings }, kind: .toggle(.global(InterfaceSettings.hideStoryRings))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.disableStoryCameraSwipe", section: InterfaceMenu.chatListStories, order: 300, title: { GGStrings.Interface.Menu.disableStoryCameraSwipe }, subtitle: { GGStrings.Interface.Menu.disableStoryCameraSwipeInfo }, kind: .toggle(.global(InterfaceSettings.disableStoryCameraSwipe))))
        let ringColors: [(String, () -> String)] = [
            ("", { GGStrings.Interface.Menu.colorTheme }),
            ("3390EC", { GGStrings.Interface.Menu.colorBlue }),
            ("34C759", { GGStrings.Interface.Menu.colorGreen }),
            ("FF9500", { GGStrings.Interface.Menu.colorOrange }),
            ("FF2D55", { GGStrings.Interface.Menu.colorPink }),
            ("AF52DE", { GGStrings.Interface.Menu.colorPurple }),
            ("FFFFFF", { GGStrings.Interface.Menu.colorWhite }),
            ("8E8E93", { GGStrings.Interface.Menu.colorGray })
        ]
        GGMenuRegistry.register(GGMenuRow(id: "interface.avatars.storyRingColor", section: InterfaceMenu.chatListStories, order: 400, title: { GGStrings.Interface.Menu.storyRingColor }, kind: .choice(.global(InterfaceSettings.storyRingColor), options: ringColors.map { GGMenuChoiceOption(value: $0.0, title: $0.1) }), isVisible: { _ in !InterfaceSettings.hideStoryRings.value }))

        // Message previews
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.chatListPreviews, screen: .tab(tab), order: 400, header: { GGStrings.Interface.Menu.previewsHeader }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.hidePreview", section: InterfaceMenu.chatListPreviews, order: 100, title: { GGStrings.Interface.Menu.hidePreview }, subtitle: { GGStrings.Interface.Menu.hidePreviewInfo }, kind: .toggle(.global(InterfaceSettings.hidePreview))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.hidePreviewScope", section: InterfaceMenu.chatListPreviews, order: 200, title: { GGStrings.Interface.Menu.hidePreviewScope }, kind: .choice(.global(InterfaceSettings.hidePreviewScope), options: [
            GGMenuChoiceOption(value: "all", title: { GGStrings.Interface.Menu.scopeAll }),
            GGMenuChoiceOption(value: "selected", title: { GGStrings.Interface.Menu.scopeSelected })
        ]), isVisible: { _ in InterfaceSettings.hidePreview.value }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.chatList.hidePreviewPeers", section: InterfaceMenu.chatListPreviews, order: 300, title: { GGStrings.Interface.ChatList.hiddenPreviewChats }, kind: .action({ menu in
            menu.push(GGHiddenPreviewScreens.makeScreen(context: menu.context))
        }), isVisible: { _ in InterfaceSettings.hidePreview.value && InterfaceSettings.hidePreviewScope.value == "selected" }, label: { menu in
            let count = InterfaceSettings.hidePreviewPeers.value(for: menu.accountID).count
            return count == 0 ? nil : "\(count)"
        }))

        // Avatars
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.chatListAvatars, screen: .tab(tab), order: 500, header: { GGStrings.Interface.Menu.avatarsHeader }, footer: { _ in GGStrings.Interface.Menu.avatarsFooter }))
        // One row since 2026-10-27: the circle is the first stop, the square the last.
        GGMenuRegistry.register(GGMenuRow(id: "interface.avatars.corners", section: InterfaceMenu.chatListAvatars, order: 100, title: { GGStrings.Interface.Menu.squareness }, kind: .discreteChoice(.global(InterfaceSettings.avatarCorners), options: [
            GGMenuChoiceOption(value: GGAvatarCorners.round, title: { GGStrings.Interface.Menu.squarenessNone }),
            GGMenuChoiceOption(value: "25", title: { GGStrings.Interface.Menu.squarenessSlight }),
            GGMenuChoiceOption(value: "50", title: { GGStrings.Interface.Menu.squarenessMedium }),
            GGMenuChoiceOption(value: "75", title: { GGStrings.Interface.Menu.squarenessStrong }),
            GGMenuChoiceOption(value: "100", title: { GGStrings.Interface.Menu.squarenessFull })
        ]), searchKeywords: { [GGStrings.Interface.Menu.squarenessKeywords] }))
        // Forums are drawn as circles with any corner setting, so the switch is always shown.
        GGMenuRegistry.register(GGMenuRow(id: "interface.avatars.roundInForums", section: InterfaceMenu.chatListAvatars, order: 200, title: { GGStrings.Interface.Menu.roundInForums }, kind: .toggle(.global(InterfaceSettings.roundAvatarsInForums))))

        // Folders
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.chatListFolders, screen: .tab(tab), order: 600, header: { GGStrings.Interface.Menu.foldersHeader }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.folders.hideAllChats", section: InterfaceMenu.chatListFolders, order: 100, title: { GGStrings.Interface.Menu.hideAllChats }, subtitle: { GGStrings.Interface.Menu.hideAllChatsInfo }, kind: .toggle(.global(InterfaceSettings.hideAllChats))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.folders.allChatsTitle", section: InterfaceMenu.chatListFolders, order: 200, title: { GGStrings.Interface.Menu.allChatsTitle }, kind: .choice(.global(InterfaceSettings.allChatsTitle), options: [
            GGMenuChoiceOption(value: "default", title: { GGStrings.Interface.Menu.allChatsTitleDefault }),
            GGMenuChoiceOption(value: "long", title: { GGStrings.Interface.Menu.allChatsTitleLong })
        ]), isVisible: { _ in !InterfaceSettings.hideAllChats.value }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.folders.compactTabs", section: InterfaceMenu.chatListFolders, order: 300, title: { GGStrings.Interface.Menu.compactFolderTabs }, kind: .toggle(.global(InterfaceSettings.compactFolderTabs))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.folders.atBottom", section: InterfaceMenu.chatListFolders, order: 400, title: { GGStrings.Interface.Menu.foldersAtBottom }, subtitle: { GGStrings.Interface.Menu.foldersAtBottomInfo }, kind: .toggle(.global(InterfaceSettings.foldersAtBottom))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.folders.barHeightOffset", section: InterfaceMenu.chatListFolders, order: 500, title: { GGStrings.Interface.Menu.folderBarHeight }, kind: .slider(.global(InterfaceSettings.folderBarHeightOffset), range: 0.0 ... 24.0, step: 1.0, format: InterfaceMenu.points)))
        GGMenuRegistry.register(GGMenuRow(id: "interface.folders.rememberLast", section: InterfaceMenu.chatListFolders, order: 600, title: { GGStrings.Interface.Menu.rememberLastFolder }, subtitle: { GGStrings.Interface.Menu.rememberLastFolderInfo }, kind: .toggle(.global(InterfaceSettings.rememberLastFolder))))
    }

    // MARK: Панели

    private static func registerPanels() {
        let tab = GGMenuTabID.appearancePanels

        // Two previews, each under its section's header and over its rows (owner, builds 188–189): the
        // tab bar, the input field.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.panelsTabBarPreview, screen: .tab(tab), order: 240, header: { GGStrings.Interface.Menu.tabBarHeader }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.panels.preview", section: InterfaceMenu.panelsTabBarPreview, order: 100, title: { "" }, kind: .preview(.custom(height: GGTabBarPreviewView.height, make: { _ in
            return GGTabBarPreviewView(frame: CGRect())
        }))))

        let main = InterfaceMenu.panelsTabBar
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: main, screen: .tab(tab), order: 250))
        GGMenuRegistry.register(GGMenuRow(id: "interface.tabBar.organizer", section: main, order: 100, title: { GGStrings.Interface.TabBar.organizerTitle }, subtitle: { GGStrings.Interface.Menu.tabOrganizerInfo }, kind: .action({ menu in
            menu.push(GGTabBarScreens.makeOrganizer(context: menu.context))
        }), searchKeywords: { [GGStrings.Interface.Menu.tabKeywords] }, label: { _ in
            let changed = !InterfaceSettings.tabOrder.isDefault || !InterfaceSettings.tabTitles.isDefault || !InterfaceSettings.hiddenTabs.isDefault
            return changed ? GGStrings.Interface.Menu.changedLabel : nil
        }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.tabBar.hideTitles", section: main, order: 200, title: { GGStrings.Interface.Menu.hideTabTitles }, subtitle: { GGStrings.Interface.Menu.hideTabTitlesInfo }, kind: .toggle(.global(InterfaceSettings.hideTabTitles))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.tabBar.wide", section: main, order: 300, title: { GGStrings.Interface.Menu.wideTabBar }, kind: .toggle(.global(InterfaceSettings.wideTabBar))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.tabBar.hide", section: main, order: 400, title: { GGStrings.Interface.Menu.hideTabBar }, subtitle: { GGStrings.Interface.Menu.hideTabBarInfo }, kind: .toggle(.global(InterfaceSettings.hideTabBar))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.tabBar.heightOffset", section: main, order: 500, title: { GGStrings.Interface.Menu.tabBarHeight }, kind: .slider(.global(InterfaceSettings.tabBarHeightOffset), range: GGTabBarLayout.heightOffsetRange, step: 1.0, format: InterfaceMenu.points), isVisible: { _ in !InterfaceSettings.hideTabBar.value }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.tabBar.bottomOffset", section: main, order: 600, title: { GGStrings.Interface.Menu.tabBarLift }, kind: .slider(.global(InterfaceSettings.tabBarBottomOffset), range: GGTabBarLayout.bottomOffsetRange, step: 1.0, format: InterfaceMenu.points), isVisible: { _ in !InterfaceSettings.hideTabBar.value }))

        // Input field
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.panelsInputPreview, screen: .tab(tab), order: 290, header: { GGStrings.Interface.Menu.inputHeader }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.panels.inputPreview", section: InterfaceMenu.panelsInputPreview, order: 100, title: { "" }, kind: .preview(.custom(height: GGInputBarPreviewView.height, make: { _ in
            return GGInputBarPreviewView(frame: CGRect())
        }))))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.panelsInput, screen: .tab(tab), order: 300))
        GGMenuRegistry.register(GGMenuRow(id: "interface.inputBar.editor", section: InterfaceMenu.panelsInput, order: 100, title: { GGStrings.Interface.Menu.inputEditor }, subtitle: { GGStrings.Interface.Menu.inputEditorInfo }, kind: .action({ menu in
            GGInputBarEditor.start(context: menu.context, navigationController: menu.navigationController)
        }), label: { _ in
            return InterfaceSettings.inputBarGeometry.isDefault ? nil : GGStrings.Interface.Menu.changedLabel
        }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.inputBar.characterCounter", section: InterfaceMenu.panelsInput, order: 200, title: { GGStrings.Interface.Menu.characterCounter }, subtitle: { GGStrings.Interface.Menu.characterCounterInfo }, kind: .toggle(.global(InterfaceSettings.characterCounter))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.inputBar.formattingToolbar", section: InterfaceMenu.panelsInput, order: 300, title: { GGStrings.Interface.Menu.formattingToolbar }, subtitle: { GGStrings.Interface.Menu.formattingToolbarInfo }, kind: .toggle(.global(InterfaceSettings.formattingToolbar))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.inputBar.autoFormatting", section: InterfaceMenu.panelsInput, order: 400, title: { GGStrings.Interface.Menu.autoFormatting }, subtitle: { GGStrings.Interface.Menu.autoFormattingInfo }, kind: .toggle(.global(InterfaceSettings.autoFormatting))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.inputBar.autoFormattingStyle", section: InterfaceMenu.panelsInput, order: 500, title: { GGStrings.Interface.Menu.autoFormattingStyle }, kind: .choice(.global(InterfaceSettings.autoFormattingStyle), options: InterfaceMenu.options(GGAutoFormatting.styles, title: GGAutoFormatting.title)), isVisible: { _ in InterfaceSettings.autoFormatting.value }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.inputBar.emojiTabFirst", section: InterfaceMenu.panelsInput, order: 600, title: { GGStrings.Interface.Menu.emojiTabFirst }, kind: .toggle(.global(InterfaceSettings.emojiTabFirst))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.inputBar.standardEmojiFirst", section: InterfaceMenu.panelsInput, order: 700, title: { GGStrings.Interface.Menu.standardEmojiFirst }, kind: .toggle(.global(InterfaceSettings.standardEmojiFirst))))

        // Typing animation
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.panelsTyping, screen: .tab(tab), order: 400, header: { GGStrings.Interface.Menu.typingHeader }, footer: { _ in GGStrings.Interface.Menu.typingFooter }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.typingAnimation.enabled", section: InterfaceMenu.panelsTyping, order: 100, title: { GGStrings.Interface.Menu.typingAnimation }, kind: .toggle(.global(InterfaceSettings.typingAnimation))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.typingAnimation.preset", section: InterfaceMenu.panelsTyping, order: 200, title: { GGStrings.Interface.Menu.typingPreset }, kind: .choice(.global(InterfaceSettings.typingAnimationPreset), options: InterfaceMenu.options(GGTypingAnimationParameters.presets, title: InterfaceMenu.presetTitle)), isVisible: { _ in InterfaceSettings.typingAnimation.value }))
        let isCustom: (GGMenuContext) -> Bool = { _ in InterfaceSettings.typingAnimation.value && InterfaceSettings.typingAnimationPreset.value == "custom" }
        let sliders: [(String, Int, () -> String, GGSetting<Double>)] = [
            ("interface.typingAnimation.intensity", 300, { GGStrings.Interface.Menu.typingIntensity }, InterfaceSettings.typingAnimationIntensity),
            ("interface.typingAnimation.speed", 400, { GGStrings.Interface.Menu.typingSpeed }, InterfaceSettings.typingAnimationSpeed),
            ("interface.typingAnimation.scale", 500, { GGStrings.Interface.Menu.typingScale }, InterfaceSettings.typingAnimationScale),
            ("interface.typingAnimation.offset", 600, { GGStrings.Interface.Menu.typingOffset }, InterfaceSettings.typingAnimationOffset),
            ("interface.typingAnimation.glow", 700, { GGStrings.Interface.Menu.typingGlow }, InterfaceSettings.typingAnimationGlow)
        ]
        for (id, order, title, setting) in sliders {
            GGMenuRegistry.register(GGMenuRow(id: id, section: InterfaceMenu.panelsTyping, order: order, title: title, kind: .slider(.global(setting), range: 0.0 ... 100.0, step: 5.0, format: InterfaceMenu.percent), isVisible: isCustom))
        }

        // Quick buttons
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.panelsButtons, screen: .tab(tab), order: 500, header: { GGStrings.Interface.Menu.buttonsHeader }, footer: { _ in GGStrings.Interface.Menu.buttonsFooter }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.bindButtons.enabled", section: InterfaceMenu.panelsButtons, order: 100, title: { GGStrings.Interface.Menu.bindButtons }, kind: .toggle(.global(InterfaceSettings.bindButtons))))
        // The buttons on a full chat preview: dragged into place, width and height by sliders.
        GGMenuRegistry.register(GGMenuRow(id: "interface.bindButtons.layout", section: InterfaceMenu.panelsButtons, order: 150, title: { GGStrings.Interface.Binds.editorTitle }, kind: .action({ menu in
            menu.push(GGQuickButtonsEditorController(context: menu.context))
        }), isVisible: { _ in InterfaceSettings.bindButtons.value }, label: { _ in
            let size = GGQuickButtonsLayout.size()
            let defaultSide = CGFloat(GGQuickButtonsLayout.defaultSide)
            if size.width != defaultSide || size.height != defaultSide {
                return "\(Int(size.width))×\(Int(size.height))"
            }
            return InterfaceSettings.bindButtonsPositions.value.isEmpty ? nil : GGStrings.Interface.Binds.customLayout
        }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.bindButtons.hidden", section: InterfaceMenu.panelsButtons, order: 200, title: { GGStrings.Interface.Binds.buttonsTitle }, kind: .action({ menu in
            menu.push(GGQuickButtonScreens.makeScreen(context: menu.context))
        }), isVisible: { _ in InterfaceSettings.bindButtons.value }, label: { _ in
            let all = GGQuickActions.all.map { $0.id }
            let hidden = Set(InterfaceSettings.bindButtonsHidden.value)
            return "\(all.filter { !hidden.contains($0) }.count)/\(all.count)"
        }))

        // Reactions
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.panelsReactions, screen: .tab(tab), order: 600, header: { GGStrings.Interface.Menu.reactionsHeader }, footer: { _ in GGStrings.Interface.Menu.reactionsFooter }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.customReactions.enabled", section: InterfaceMenu.panelsReactions, order: 100, title: { GGStrings.Interface.Menu.customReactions }, kind: .toggle(.global(InterfaceSettings.customReactions))))
        GGMenuRegistry.register(GGMenuRow(id: "interface.customReactions.list", section: InterfaceMenu.panelsReactions, order: 200, title: { GGStrings.Interface.Reactions.editorTitle }, kind: .action({ menu in
            menu.push(GGReactionScreens.makeEditor(context: menu.context))
        }), isVisible: { _ in InterfaceSettings.customReactions.value }, label: { _ in
            return "\(InterfaceSettings.customReactionsList.value.count)"
        }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.customReactions.appendStandard", section: InterfaceMenu.panelsReactions, order: 300, title: { GGStrings.Interface.Menu.appendStandardReactions }, kind: .toggle(.global(InterfaceSettings.customReactionsAppendStandard)), isVisible: { _ in InterfaceSettings.customReactions.value }))
    }

    private static func presetTitle(_ preset: String) -> String {
        switch preset {
        case "pulse":
            return GGStrings.Interface.Menu.presetPulse
        case "wave":
            return GGStrings.Interface.Menu.presetWave
        case "panelWave":
            return GGStrings.Interface.Menu.presetPanelWave
        case "neon":
            return GGStrings.Interface.Menu.presetNeon
        case "shake":
            return GGStrings.Interface.Menu.presetShake
        default:
            return GGStrings.Interface.Menu.presetCustom
        }
    }

    // MARK: Иконки

    private static func registerIcons() {
        let tab = GGMenuTabID.appearanceIcons
        let main = GGMenuSectionID.main(of: tab)

        GGMenuRegistry.register(GGMenuRow(id: "interface.icons.preview", section: .preview(of: tab), order: 100, title: { "" }, kind: .preview(.custom(height: 176.0, make: { _ in
            return GGIconsPreviewView(frame: CGRect())
        }))))

        // No «Иконка приложения» row: Ghostgram ships one app icon, the ghost (the duck was removed by
        // the owner, 2026-10-28), so there is nothing to choose.
        GGMenuRegistry.register(GGMenuRow(id: "interface.iconPacks", section: main, order: 200, title: { GGStrings.Interface.IconPacks.title }, subtitle: { GGStrings.Interface.Menu.iconPacksInfo }, icon: .bundle("Chat/Context Menu/Apps"), kind: .action({ menu in
            menu.push(GGIconPackScreens.makeListScreen(context: menu.context))
        }), searchKeywords: { [GGStrings.Interface.Menu.iconPacksKeywords] }, label: { _ in
            let count = InterfaceSettings.iconPacks.value.count
            return count == 0 ? GGStrings.Interface.Menu.offLabel : "\(count)"
        }))

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.iconsBadge, screen: .tab(tab), order: 300, header: { GGStrings.Interface.Menu.badgeHeader }, footer: { _ in
            return GGIslandBadgeGeometry.isSupported ? GGStrings.Interface.Menu.badgeFooter : GGStrings.Interface.Menu.badgeUnsupported
        }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.enabled", section: InterfaceMenu.iconsBadge, order: 100, title: { GGStrings.Interface.Menu.islandBadge }, kind: .toggle(.global(InterfaceSettings.islandBadge)), searchKeywords: { [GGStrings.Interface.Menu.badgeKeywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.selection", section: InterfaceMenu.iconsBadge, order: 200, title: { GGStrings.Interface.Badge.galleryTitle }, kind: .action({ menu in
            menu.push(GGBadgeGallery.makeScreen(context: menu.context))
        }), label: { _ in
            let selection = InterfaceSettings.islandBadgeSelection.value
            return GGBadgeStore.isValidId(selection) ? GGStrings.Interface.Menu.ownBadgeLabel : GGStrings.Interface.Badge.bundledName
        }))
    }

    // MARK: Вкладка «Настройки»

    private static func registerSettingsTab() {
        let tab = GGMenuTabID.appearanceProfileSettings
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: InterfaceMenu.settingsTab, screen: .tab(tab), order: 500, header: { GGStrings.Interface.Menu.settingsTabHeader }, footer: { _ in GGStrings.Interface.Menu.settingsTabFooter }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.settingsTab.items", section: InterfaceMenu.settingsTab, order: 100, title: { GGStrings.Interface.SettingsTab.itemsTitle }, subtitle: { GGStrings.Interface.Menu.settingsItemsInfo }, kind: .action({ menu in
            menu.push(GGSettingsTabScreens.makeScreen(context: menu.context))
        }), searchKeywords: { [GGStrings.Interface.Menu.settingsItemsKeywords] }, label: { _ in
            let count = InterfaceSettings.hiddenSettingsItems.value.count
            return count == 0 ? nil : GGStrings.Interface.Menu.hiddenCount(count: count)
        }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.settingsTab.shortcuts", section: InterfaceMenu.settingsTab, order: 200, title: { GGStrings.Interface.Shortcuts.title }, subtitle: { GGStrings.Interface.Menu.shortcutsInfo }, kind: .action({ menu in
            menu.push(GGShortcutScreens.makeScreen(context: menu.context))
        }), searchKeywords: { [GGStrings.Interface.Menu.shortcutsKeywords] }, label: { menu in
            let count = InterfaceSettings.settingsShortcuts.value(for: menu.accountID).count
            return count == 0 ? nil : "\(count)"
        }))
    }
}
