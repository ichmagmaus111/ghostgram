import Foundation
import UIKit
import Display
import ItemListUI
import TelegramPresentationData
import GGCore
import GGSettingsUI
import GGAppearanceSettings

/// The appearance rows of the Ghostgram menu (PLAN §2.4): tabs «Сообщения», «Тема и фон» and the
/// «Профиль» part of «Профиль и Настройки». Every setting has exactly one row; titles are computed
/// at display time; sliders write once, on release (the preview follows the finger).
enum GGAppearanceMenu {
    // Sections of «Сообщения».
    static let messagesBubbles = GGMenuSectionID("appearance.messages.bubbles")
    static let messagesChecks = GGMenuSectionID("appearance.messages.checkmarks")
    static let messagesStickers = GGMenuSectionID("appearance.messages.stickers")
    static let messagesInterface = GGMenuSectionID("appearance.messages.interface")
    static let messagesTopBar = GGMenuSectionID("appearance.messages.topBar")
    // Sections of «Тема и фон».
    static let themeEdges = GGMenuSectionID("appearance.themeBackground.edges")
    static let themeBackground = GGMenuSectionID("appearance.themeBackground.chatBackground")
    static let themeSnow = GGMenuSectionID("appearance.themeBackground.snow")
    // Sections of «Профиль и Настройки» (the «Настройки» part belongs to the interface feature).
    static let profileInfo = GGMenuSectionID("appearance.profileSettings.profile")
    static let profileBackground = GGMenuSectionID("appearance.profileSettings.profileBackground")
    // The font tab.
    static let fontTab = GGMenuTabID("appearance.font")
    static let fontSystem = GGMenuSectionID("appearance.font.systemDesigns")
    static let fontFamilies = GGMenuSectionID("appearance.font.families")
    static let fontCustom = GGMenuSectionID("appearance.font.custom")

    static func register() {
        GGAppearanceMenu.registerMessages()
        GGAppearanceMenu.registerFont()
        GGAppearanceMenu.registerTheme()
        GGAppearanceMenu.registerProfile()
    }

    // MARK: Formats

    static func percent(_ value: Double) -> String {
        return GGStrings.Appearance.Common.percent(value: "\(Int(value.rounded()))")
    }

    static func points(_ value: Double) -> String {
        return GGStrings.Appearance.Common.points(value: "\(Int(value.rounded()))")
    }

    static func colorLabel(_ setting: GGSetting<String>) -> String {
        if let rgb = ggAppearanceParseColor(setting.value) {
            return "#" + ggAppearanceColorString(rgb)
        }
        return GGStrings.Appearance.Common.automatic
    }

    // MARK: «Сообщения»

    private static func registerMessages() {
        let tab = GGMenuTabID.appearanceMessages

        GGMenuRegistry.register(GGMenuRow(
            id: "appearance.messages.preview",
            section: .preview(of: tab),
            order: 100,
            title: { "" },
            // Live: bubbles follow the sliders of the bubble editor while dragged (U6); the top bar
            // follows «Скрыть в шапке чата» (U7).
            kind: .preview(.miniChat(GGAppearancePreview.configuration(scope: "appearance.messages", overlays: false, content: { _ in
                var content = GGAppearancePreview.sampleContent()
                if content.messages.count > 1 {
                    // Shows the «edited» label, the time and the checkmarks the options change.
                    content.messages[1].isEdited = true
                }
                return content
            })))
        ))

        // Font: its own tab with samples.
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(
            id: GGAppearanceMenu.fontTab,
            parent: .tab(tab),
            title: { GGStrings.Appearance.Font.title },
            topView: GGMenuTopView(content: .emoji("🔤"), text: { GGStrings.Appearance.Font.info }),
            searchKeywords: { [GGStrings.Appearance.Font.keywords] }
        ), linkIn: .main(of: tab), order: 100, subtitle: { GGStrings.Appearance.Font.subtitle }, icon: .bundle("Chat/Context Menu/FormatText"), label: { _ in
            return GGFonts.selectedDisplayName
        })

