import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import AppBundle
import TelegramCore
import ComponentFlow
import TabBarComponent
import GlassBackgroundComponent
import WallpaperBackgroundNode
import GGCore
import GGHooks
import GGSettingsUI

private func ggPreviewGlyph(_ name: String, color: UIColor) -> UIImage? {
    return generateTintedImage(image: UIImage(bundleImageName: name), color: color)
}

/// «Панели» › input field: stands on the chat's real wallpaper, its bars are Telegram 13's glass, as on
/// screen: the wallpaper node is laid out over the block and follows the theme.
class GGPanelsPreviewBase: UIView {
    private var wallpaperNode: WallpaperBackgroundNode?
    private var wallpaperTheme: PresentationTheme?
    private var wallpaper: TelegramWallpaper?
    private var glyphTheme: PresentationTheme?
    private var glyphs: [String: UIImage] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func updateWallpaper(context: GGMenuContext) {
        let presentationData = context.presentationData
        let node: WallpaperBackgroundNode
        if let current = self.wallpaperNode {
            node = current
        } else {
            node = createWallpaperBackgroundNode(context: context.context, forChatDisplay: false)
            node.isUserInteractionEnabled = false
            self.insertSubview(node.view, at: 0)
            self.wallpaperNode = node
        }
        if self.wallpaper != presentationData.chatWallpaper {
            self.wallpaper = presentationData.chatWallpaper
            node.update(wallpaper: presentationData.chatWallpaper, animated: false)
        }
        if self.wallpaperTheme !== presentationData.theme {
            self.wallpaperTheme = presentationData.theme
            node.updateBubbleTheme(bubbleTheme: presentationData.theme, bubbleCorners: presentationData.chatBubbleCorners)
        }
        // A screen-high wallpaper, cut by the block — the pattern keeps the chat's scale.
        let wallpaperFrame = CGRect(x: 0.0, y: -200.0, width: self.bounds.width, height: self.bounds.height + 400.0)
        if node.frame != wallpaperFrame {
            node.frame = wallpaperFrame
            node.updateLayout(size: wallpaperFrame.size, displayMode: .aspectFill, transition: .immediate)
        }
    }

    func updateGlass(_ view: GlassBackgroundView, frame: CGRect, cornerRadius: CGFloat, theme: PresentationTheme) {
        view.frame = frame
        view.update(size: frame.size, cornerRadius: cornerRadius, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
    }

    func glyph(_ name: String, color: UIColor, theme: PresentationTheme) -> UIImage? {
        if self.glyphTheme !== theme {
            self.glyphTheme = theme
            self.glyphs.removeAll()
        }
        let key = name + "|\(color.hashValue)"
        if let image = self.glyphs[key] {
            return image
        }
        let image = ggPreviewGlyph(name, color: color)
        self.glyphs[key] = image
        return image
    }
}

/// «Панели» › tab bar: Telegram's own bar (`TabBarComponent`) with the account's real tabs — their icons,
/// the avatar of «Настройки», the unread badges, the selection lens — in the user's order, names and
/// style, over a chat list, as on screen (owner, build 189: the drawn bar on the wallpaper did not look
/// like the real one). Updated on every rebuild (slider ticks included); the chat list is rebuilt only
/// when the theme, the text size or the width change.
final class GGTabBarPreviewView: UIView, GGMenuPreviewView {
    static let height: CGFloat = 184.0

    private var listNode: GGPreviewChatListNode?
    private var listKey: (theme: ObjectIdentifier, fontSize: PresentationFontSize, width: CGFloat)?
    private let tabBar = ComponentView<Empty>()
    /// Telegram's own «Calls» tab switch: the organizer hides Calls through it, not through
    /// `hiddenTabs`. Known synchronously from the built tab bar, then followed.
    private var showsCallsTab: Bool?
    private var callsDisposable: MetaDisposable?
    private var lastContext: GGMenuContext?
    private var isUpdating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        self.callsDisposable?.dispose()
    }

