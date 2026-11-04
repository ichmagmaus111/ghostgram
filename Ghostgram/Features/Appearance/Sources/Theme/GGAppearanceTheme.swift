import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import GGCore
import GGHooks
import GGAppearanceSettings

/// The appearance transformer of the theme chain (GGThemeHooks.presentationData): AMOLED, AMOLED
/// keyboard, hidden separators, bubble paint and corners — all as theme values (checkmark colors are
/// picked per state where the checks are drawn, see `derivedTheme`),
/// so the upstream theme caches (bubble images, checks, list resources) work unchanged and every
/// image is made once per value, never per layout. With the snapshot at its defaults the
/// PresentationData passes through untouched (upstream byte for byte).
enum GGAppearanceTheme {
    static func register() {
        GGThemeHooks.presentationData.register({ presentationData, _ in
            return GGAppearanceTheme.transform(presentationData)
        }, order: 100)

        GGThemeHooks.bubbleShape.register({ shape in
            GGAppearanceTheme.transformBubbleShape(&shape)
        }, order: 100)

        GGChatScreenHooks.bubbleMaxWidth.register({ width, _, _ in
            guard let bubbles = GGAppearanceSnapshot.current.bubbles, bubbles.widthFraction < 1.0 else {
                return nil
            }
            return floor(width * CGFloat(bubbles.widthFraction))
        }, order: 100)

        // One theme rebuild per change of the snapshot (a slider writes once, on release). The first
        // value is the snapshot at launch: the first PresentationData already reflects it.
        var isFirst = true
        let _ = (GGAppearanceSnapshot.signal
        |> deliverOnMainQueue).start(next: { _ in
            if isFirst {
                isFirst = false
                return
            }
            GGThemeHooks.invalidate()
        })
    }

    // MARK: PresentationData

    private static let cache = GGDerivedThemeCache()

    static func transform(_ presentationData: PresentationData) -> PresentationData {
        let snapshot = GGAppearanceSnapshot.current
        if snapshot.isDefault {
            return presentationData
        }
        let theme = GGAppearanceTheme.cache.theme(for: presentationData.theme, snapshot: snapshot)
        GGAppearanceTheme.sources.note(result: theme, source: presentationData.theme, corners: presentationData.chatBubbleCorners)
        return GGAppearanceTheme.presentationData(presentationData, theme: theme, chatBubbleCorners: GGAppearanceTheme.corners(presentationData.chatBubbleCorners, snapshot: snapshot))
    }

    /// Media corners and text insets of the bubble follow the editor's larger radius; the
    /// per-direction shapes come from `transformBubbleShape`.
    private static func corners(_ corners: PresentationChatBubbleCorners, snapshot: GGAppearanceSnapshot) -> PresentationChatBubbleCorners {
        var result = corners
        if let bubbles = snapshot.bubbles {
            let mainRadius = CGFloat(max(bubbles.incomingRadius, bubbles.outgoingRadius))
            result.mainRadius = mainRadius
            result.auxiliaryRadius = min(result.auxiliaryRadius, mainRadius)
        }
        return result
    }

    private static func presentationData(_ presentationData: PresentationData, theme: PresentationTheme, chatBubbleCorners: PresentationChatBubbleCorners) -> PresentationData {
        return PresentationData(strings: presentationData.strings, theme: theme, autoNightModeTriggered: presentationData.autoNightModeTriggered, chatWallpaper: presentationData.chatWallpaper, chatFontSize: presentationData.chatFontSize, chatBubbleCorners: chatBubbleCorners, listsFontSize: presentationData.listsFontSize, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, nameSortOrder: presentationData.nameSortOrder, reduceMotion: presentationData.reduceMotion, largeEmoji: presentationData.largeEmoji)
    }

    // MARK: Live preview

    /// Themes made for the menu's preview while a slider is dragged; kept apart from `cache`, so
    /// dragging never pushes the app's own theme out of it.
    private static let previewCache = GGDerivedThemeCache()
    private static let sources = GGDerivedThemeSources()