        // Bubbles.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.messagesBubbles, screen: .tab(tab), order: 300, header: { GGStrings.Appearance.Bubbles.header }, footer: { _ in GGStrings.Appearance.Bubbles.footer }))
        let editorOn: (GGMenuContext) -> Bool = { _ in GGAppearanceSettings.bubbleEditor.value }
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.editor", section: GGAppearanceMenu.messagesBubbles, order: 100, title: { GGStrings.Appearance.Bubbles.editor }, subtitle: { GGStrings.Appearance.Bubbles.editorInfo }, kind: .toggle(.global(GGAppearanceSettings.bubbleEditor)), searchKeywords: { [GGStrings.Appearance.Bubbles.keywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.incomingRadius", section: GGAppearanceMenu.messagesBubbles, order: 200, title: { GGStrings.Appearance.Bubbles.incomingRadius }, kind: .slider(.global(GGAppearanceSettings.bubbleIncomingRadius), range: 0.0 ... 16.0, step: 1.0, format: GGAppearanceMenu.points), isVisible: editorOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.outgoingRadius", section: GGAppearanceMenu.messagesBubbles, order: 300, title: { GGStrings.Appearance.Bubbles.outgoingRadius }, kind: .slider(.global(GGAppearanceSettings.bubbleOutgoingRadius), range: 0.0 ... 16.0, step: 1.0, format: GGAppearanceMenu.points), isVisible: editorOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.padding", section: GGAppearanceMenu.messagesBubbles, order: 400, title: { GGStrings.Appearance.Bubbles.padding }, kind: .slider(.global(GGAppearanceSettings.bubblePadding), range: 0.0 ... 24.0, step: 1.0, format: GGAppearanceMenu.points), isVisible: editorOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.width", section: GGAppearanceMenu.messagesBubbles, order: 500, title: { GGStrings.Appearance.Bubbles.width }, kind: .slider(.global(GGAppearanceSettings.bubbleWidth), range: 40.0 ... 100.0, step: 5.0, format: GGAppearanceMenu.percent), isVisible: editorOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.backgroundOpacity", section: GGAppearanceMenu.messagesBubbles, order: 600, title: { GGStrings.Appearance.Bubbles.backgroundOpacity }, kind: .slider(.global(GGAppearanceSettings.bubbleBackgroundOpacity), range: 0.0 ... 100.0, step: 5.0, format: GGAppearanceMenu.percent), isVisible: editorOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.outlineOpacity", section: GGAppearanceMenu.messagesBubbles, order: 700, title: { GGStrings.Appearance.Bubbles.outlineOpacity }, kind: .slider(.global(GGAppearanceSettings.bubbleOutlineOpacity), range: 0.0 ... 100.0, step: 5.0, format: GGAppearanceMenu.percent), isVisible: editorOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.reset", section: GGAppearanceMenu.messagesBubbles, order: 800, title: { GGStrings.Appearance.Bubbles.reset }, kind: .action({ _ in
            GGAppearanceSettings.bubbleIncomingRadius.reset()
            GGAppearanceSettings.bubbleOutgoingRadius.reset()
            GGAppearanceSettings.bubblePadding.reset()
            GGAppearanceSettings.bubbleWidth.reset()
            GGAppearanceSettings.bubbleBackgroundOpacity.reset()
            GGAppearanceSettings.bubbleOutlineOpacity.reset()
        }), isVisible: editorOn, isDestructive: true))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.bubbles.hideTails", section: GGAppearanceMenu.messagesBubbles, order: 900, title: { GGStrings.Appearance.Bubbles.hideTails }, subtitle: { GGStrings.Appearance.Bubbles.hideTailsInfo }, kind: .toggle(.global(GGAppearanceSettings.bubbleHideTails))))

        // Checkmarks.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.messagesChecks, screen: .tab(tab), order: 400, header: { GGStrings.Appearance.Checkmarks.header }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.checkmarks.readColor", section: GGAppearanceMenu.messagesChecks, order: 100, title: { GGStrings.Appearance.Checkmarks.readColor }, kind: .action({ context in
            GGColorPicker.present(context: context, setting: GGAppearanceSettings.readCheckColor, fallback: UIColor(rgb: 0x19c700))
        }), searchKeywords: { [GGStrings.Appearance.Checkmarks.keywords] }, label: { _ in GGAppearanceMenu.colorLabel(GGAppearanceSettings.readCheckColor) }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.checkmarks.unreadSameAsRead", section: GGAppearanceMenu.messagesChecks, order: 200, title: { GGStrings.Appearance.Checkmarks.unreadSameAsRead }, kind: .toggle(.global(GGAppearanceSettings.unreadCheckSameAsRead)), isVisible: { _ in !GGAppearanceSettings.readCheckColor.value.isEmpty }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.checkmarks.unreadColor", section: GGAppearanceMenu.messagesChecks, order: 300, title: { GGStrings.Appearance.Checkmarks.unreadColor }, kind: .action({ context in
            GGColorPicker.present(context: context, setting: GGAppearanceSettings.unreadCheckColor, fallback: UIColor(rgb: 0xa3a3a3))
        }), isVisible: { _ in !GGAppearanceSettings.unreadCheckSameAsRead.value || GGAppearanceSettings.readCheckColor.value.isEmpty }, label: { _ in GGAppearanceMenu.colorLabel(GGAppearanceSettings.unreadCheckColor) }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.checkmarks.inChatList", section: GGAppearanceMenu.messagesChecks, order: 400, title: { GGStrings.Appearance.Checkmarks.inChatList }, kind: .toggle(.global(GGAppearanceSettings.checkColorsInChatList)), isVisible: { _ in !GGAppearanceSettings.readCheckColor.value.isEmpty }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.checkmarks.reset", section: GGAppearanceMenu.messagesChecks, order: 500, title: { GGStrings.Appearance.Checkmarks.reset }, kind: .action({ _ in
            GGAppearanceSettings.readCheckColor.reset()
            GGAppearanceSettings.unreadCheckColor.reset()
        }), isVisible: { _ in !GGAppearanceSettings.readCheckColor.value.isEmpty || !GGAppearanceSettings.unreadCheckColor.value.isEmpty }, isDestructive: true))

        // Stickers.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.messagesStickers, screen: .tab(tab), order: 500, header: { GGStrings.Appearance.Stickers.header }))
        // Live: the emoji and the sticker follow the size slider while it is dragged (2026-11-02).
        GGMenuRegistry.register(GGMenuRow(id: "appearance.stickers.preview", section: GGAppearanceMenu.messagesStickers, order: 50, title: { "" }, kind: .preview(.custom(height: GGStickerSizePreviewView.height, make: { _ in
            return GGStickerSizePreviewView(frame: .zero)
        }))))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.stickers.size", section: GGAppearanceMenu.messagesStickers, order: 100, title: { GGStrings.Appearance.Stickers.size }, kind: .slider(.global(GGAppearanceSettings.stickerSize), range: 50.0 ... 200.0, step: 5.0, format: GGAppearanceMenu.percent)))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.stickers.hideTime", section: GGAppearanceMenu.messagesStickers, order: 200, title: { GGStrings.Appearance.Stickers.hideTime }, kind: .toggle(.global(GGAppearanceSettings.stickerHideTime))))

        // Message interface.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.messagesInterface, screen: .tab(tab), order: 600, header: { GGStrings.Appearance.Messages.header }))
        // «Скрыть в сообщениях» (2026-10-27): four switches in one row that opens in place.
        let hiddenInMessages: [(String, () -> String, GGSetting<Bool>)] = [
            ("appearance.messages.hideEdited", { GGStrings.Appearance.Messages.hiddenEdited }, GGAppearanceSettings.hideEdited),
            ("appearance.messages.hideTime", { GGStrings.Appearance.Messages.hiddenTime }, GGAppearanceSettings.hideTime),
            ("appearance.messages.hideViewCounts", { GGStrings.Appearance.Messages.hiddenViewCounts }, GGAppearanceSettings.hideViewCounts),
            ("appearance.messages.hideChannelComments", { GGStrings.Appearance.Messages.hiddenChannelComments }, GGAppearanceSettings.hideChannelComments)
        ]
        GGMenuRegistry.register(GGMenuRow(id: "appearance.messages.hidden", section: GGAppearanceMenu.messagesInterface, order: 100, title: { GGStrings.Appearance.Messages.hidden }, kind: .expandableList(children: GGAppearanceMenu.hiddenChildren(hiddenInMessages, section: GGAppearanceMenu.messagesInterface), summary: GGAppearanceMenu.hiddenSummary)))
        let toggles: [(String, Int, () -> String, (() -> String)?, GGSetting<Bool>)] = [
            ("appearance.messages.secondsInTime", 300, { GGStrings.Appearance.Messages.secondsInTime }, { GGStrings.Appearance.Messages.secondsInTimeInfo }, GGAppearanceSettings.secondsInTime),
            ("appearance.messages.exactLastSeen", 400, { GGStrings.Appearance.Messages.exactLastSeen }, { GGStrings.Appearance.Messages.exactLastSeenInfo }, GGAppearanceSettings.exactLastSeen),
            ("appearance.messages.wideChannelPosts", 900, { GGStrings.Appearance.Messages.wideChannelPosts }, nil, GGAppearanceSettings.wideChannelPosts),
            ("appearance.messages.authorOnline", 1000, { GGStrings.Appearance.Messages.authorOnline }, { GGStrings.Appearance.Messages.authorOnlineInfo }, GGAppearanceSettings.authorOnlineIndicator),
            ("appearance.messages.colorSwatches", 1100, { GGStrings.Appearance.Messages.colorSwatches }, { GGStrings.Appearance.Messages.colorSwatchesInfo }, GGAppearanceSettings.colorSwatches),
            ("appearance.messages.noSelectionBlur", 1200, { GGStrings.Appearance.Messages.noSelectionBlur }, nil, GGAppearanceSettings.noSelectionBlur)
        ]
        for (id, order, title, subtitle, setting) in toggles {
            GGMenuRegistry.register(GGMenuRow(id: id, section: GGAppearanceMenu.messagesInterface, order: order, title: title, subtitle: subtitle, kind: .toggle(.global(setting))))
        }
        // Two choices instead of four switches (2026-10-27): where reactions and formatting are hidden.
        GGMenuRegistry.register(GGMenuRow(id: "appearance.messages.hideReactions", section: GGAppearanceMenu.messagesInterface, order: 500, title: { GGStrings.Appearance.Messages.hideReactions }, kind: .choice(.global(GGAppearanceSettings.hideReactions), options: [
            GGMenuChoiceOption(value: GGHiddenReactions.off.rawValue, title: { GGStrings.Appearance.Messages.hiddenNowhere }),
            GGMenuChoiceOption(value: GGHiddenReactions.chats.rawValue, title: { GGStrings.Appearance.Messages.hideReactionsChats }),
            GGMenuChoiceOption(value: GGHiddenReactions.channels.rawValue, title: { GGStrings.Appearance.Messages.hideReactionsChannels }),
            GGMenuChoiceOption(value: GGHiddenReactions.all.rawValue, title: { GGStrings.Appearance.Messages.hiddenEverywhere })
        ])))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.messages.hideFormatting", section: GGAppearanceMenu.messagesInterface, order: 800, title: { GGStrings.Appearance.Messages.hideFormatting }, subtitle: { GGStrings.Appearance.Messages.hideFormattingInfo }, kind: .choice(.global(GGAppearanceSettings.hideFormatting), options: [
            GGMenuChoiceOption(value: GGHiddenFormatting.off.rawValue, title: { GGStrings.Appearance.Messages.hiddenNowhere }),
            GGMenuChoiceOption(value: GGHiddenFormatting.incoming.rawValue, title: { GGStrings.Appearance.Messages.hideFormattingIncoming }),
            GGMenuChoiceOption(value: GGHiddenFormatting.outgoing.rawValue, title: { GGStrings.Appearance.Messages.hideFormattingOutgoing }),
            GGMenuChoiceOption(value: GGHiddenFormatting.all.rawValue, title: { GGStrings.Appearance.Messages.hiddenEverywhere })
        ])))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.messages.tripleTapDelete", section: GGAppearanceMenu.messagesInterface, order: 1300, title: { GGStrings.Appearance.Messages.tripleTapDelete }, kind: .choice(.global(GGAppearanceSettings.tripleTapDelete), options: [
            GGMenuChoiceOption(value: GGTripleTapDelete.off.rawValue, title: { GGStrings.Appearance.Messages.tripleTapOff }),
            GGMenuChoiceOption(value: GGTripleTapDelete.local.rawValue, title: { GGStrings.Appearance.Messages.tripleTapLocal }),
            GGMenuChoiceOption(value: GGTripleTapDelete.everyone.rawValue, title: { GGStrings.Appearance.Messages.tripleTapEveryone })
        ])))

        // «Скрыть в шапке чата» (2026-10-27): the chat's top bar, four switches in one row. The
        // section keeps only its footer: the row's title says what it is.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.messagesTopBar, screen: .tab(tab), order: 700, footer: { _ in GGStrings.Appearance.TopBar.footer }))
        let hiddenInTopBar: [(String, () -> String, GGSetting<Bool>)] = [
            ("appearance.chatTopBar.hideBackButton", { GGStrings.Appearance.TopBar.backButton }, GGAppearanceSettings.hideBackButton),
            ("appearance.chatTopBar.hideTitle", { GGStrings.Appearance.TopBar.title }, GGAppearanceSettings.hideTitlePanel),
            ("appearance.chatTopBar.hideAvatar", { GGStrings.Appearance.TopBar.avatar }, GGAppearanceSettings.hideAvatar),
            ("appearance.chatTopBar.hidePinned", { GGStrings.Appearance.TopBar.pinned }, GGAppearanceSettings.hidePinnedMessages)
        ]
        GGMenuRegistry.register(GGMenuRow(id: "appearance.chatTopBar.hidden", section: GGAppearanceMenu.messagesTopBar, order: 100, title: { GGStrings.Appearance.TopBar.hidden }, kind: .expandableList(children: GGAppearanceMenu.hiddenChildren(hiddenInTopBar, section: GGAppearanceMenu.messagesTopBar), summary: GGAppearanceMenu.hiddenSummary), searchKeywords: { [GGStrings.Appearance.TopBar.keywords] }))
    }

    /// The switches of a «Скрыть в …» row, in the given order.
    private static func hiddenChildren(_ items: [(String, () -> String, GGSetting<Bool>)], section: GGMenuSectionID) -> [GGMenuRow] {
        var result: [GGMenuRow] = []
        var order = 100
        for (id, title, setting) in items {
            result.append(GGMenuRow(id: id, section: section, order: order, title: title, kind: .toggle(.global(setting))))
            order += 100
        }
        return result
    }

    /// «скрыто: 2 из 4» on the right of a «Скрыть в …» row (nothing while none is hidden).
    static func hiddenSummary(_ count: GGMenuGroupCount) -> String {
        return GGStrings.Appearance.Messages.hiddenCount(selected: "\(count.selected)", total: "\(count.total)")
    }

    // MARK: Font tab

    /// The user's own fonts (owner 2026-10-27), then the system font and its designs, then the
    /// families preinstalled in iOS. Nothing bundled, no font licenses to list.
    private static func registerFont() {
        GGAppearanceMenu.registerCustomFonts()

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.fontSystem, screen: .tab(GGAppearanceMenu.fontTab), order: 300, header: { GGStrings.Appearance.Font.systemHeader }, footer: { _ in
            if GGFonts.needsRestart {
                return GGStrings.Core.requiresRestartFooter
            }
            return GGStrings.Appearance.Font.systemFooter
        }))
        var order = 100
        for family in [GGFontFamily.system] + GGFonts.designFamilies {
            GGAppearanceMenu.registerFontRow(family: family, section: GGAppearanceMenu.fontSystem, order: order)
            order += 100
        }

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.fontFamilies, screen: .tab(GGAppearanceMenu.fontTab), order: 400, header: { GGStrings.Appearance.Font.familiesHeader }, footer: { _ in GGStrings.Appearance.Font.familiesFooter }))
        order = 100
        for family in GGFonts.installedFamilies {
            GGAppearanceMenu.registerFontRow(family: family, section: GGAppearanceMenu.fontFamilies, order: order)
            order += 100
        }
    }

    private static func registerFontRow(family: GGFontFamily, section: GGMenuSectionID, order: Int) {
        // «SF Mono», «New York» find the rows of the system designs too.
        let properName = GGFonts.properName(family)
        GGMenuRegistry.register(GGMenuRow(id: "appearance.font.\(family.rawValue)", section: section, order: order, title: { GGFonts.displayName(family) }, kind: .custom({ context in
            return GGAppearanceMenu.fontItem(family: family, context: context)
        }), isVisible: { _ in GGFonts.isAvailable(family) }, searchKeywords: { properName.map { [$0] } ?? [] }))
    }

    /// «Свои шрифты»: a row per added font (fixed slots: the registry is static, the list is a
    /// setting), «Добавить шрифт…» and «Удалить шрифт…».
    private static func registerCustomFonts() {
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.fontCustom, screen: .tab(GGAppearanceMenu.fontTab), order: 200, header: { GGStrings.Appearance.Font.customHeader }, footer: { _ in
            if GGFonts.needsRestart && GGFonts.selectedCustomFont != nil {
                return GGStrings.Core.requiresRestartFooter
            }
            return GGStrings.Appearance.Font.customFooter
        }))
        for index in 0 ..< GGCustomFonts.maximumCount {
            let font: () -> GGCustomFont? = {
                let fonts = GGCustomFonts.fonts
                return index < fonts.count ? fonts[index] : nil
            }
            GGMenuRegistry.register(GGMenuRow(id: "appearance.font.custom.\(index)", section: GGAppearanceMenu.fontCustom, order: 100 + index * 10, title: { font()?.familyName ?? "" }, kind: .custom({ context in
                guard let customFont = font() else {
                    return GGAppearanceMenu.fontItem(family: .system, context: context)
                }
                return GGAppearanceMenu.customFontItem(customFont, context: context)
            }), isVisible: { _ in font() != nil }))
        }
        GGMenuRegistry.register(GGMenuRow(id: "appearance.font.add", section: GGAppearanceMenu.fontCustom, order: 500, title: { GGStrings.Appearance.Font.add }, kind: .action({ context in
            GGPickers.pickFont(context: context)
        }), searchKeywords: { [GGStrings.Appearance.Font.keywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.font.remove", section: GGAppearanceMenu.fontCustom, order: 600, title: { GGStrings.Appearance.Font.remove }, kind: .action({ context in
            GGAppearanceMenu.presentRemoveFont(context: context)
        }), isVisible: { _ in !GGCustomFonts.fonts.isEmpty }, isDestructive: true))
    }

    private static func customFontItem(_ customFont: GGCustomFont, context: GGMenuContext) -> ListViewItem {
        let presentationData = context.itemListPresentationData
        let sample = GGFonts.sampleImage(customFont: customFont, color: presentationData.theme.list.itemPrimaryTextColor)
        let detail: String? = GGFonts.hasCyrillic(customFont) ? nil : GGStrings.Appearance.Font.noCyrillic
        return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: sample, iconSize: sample?.size, title: customFont.familyName, subtitle: detail, style: .right, checked: GGFonts.selectedCustomFont == customFont, zeroSeparatorInsets: false, sectionId: context.sectionId, action: {
            GGMenuBinding.global(GGAppearanceSettings.fontFamily).set(GGCustomFonts.settingValue(customFont), in: context)
        })
    }

    private static func presentRemoveFont(context: GGMenuContext) {
        let sheet = UIAlertController(title: GGStrings.Appearance.Font.removeTitle, message: nil, preferredStyle: .actionSheet)
        for customFont in GGCustomFonts.fonts {
            sheet.addAction(UIAlertAction(title: customFont.familyName, style: .destructive, handler: { _ in
                GGCustomFonts.remove(customFont)
            }))
        }
        sheet.addAction(UIAlertAction(title: context.presentationData.strings.Common_Cancel, style: .cancel, handler: nil))
        context.presentNative(sheet)
    }

    private static func fontItem(family: GGFontFamily, context: GGMenuContext) -> ListViewItem {
        let presentationData = context.itemListPresentationData
        let isSelected = GGFonts.selectedCustomFont == nil && GGFonts.selectedFamily == family
        let sample = GGFonts.sampleImage(family: family, color: presentationData.theme.list.itemPrimaryTextColor)
        return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: sample, iconSize: sample?.size, title: GGFonts.displayName(family), subtitle: GGFonts.detail(family), style: .right, checked: isSelected, zeroSeparatorInsets: false, sectionId: context.sectionId, action: {
            GGMenuBinding.global(GGAppearanceSettings.fontFamily).set(family.rawValue, in: context)
        })
    }

    // MARK: «Тема и фон»

    private static func registerTheme() {
        let tab = GGMenuTabID.appearanceThemeBackground

        GGMenuRegistry.register(GGMenuRow(
            id: "appearance.theme.preview",
            section: .preview(of: tab),
            order: 100,
            title: { "" },
            // Live: the theme follows its sliders while dragged; the animated background, the snow
            // and the edge bands are shown as in a chat (U6, U7).
            kind: .preview(.miniChat(GGAppearancePreview.configuration(scope: "appearance.theme", overlays: true, content: { _ in
                return GGAppearancePreview.sampleContent()
            })))
        ))

        let main = GGMenuSectionID.main(of: tab)
        GGMenuRegistry.register(GGMenuRow(id: "appearance.theme.amoled", section: main, order: 100, title: { GGStrings.Appearance.Theme.amoled }, subtitle: { GGStrings.Appearance.Theme.amoledInfo }, kind: .toggle(.global(GGAppearanceSettings.amoled)), searchKeywords: { [GGStrings.Appearance.Theme.amoledKeywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.theme.amoledKeyboard", section: main, order: 200, title: { GGStrings.Appearance.Theme.amoledKeyboard }, subtitle: { GGStrings.Appearance.Theme.amoledKeyboardInfo }, kind: .toggle(.global(GGAppearanceSettings.amoledKeyboard))))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.theme.hideSeparators", section: main, order: 300, title: { GGStrings.Appearance.Theme.hideSeparators }, kind: .toggle(.global(GGAppearanceSettings.hideSeparators))))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.theme.nameSaturation", section: main, order: 400, title: { GGStrings.Appearance.Theme.nameSaturation }, subtitle: { GGStrings.Appearance.Theme.nameSaturationInfo }, kind: .slider(.global(GGAppearanceSettings.nameColorSaturation), range: 0.0 ... 100.0, step: 5.0, format: GGAppearanceMenu.percent)))

        // «Затемнение краёв» (one group since 2026-10-27): the kind of band, then only what it uses.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.themeEdges, screen: .tab(tab), order: 400, header: { GGStrings.Appearance.Edges.header }, footer: { _ in GGStrings.Appearance.Edges.footer }))
        let edgeStyle: () -> GGEdgeStyle = { GGEdgeStyle(rawValue: GGAppearanceSettings.edgeStyle.value) ?? .off }
        let edgesOn: (GGMenuContext) -> Bool = { _ in edgeStyle() != .off }
        GGMenuRegistry.register(GGMenuRow(id: "appearance.edges.style", section: GGAppearanceMenu.themeEdges, order: 100, title: { GGStrings.Appearance.Edges.header }, kind: .discreteChoice(.global(GGAppearanceSettings.edgeStyle), options: [
            GGMenuChoiceOption(value: GGEdgeStyle.off.rawValue, title: { GGStrings.Appearance.Edges.styleOff }),
            GGMenuChoiceOption(value: GGEdgeStyle.blur.rawValue, title: { GGStrings.Appearance.Edges.styleBlur }),
            GGMenuChoiceOption(value: GGEdgeStyle.gradient.rawValue, title: { GGStrings.Appearance.Edges.styleGradient })
        ]), searchKeywords: { [GGStrings.Appearance.Edges.keywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.edges.intensity", section: GGAppearanceMenu.themeEdges, order: 200, title: { GGStrings.Appearance.Edges.intensity }, kind: .slider(.global(GGAppearanceSettings.edgeIntensity), range: 0.0 ... 100.0, step: 5.0, format: GGAppearanceMenu.percent), isVisible: edgesOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.edges.size", section: GGAppearanceMenu.themeEdges, order: 300, title: { GGStrings.Appearance.Edges.size }, kind: .slider(.global(GGAppearanceSettings.edgeSize), range: GGEdgeStyle.sizeRange, step: 4.0, format: GGAppearanceMenu.points), isVisible: edgesOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.edges.color", section: GGAppearanceMenu.themeEdges, order: 400, title: { GGStrings.Appearance.Edges.color }, kind: .action({ context in
            // The picker starts where the old rows did: the bar's color for the blur, the accent for the gradient.
            let fallback = edgeStyle() == .gradient ? context.presentationData.theme.list.itemAccentColor : context.presentationData.theme.rootController.navigationBar.opaqueBackgroundColor
            GGColorPicker.present(context: context, setting: GGAppearanceSettings.edgeColor, fallback: fallback)
        }), isVisible: edgesOn, label: { _ in GGAppearanceMenu.colorLabel(GGAppearanceSettings.edgeColor) }))
        // Back to «Automatic» (the bar's color, following the theme) once a color was chosen.
        GGMenuRegistry.register(GGMenuRow(id: "appearance.edges.resetColor", section: GGAppearanceMenu.themeEdges, order: 450, title: { GGStrings.Appearance.Edges.resetColor }, kind: .action({ _ in
            GGAppearanceSettings.edgeColor.reset()
        }), isVisible: { context in edgesOn(context) && !GGAppearanceSettings.edgeColor.value.isEmpty }, isDestructive: true))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.edges.hideInChatList", section: GGAppearanceMenu.themeEdges, order: 500, title: { GGStrings.Appearance.Edges.hideInChatList }, kind: .toggle(.global(GGAppearanceSettings.edgeHideInChatList)), isVisible: { _ in edgeStyle() == .gradient }))

        // Animated chat background.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.themeBackground, screen: .tab(tab), order: 500, header: { GGStrings.Appearance.Background.chatHeader }, footer: { _ in GGStrings.Appearance.Background.footer }))
        GGAppearanceMenu.registerBackgroundRows(kind: .chat, section: GGAppearanceMenu.themeBackground, idPrefix: "appearance.chatBackground")

        // Snowfall.
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.themeSnow, screen: .tab(tab), order: 600, header: { GGStrings.Appearance.Snow.header }, footer: { _ in
            // Says so when the system is what stops the snow right now (the switch alone looked broken).
            if GGAppearanceSettings.snow.value && GGSystemState.current {
                return GGStrings.Appearance.Snow.footer + "\n\n" + GGStrings.Appearance.Snow.pausedNow
            }
            return GGStrings.Appearance.Snow.footer
        }))
        let snowOn: (GGMenuContext) -> Bool = { _ in GGAppearanceSettings.snow.value }
        GGMenuRegistry.register(GGMenuRow(id: "appearance.snow.enabled", section: GGAppearanceMenu.themeSnow, order: 100, title: { GGStrings.Appearance.Snow.enabled }, kind: .toggle(.global(GGAppearanceSettings.snow)), searchKeywords: { [GGStrings.Appearance.Snow.keywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.snow.style", section: GGAppearanceMenu.themeSnow, order: 200, title: { GGStrings.Appearance.Snow.style }, kind: .choice(.global(GGAppearanceSettings.snowStyle), options: [
            GGMenuChoiceOption(value: GGSnowStyle.snow.rawValue, title: { GGStrings.Appearance.Snow.styleSnow }),
            GGMenuChoiceOption(value: GGSnowStyle.lightning.rawValue, title: { GGStrings.Appearance.Snow.styleLightning })
        ]), isVisible: snowOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.snow.intensity", section: GGAppearanceMenu.themeSnow, order: 300, title: { GGStrings.Appearance.Snow.intensity }, kind: .slider(.global(GGAppearanceSettings.snowIntensity), range: 10.0 ... 100.0, step: 5.0, format: GGAppearanceMenu.percent), isVisible: snowOn))
        GGMenuRegistry.register(GGMenuRow(id: "appearance.snow.hideInChats", section: GGAppearanceMenu.themeSnow, order: 400, title: { GGStrings.Appearance.Snow.hideInChats }, kind: .toggle(.global(GGAppearanceSettings.snowHideInChats)), isVisible: snowOn))
    }

    /// Rows of an animated background: on/off (once a file exists), pick, opacity, delete.
    private static func registerBackgroundRows(kind: GGAnimatedBackgroundKind, section: GGMenuSectionID, idPrefix: String) {
        let hasFile: (GGMenuContext) -> Bool = { _ in kind.versionSetting.value != 0 }
        GGMenuRegistry.register(GGMenuRow(id: "\(idPrefix).enabled", section: section, order: 100, title: { GGStrings.Appearance.Background.enabled }, kind: .toggle(.global(kind.enabledSetting)), isVisible: hasFile))
        GGMenuRegistry.register(GGMenuRow(id: "\(idPrefix).pick", section: section, order: 200, title: { GGStrings.Appearance.Background.pick }, subtitle: { GGStrings.Appearance.Background.pickInfo }, kind: .action({ context in
            GGPickers.pickBackground(context: context, kind: kind)
        }), searchKeywords: { [GGStrings.Appearance.Background.keywords] }, label: { _ in
            return kind.versionSetting.value != 0 ? GGStrings.Appearance.Background.isSet : GGStrings.Appearance.Background.notSet
        }))
        GGMenuRegistry.register(GGMenuRow(id: "\(idPrefix).opacity", section: section, order: 300, title: { GGStrings.Appearance.Background.opacity }, kind: .slider(.global(kind.opacitySetting), range: 5.0 ... 100.0, step: 5.0, format: GGAppearanceMenu.percent), isVisible: hasFile))
        GGMenuRegistry.register(GGMenuRow(id: "\(idPrefix).remove", section: section, order: 400, title: { GGStrings.Appearance.Background.remove }, kind: .action({ _ in
            GGAnimatedBackgrounds.remove(kind)
        }), isVisible: hasFile, isDestructive: true))
    }

    // MARK: «Профиль»

    private static func registerProfile() {
        let tab = GGMenuTabID.appearanceProfileSettings
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.profileInfo, screen: .tab(tab), order: 300, header: { GGStrings.Appearance.Profile.header }, footer: { _ in GGStrings.Appearance.Profile.footer }))
        let rows: [(String, () -> String, (() -> String)?, GGSetting<Bool>)] = [
            ("appearance.profile.showId", { GGStrings.Appearance.Profile.showId }, nil, GGAppearanceSettings.profileShowId),
            ("appearance.profile.showDataCenter", { GGStrings.Appearance.Profile.showDataCenter }, { GGStrings.Appearance.Profile.showDataCenterInfo }, GGAppearanceSettings.profileShowDataCenter),
            ("appearance.profile.showDates", { GGStrings.Appearance.Profile.showDates }, { GGStrings.Appearance.Profile.showDatesInfo }, GGAppearanceSettings.profileShowDates),
            ("appearance.profile.hideDescription", { GGStrings.Appearance.Profile.hideDescription }, nil, GGAppearanceSettings.profileHideDescription),
            ("appearance.profile.hideShareButton", { GGStrings.Appearance.Profile.hideShareButton }, nil, GGAppearanceSettings.profileHideShareButton),
            ("appearance.profile.hideStarRating", { GGStrings.Appearance.Profile.hideStarRating }, nil, GGAppearanceSettings.profileHideStarRating)
        ]
        var order = 100
        for (id, title, subtitle, setting) in rows {
            GGMenuRegistry.register(GGMenuRow(id: id, section: GGAppearanceMenu.profileInfo, order: order, title: title, subtitle: subtitle, kind: .toggle(.global(setting))))
            order += 100
        }

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGAppearanceMenu.profileBackground, screen: .tab(tab), order: 400, header: { GGStrings.Appearance.Background.profileHeader }, footer: { _ in GGStrings.Appearance.Background.profileFooter }))
        GGAppearanceMenu.registerBackgroundRows(kind: .profile, section: GGAppearanceMenu.profileBackground, idPrefix: "appearance.profileBackground")
    }
}