    /// Starts following Telegram's «Calls» tab switch once per view; a change redraws the preview.
    private func followCallsTab(context: GGMenuContext) {
        if self.callsDisposable != nil {
            return
        }
        if self.showsCallsTab == nil, let entry = GGRootRegistry.shared.allEntries.first(where: { $0.context === context.context }) {
            // The built tab bar has the calls controller only while Telegram shows the tab.
            self.showsCallsTab = entry.calls != nil
        }
        let disposable = MetaDisposable()
        self.callsDisposable = disposable
        disposable.set((GGTabBarScreens.showsCallsTab(context: context.context)
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.showsCallsTab != value else {
                return
            }
            self.showsCallsTab = value
            if !self.isUpdating, let lastContext = self.lastContext {
                self.update(context: lastContext)
            }
        }))
    }

    func update(context: GGMenuContext) {
        self.lastContext = context
        self.isUpdating = true
        defer {
            self.isUpdating = false
        }
        self.followCallsTab(context: context)

        let size = self.bounds.size
        if size.width <= 0.0 {
            return
        }
        let presentationData = context.presentationData
        let theme = presentationData.theme
        let strings = presentationData.strings

        // The chat list the bar floats over.
        self.backgroundColor = theme.chatList.backgroundColor
        let listNode: GGPreviewChatListNode
        if let current = self.listNode {
            listNode = current
        } else {
            listNode = GGPreviewChatListNode(context: context.context)
            self.insertSubview(listNode.view, at: 0)
            self.listNode = listNode
        }
        listNode.frame = CGRect(origin: CGPoint(), size: size)
        let listKey = (theme: ObjectIdentifier(theme), fontSize: presentationData.listsFontSize, width: size.width)
        if self.listKey.map({ $0.theme != listKey.theme || $0.fontSize != listKey.fontSize || $0.width != listKey.width }) ?? true {
            self.listKey = listKey
            listNode.update(context: context.context, presentationData: presentationData, rows: GGPreviewChatListRow.samples(), width: size.width)
        }

        // The bar: the settings as they are (sliders while dragged), the snapshot's label revision.
        let isWide = InterfaceSettings.wideTabBar.value
        let style = GGTabBarStyle(
            hidesTitles: InterfaceSettings.hideTabTitles.value,
            isWide: isWide,
            fitsItems: !isWide,
            hidesBar: InterfaceSettings.hideTabBar.value,
            heightOffset: CGFloat(GGTabBarLayout.clampHeightOffset(context.displayValue(.global(InterfaceSettings.tabBarHeightOffset)))),
            bottomOffset: CGFloat(GGTabBarLayout.clampBottomOffset(context.displayValue(.global(InterfaceSettings.tabBarBottomOffset)))),
            titlesRevision: InterfaceSnapshots.shared.current.tabBarStyle.titlesRevision
        )
        let order = GGTabBarLayout.normalizedOrder(InterfaceSettings.tabOrder.value)
        var hidden = Set(InterfaceSettings.hiddenTabs.value)
        if self.showsCallsTab == false {
            hidden.insert(GGTabBarLayout.calls)
        }
        let visible = order.filter { !hidden.contains($0) }
        // The account's own tab items (icons, avatar, badges); drawn ones only while its root is not built.
        let entry = GGRootRegistry.shared.allEntries.first(where: { $0.context === context.context })
        let icons: [String: String] = [
            GGTabBarLayout.contacts: "Chat List/Tabs/IconContacts",
            GGTabBarLayout.calls: "Chat List/Tabs/IconCalls",
            GGTabBarLayout.chats: "Chat List/Tabs/IconChats",
            GGTabBarLayout.settings: "Chat List/Tabs/IconSettings"
        ]
        var items: [TabBarComponent.Item] = []
        var selectedId: AnyHashable?
        for id in visible {
            let content: TabBarComponent.Item.Content
            let itemId: AnyHashable
            if let tabBarItem = entry?.controller(for: id)?.tabBarItem {
                content = .tabBarItem(tabBarItem)
                itemId = AnyHashable(ObjectIdentifier(tabBarItem))
            } else {
                content = .customItem(TabBarComponent.Item.Content.CustomItem(id: id, title: GGTabBarScreens.title(id, strings: strings), icon: .bundleIcon(name: icons[id] ?? "")))
                itemId = AnyHashable(id)
            }
            if id == GGTabBarLayout.chats {
                selectedId = itemId
            }
            items.append(TabBarComponent.Item(content: content, action: { _ in }, doubleTapAction: nil, contextAction: nil))
        }
        // The bar's own side insets and width rule (TabBarControllerNode), its lift at full scale.
        let sideInset: CGFloat = isWide ? 8.0 : 12.0
        let bottomInset: CGFloat = 12.0 + style.bottomOffset
        let barSize = self.tabBar.update(
            transition: .immediate,
            component: AnyComponent(TabBarComponent(
                theme: theme,
                strings: strings,
                items: items,
                search: nil,
                selectedId: selectedId,
                outerInsets: UIEdgeInsets(top: 0.0, left: sideInset, bottom: bottomInset, right: sideInset),
                axis: .horizontal,
                isCompact: false,
                ggStyle: style
            )),
            environment: {},
            containerSize: CGSize(width: max(1.0, size.width - sideInset * 2.0), height: 100.0)
        )
        if let barView = self.tabBar.view {
            if barView.superview == nil {
                barView.isUserInteractionEnabled = false
                self.addSubview(barView)
            }
            barView.isHidden = style.hidesBar || items.isEmpty
            barView.frame = CGRect(origin: CGPoint(x: floor((size.width - barSize.width) * 0.5), y: size.height - bottomInset - barSize.height), size: barSize)
        }
    }
}