    /// The PresentationData of the menu's live preview: the app's theme as the appearance settings
    /// make it with the dragged values. Call inside `GGAppearanceSnapshot.withPreview(_:_:)` (the
    /// preview's `draftScope`): the snapshot read here and by the bubble shapes drawn for the new
    /// theme is the draft. The menu's own PresentationData already went through this transformer,
    /// so it starts again from the theme the transformer was given (found by the theme's `chat`
    /// object, which the later transformers of the chain pass through unchanged).
    static func previewPresentationData(_ presentationData: PresentationData) -> PresentationData {
        var sourceTheme = presentationData.theme
        var sourceCorners = presentationData.chatBubbleCorners
        if let source = GGAppearanceTheme.sources.source(of: presentationData.theme) {
            sourceTheme = source.theme
            sourceCorners = source.corners
        }
        let snapshot = GGAppearanceSnapshot.current
        let theme = snapshot.isDefault ? sourceTheme : GGAppearanceTheme.previewCache.theme(for: sourceTheme, snapshot: snapshot)
        return GGAppearanceTheme.presentationData(presentationData, theme: theme, chatBubbleCorners: GGAppearanceTheme.corners(sourceCorners, snapshot: snapshot))
    }

    /// A new theme instance for a non-default snapshot: colors where the snapshot changes them,
    /// and in any case a new identity, so screens that only lay out differently (hidden time,
    /// wide posts…) re-lay out once.
    static func derivedTheme(_ source: PresentationTheme, snapshot: GGAppearanceSnapshot) -> PresentationTheme {
        var rootController = source.rootController
        var list = source.list
        var chatList = source.chatList
        var chat = source.chat
        var actionSheet = source.actionSheet
        var contextMenu = source.contextMenu
        var inAppNotification = source.inAppNotification

        if snapshot.amoled && source.overallDarkAppearance {
            let black = UIColor(rgb: 0x000000)
            let elevated = UIColor(rgb: 0x0e0e0e)
            let raised = UIColor(rgb: 0x141414)
            let pressed = UIColor(rgb: 0x1d1d1d)

            list = list.withUpdated(blocksBackgroundColor: black, modalBlocksBackgroundColor: black, plainBackgroundColor: black, modalPlainBackgroundColor: black, itemBlocksBackgroundColor: elevated, itemModalBlocksBackgroundColor: elevated, itemHighlightedBackgroundColor: pressed)
            chatList = chatList.withUpdated(backgroundColor: black, itemBackgroundColor: black, pinnedItemBackgroundColor: elevated, itemHighlightedBackgroundColor: pressed, pinnedItemHighlightedBackgroundColor: pressed, itemSelectedBackgroundColor: pressed)
            rootController = rootController.withUpdated(
                tabBar: rootController.tabBar.withUpdated(backgroundColor: black),
                navigationBar: rootController.navigationBar.withUpdated(blurredBackgroundColor: black.withAlphaComponent(0.9), opaqueBackgroundColor: black),
                navigationSearchBar: rootController.navigationSearchBar.withUpdated(backgroundColor: black, inputFillColor: raised)
            )
            chat = chat.withUpdated(inputPanel: chat.inputPanel.withUpdated(panelBackgroundColor: black, panelBackgroundColorNoWallpaper: black, inputBackgroundColor: raised))
            actionSheet = actionSheet.withUpdated(opaqueItemBackgroundColor: elevated, opaqueItemHighlightedBackgroundColor: pressed)
            contextMenu = contextMenu.withUpdated(backgroundColor: elevated, itemHighlightedBackgroundColor: pressed)
            inAppNotification = inAppNotification.withUpdated(fillColor: elevated)
        }

        if snapshot.amoledKeyboard {
            // Telegram's own inputs ask for the dark keyboard in any theme, as in the old client; the
            // keyboard itself is painted black by GGAmoledKeyboard. The panels Telegram draws itself go
            // black in a dark theme only (a light theme's icons would vanish on black).
            rootController = rootController.withUpdated(keyboardColor: .dark)
            if source.overallDarkAppearance {
                let black = UIColor(rgb: 0x000000)
                chat = chat.withUpdated(
                    inputMediaPanel: chat.inputMediaPanel.withUpdated(stickersBackgroundColor: black, gifsBackgroundColor: black, backgroundColor: black),
                    inputButtonPanel: chat.inputButtonPanel.withUpdated(panelBackgroundColor: black)
                )
            }
        }

        if snapshot.hideSeparators {
            // An explicit list of every cell and bar hairline the theme owns. Alpha 0 keeps the
            // RGB, so code that derives another color from a separator still gets a sane value.
            func hidden(_ color: UIColor) -> UIColor {
                return color.withAlphaComponent(0.0)
            }
            list = list.withUpdated(itemBlocksSeparatorColor: hidden(list.itemBlocksSeparatorColor), itemPlainSeparatorColor: hidden(list.itemPlainSeparatorColor))
            chatList = chatList.withUpdated(itemSeparatorColor: hidden(chatList.itemSeparatorColor))
            rootController = rootController.withUpdated(
                tabBar: rootController.tabBar.withUpdated(separatorColor: hidden(rootController.tabBar.separatorColor)),
                navigationBar: rootController.navigationBar.withUpdated(separatorColor: hidden(rootController.navigationBar.separatorColor)),
                navigationSearchBar: rootController.navigationSearchBar.withUpdated(separatorColor: hidden(rootController.navigationSearchBar.separatorColor))
            )
            chat = chat.withUpdated(
                inputPanel: chat.inputPanel.withUpdated(panelSeparatorColor: hidden(chat.inputPanel.panelSeparatorColor)),
                inputMediaPanel: chat.inputMediaPanel.withUpdated(panelSeparatorColor: hidden(chat.inputMediaPanel.panelSeparatorColor)),
                inputButtonPanel: chat.inputButtonPanel.withUpdated(panelSeparatorColor: hidden(chat.inputButtonPanel.panelSeparatorColor))
            )
            actionSheet = actionSheet.withUpdated(opaqueItemSeparatorColor: hidden(actionSheet.opaqueItemSeparatorColor))
            contextMenu = contextMenu.withUpdated(itemSeparatorColor: hidden(contextMenu.itemSeparatorColor))
            let expanded = inAppNotification.expandedNotification
            inAppNotification = inAppNotification.withUpdated(expandedNotification: expanded.withUpdated(navigationBar: expanded.navigationBar.withUpdated(separatorColor: hidden(expanded.navigationBar.separatorColor))))
        }

        // Checkmark colors are not put into the theme: it has one color for read and delivered both,
        // so «delivered» drew in the read color. The bubble picks per state (`ggCustomCheckImages`,
        // ChatMessageDateAndStatusNode), the chat list too (`ggChatListCheckmarkColor`, ChatListItem);
        // an automatic color keeps the theme's own.

        if let bubbles = snapshot.bubbles, bubbles.outlineAlpha > 0.0 {
            let message = chat.message
            chat = chat.withUpdated(message: message.withUpdated(
                incoming: message.incoming.withUpdated(bubble: GGAppearanceTheme.outlined(message.incoming.bubble, color: message.incoming.primaryTextColor, alpha: bubbles.outlineAlpha)),
                outgoing: message.outgoing.withUpdated(bubble: GGAppearanceTheme.outlined(message.outgoing.bubble, color: message.outgoing.primaryTextColor, alpha: bubbles.outlineAlpha))
            ))
        }

        let result = PresentationTheme(name: source.name, index: source.index, referenceTheme: source.referenceTheme, overallDarkAppearance: source.overallDarkAppearance, intro: source.intro, passcode: source.passcode, rootController: rootController, list: list, chatList: chatList, chat: chat, actionSheet: actionSheet, contextMenu: contextMenu, inAppNotification: inAppNotification, chart: source.chart, preview: source.preview)
        result.starGift = source.starGift
        result.forceSync = source.forceSync
        return result
    }