/// «Панели» › input field: the chat's input bar as it looks while typing — the attach button, the field
/// with a line of text and the emoji and send buttons inside it — with the editor's margins and button
/// offsets, the formatting toolbar under it with all of its buttons, and «Счётчик символов» where the
/// chat puts it: before the send button while the text is one line, in the field's top-right corner
/// past it (owner, build 189: the drawn field did not look like the real one).
final class GGInputBarPreviewView: GGPanelsPreviewBase, GGMenuPreviewView {
    static let height: CGFloat = 150.0

    private let toolbarGlass = GlassBackgroundView()
    private var toolbarButtons: [UIImageView] = []
    private let fieldGlass = GlassBackgroundView()
    private let fieldText = UILabel()
    private let attachGlass = GlassBackgroundView()
    private let attachIcon = UIImageView()
    private let emojiIcon = UIImageView()
    private let sendBackground = UIImageView()
    private let sendIcon = UIImageView()
    private let counterLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.toolbarGlass)
        for name in GGFormattingToolbar.symbolNames {
            let view = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)))
            view.contentMode = .center
            self.addSubview(view)
            self.toolbarButtons.append(view)
        }
        self.addSubview(self.fieldGlass)
        self.fieldText.numberOfLines = 2
        self.addSubview(self.fieldText)
        self.addSubview(self.attachGlass)
        self.attachIcon.contentMode = .center
        self.addSubview(self.attachIcon)
        self.emojiIcon.contentMode = .center
        self.emojiIcon.image = UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21.0, weight: .regular))
        self.addSubview(self.emojiIcon)
        self.sendBackground.image = generateStretchableFilledCircleImage(diameter: 34.0, color: .white)?.withRenderingMode(.alwaysTemplate)
        self.addSubview(self.sendBackground)
        self.sendIcon.contentMode = .center
        self.addSubview(self.sendIcon)
        self.addSubview(self.counterLabel)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func update(context: GGMenuContext) {
        let size = self.bounds.size
        if size.width <= 0.0 {
            return
        }
        self.updateWallpaper(context: context)
        let theme = context.presentationData.theme
        let geometry = InterfaceSettings.inputBarGeometry.value.clamped
        let showsToolbar = InterfaceSettings.formattingToolbar.value
        let showsCounter = InterfaceSettings.characterCounter.value

        let toolbarHeight = GGFormattingToolbar.height
        let toolbarSpacing: CGFloat = 6.0
        let buttonSize: CGFloat = 40.0
        // The chat panel's own measures: the emoji button is 32 pt wide, 4 pt from the send button.
        let accessoryWidth: CGFloat = 32.0
        let accessoryInset: CGFloat = 4.0
        let left = 10.0 + CGFloat(geometry.leftMargin) * 0.25
        let right = 10.0 + CGFloat(geometry.rightMargin) * 0.25
        let inputBottom = size.height - 12.0 - CGFloat(geometry.bottomOffset) * 0.15 - (showsToolbar ? toolbarHeight + toolbarSpacing : 0.0)

        // The text and the counter's room, decided as the chat decides it: one line with the room
        // before the send button, or two lines and the counter in the corner.
        let text = GGStrings.Menu.Preview.incomingText
        let textFont = Font.regular(15.0)
        let lineHeight = ceil(textFont.lineHeight)
        let counterFont = GGCharacterCounter.font(baseFontSize: 17.0)
        let slotWidth = showsCounter ? GGCharacterCounter.slotWidth(count: text.count, font: counterFont) : 0.0
        let fieldMinX = left + buttonSize + 6.0
        let fieldWidth = max(120.0, size.width - right - fieldMinX)
        let textInset: CGFloat = 14.0
        let rowTextWidth = fieldWidth - textInset - accessoryInset - accessoryWidth - buttonSize
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: textFont]).width)
        // One line is decided without the room; text that wraps only because of it keeps the counter
        // before the send button (as in the chat).
        let usesSlot = slotWidth > 0.0 && textWidth <= rowTextWidth
        let lines: CGFloat = textWidth <= rowTextWidth - (usesSlot ? slotWidth : 0.0) ? 1.0 : 2.0

        let inputHeight: CGFloat = 40.0 + lineHeight * (lines - 1.0) + CGFloat(geometry.heightPadding) * 0.25
        let fieldFrame = CGRect(x: fieldMinX, y: inputBottom - inputHeight, width: fieldWidth, height: inputHeight)
        self.updateGlass(self.fieldGlass, frame: fieldFrame, cornerRadius: 20.0, theme: theme)
        self.fieldText.text = text
        self.fieldText.font = textFont
        self.fieldText.textColor = theme.chat.inputPanel.primaryTextColor
        self.fieldText.frame = CGRect(x: fieldFrame.minX + textInset, y: fieldFrame.minY + floor((40.0 - lineHeight) * 0.5), width: rowTextWidth - (usesSlot ? slotWidth : 0.0), height: lineHeight * lines)

        // The attach button outside the field; the send and emoji buttons inside it, at its bottom,
        // moved by the editor's offsets.
        let attachFrame = CGRect(x: left + CGFloat(geometry.attachX) * 0.25, y: inputBottom - buttonSize + CGFloat(geometry.attachY) * 0.25, width: buttonSize, height: buttonSize)
        self.updateGlass(self.attachGlass, frame: attachFrame, cornerRadius: buttonSize * 0.5, theme: theme)
        self.attachIcon.image = self.glyph("Chat/Input/Text/IconAttachment", color: theme.chat.inputPanel.panelControlColor, theme: theme)
        self.attachIcon.frame = attachFrame
        let sendFrame = CGRect(x: fieldFrame.maxX - buttonSize + CGFloat(geometry.sendX) * 0.25, y: fieldFrame.maxY - buttonSize + CGFloat(geometry.sendY) * 0.25, width: buttonSize, height: buttonSize)
        self.sendBackground.frame = sendFrame.insetBy(dx: 3.0, dy: 3.0)
        self.sendBackground.tintColor = theme.chat.inputPanel.panelControlAccentColor
        self.sendIcon.image = PresentationResourcesChat.chatInputPanelSendIconImage(theme)
        self.sendIcon.frame = sendFrame
        let emojiFrame = CGRect(x: fieldFrame.maxX - buttonSize - accessoryInset - (usesSlot ? slotWidth : 0.0) - accessoryWidth + CGFloat(geometry.accessoryX) * 0.25, y: fieldFrame.maxY - buttonSize + CGFloat(geometry.accessoryY) * 0.25, width: accessoryWidth, height: buttonSize)
        self.emojiIcon.tintColor = theme.chat.inputPanel.inputControlColor
        self.emojiIcon.frame = emojiFrame

        // The counter as the chat draws it (GGCharacterCounter).
        self.counterLabel.isHidden = !showsCounter
        self.counterLabel.font = counterFont
        self.counterLabel.textColor = theme.chat.inputPanel.panelControlColor
        self.counterLabel.text = "\(text.count)"
        let counterSize = self.counterLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        if usesSlot {
            let slotLeft = emojiFrame.maxX - 4.0
            let slotRight = sendFrame.minX + 3.0
            self.counterLabel.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((slotLeft + slotRight - counterSize.width) * 0.5), y: floorToScreenPixels(sendFrame.midY - counterSize.height * 0.5)), size: counterSize)
        } else {
            self.counterLabel.frame = CGRect(origin: CGPoint(x: fieldFrame.maxX - counterSize.width - 11.0, y: fieldFrame.minY + 4.0), size: counterSize)
        }

        self.toolbarGlass.isHidden = !showsToolbar
        for button in self.toolbarButtons {
            button.isHidden = !showsToolbar
        }
        if showsToolbar {
            // As GGFormattingToolbar lays itself out: 4 pt inside the glass, equal columns.
            let toolbarFrame = CGRect(x: left, y: inputBottom + toolbarSpacing, width: max(40.0, size.width - left - right), height: toolbarHeight)
            self.updateGlass(self.toolbarGlass, frame: toolbarFrame, cornerRadius: toolbarHeight * 0.5, theme: theme)
            let buttonWidth = floor((toolbarFrame.width - 8.0) / CGFloat(self.toolbarButtons.count))
            for (index, button) in self.toolbarButtons.enumerated() {
                button.tintColor = theme.chat.inputPanel.panelControlColor
                button.frame = CGRect(x: toolbarFrame.minX + 4.0 + CGFloat(index) * buttonWidth, y: toolbarFrame.minY, width: buttonWidth, height: toolbarFrame.height)
            }
        }
    }
}