    private static func outlined(_ bubble: PresentationThemeBubbleColor, color: UIColor, alpha: Double) -> PresentationThemeBubbleColor {
        let stroke = color.withAlphaComponent(CGFloat(alpha))
        return bubble.withUpdated(
            withWallpaper: bubble.withWallpaper.withUpdated(stroke: stroke),
            withoutWallpaper: bubble.withoutWallpaper.withUpdated(stroke: stroke)
        )
    }

    // MARK: Bubble shape

    /// Per-direction radii of the bubble editor and tail-less bubbles. Bubble images are cached per
    /// theme, and a change of the snapshot makes a new theme, so this runs once per image.
    static func transformBubbleShape(_ shape: inout GGBubbleShape) {
        let snapshot = GGAppearanceSnapshot.current
        if let bubbles = snapshot.bubbles {
            let radius = CGFloat(shape.incoming ? bubbles.incomingRadius : bubbles.outgoingRadius)
            if shape.maxCornerRadius > 0.0 {
                shape.minCornerRadius = min(radius, shape.minCornerRadius * radius / shape.maxCornerRadius)
            } else {
                shape.minCornerRadius = radius
            }
            shape.maxCornerRadius = radius
        }
        if snapshot.hideTails {
            // The corners stay as the neighbours make them (the last bubble of a group keeps its
            // small corner on the merged side); only the tail goes.
            shape.drawsTail = false
        }
    }
}

/// What the transformer was given for each theme it made (the theme and the bubble corners), keyed
/// by the made theme's `chat` object: later transformers of the chain (the chat list style) make new
/// theme objects but pass `chat` through. Everything is held weakly; a few entries at most.
private final class GGDerivedThemeSources {
    private final class Entry {
        weak var resultChat: PresentationThemeChat?
        weak var source: PresentationTheme?
        let corners: PresentationChatBubbleCorners

        init(resultChat: PresentationThemeChat, source: PresentationTheme, corners: PresentationChatBubbleCorners) {
            self.resultChat = resultChat
            self.source = source
            self.corners = corners
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func note(result: PresentationTheme, source: PresentationTheme, corners: PresentationChatBubbleCorners) {
        if result === source {
            return
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.entries.contains(where: { $0.resultChat === result.chat && $0.source === source && $0.corners == corners }) {
            return
        }
        self.entries.removeAll(where: { $0.resultChat == nil || $0.source == nil || $0.resultChat === result.chat })
        if self.entries.count >= 8 {
            self.entries.removeFirst()
        }
        self.entries.append(Entry(resultChat: result.chat, source: source, corners: corners))
    }

    func source(of theme: PresentationTheme) -> (theme: PresentationTheme, corners: PresentationChatBubbleCorners)? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        for entry in self.entries.reversed() {
            if entry.resultChat === theme.chat, let source = entry.source {
                return (source, entry.corners)
            }
        }
        return nil
    }
}

/// Derived themes keyed by (source theme, snapshot). The source is held weakly: a new upstream theme
/// object never matches a dead one's identifier by accident.
private final class GGDerivedThemeCache {
    private final class Entry {
        weak var source: PresentationTheme?
        let snapshot: GGAppearanceSnapshot
        let result: PresentationTheme

        init(source: PresentationTheme, snapshot: GGAppearanceSnapshot, result: PresentationTheme) {
            self.source = source
            self.snapshot = snapshot
            self.result = result
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func theme(for source: PresentationTheme, snapshot: GGAppearanceSnapshot) -> PresentationTheme {
        self.lock.lock()
        if let entry = self.entries.first(where: { $0.source === source && $0.snapshot == snapshot }) {
            let result = entry.result
            self.lock.unlock()
            return result
        }
        self.lock.unlock()

        let result = GGAppearanceTheme.derivedTheme(source, snapshot: snapshot)

        self.lock.lock()
        self.entries.removeAll(where: { $0.source == nil })
        if self.entries.count >= 6 {
            self.entries.removeFirst()
        }
        self.entries.append(Entry(source: source, snapshot: snapshot, result: result))
        self.lock.unlock()
        return result
    }
}