/// «Иконки»: a 2×2 grid of the glyphs the first enabled pack replaces (Telegram's own when no
/// pack is on). Pack files are read once per (pack, its icon list), not per rebuild.
final class GGIconsPreviewView: UIView, GGMenuPreviewView {
    private var cells: [UIImageView] = []
    private var cacheKey: String?
    private var images: [UIImage] = []
    private var packsDisposable: Disposable?
    private var packs: [GGIconPack] = []
    private var lastContext: GGMenuContext?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for _ in 0 ..< 4 {
            let view = UIImageView()
            view.contentMode = .center
            view.layer.cornerRadius = 14.0
            view.clipsToBounds = true
            self.addSubview(view)
            self.cells.append(view)
        }
        self.packsDisposable = (GGIconPackStorage.shared.packs
        |> deliverOnMainQueue).start(next: { [weak self] packs in
            guard let self else {
                return
            }
            self.packs = packs
            self.cacheKey = nil
            if let context = self.lastContext {
                self.update(context: context)
            }
        })
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        self.packsDisposable?.dispose()
    }

    func update(context: GGMenuContext) {
        self.lastContext = context
        let theme = context.presentationData.theme
        let enabled = InterfaceSettings.iconPacks.value
        let pack = enabled.lazy.compactMap { id in self.packs.first(where: { $0.id == id }) }.first
        let key = (pack.map { "\($0.id)|\($0.icons.count)|\($0.icons.values.sorted().joined())" } ?? "stock") + "|\(ObjectIdentifier(theme).hashValue)"
        if key != self.cacheKey {
            self.cacheKey = key
            let color = theme.list.itemPrimaryTextColor
            // The pack's files are read and decoded off the main thread; the grid fills in when ready.
            ggInterfaceQueue.async { [weak self] in
                let images = GGIconPackResolver.previewImages(pack: pack).map { image in
                    return image.renderingMode == .alwaysTemplate ? (generateTintedImage(image: image, color: color) ?? image) : image
                }
                Queue.mainQueue().async { [weak self] in
                    guard let self, self.cacheKey == key else {
                        return
                    }
                    self.images = images
                    if let context = self.lastContext {
                        self.update(context: context)
                    }
                }
            }
        }
        let size = self.bounds.size
        let cellSide: CGFloat = min(64.0, (size.height - 36.0) / 2.0)
        let spacing: CGFloat = 12.0
        let gridWidth = cellSide * 2.0 + spacing
        let origin = CGPoint(x: floor((size.width - gridWidth) * 0.5), y: floor((size.height - gridWidth) * 0.5))
        for (index, cell) in self.cells.enumerated() {
            let row = CGFloat(index / 2)
            let column = CGFloat(index % 2)
            cell.frame = CGRect(x: origin.x + column * (cellSide + spacing), y: origin.y + row * (cellSide + spacing), width: cellSide, height: cellSide)
            cell.backgroundColor = ggPreviewOutlineColor(theme: theme).withAlphaComponent(0.25)
            cell.image = index < self.images.count ? self.images[index] : nil
        }
    }
}
