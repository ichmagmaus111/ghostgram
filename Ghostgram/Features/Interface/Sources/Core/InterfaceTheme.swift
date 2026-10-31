import Foundation
import UIKit
import SwiftSignalKit
import TelegramPresentationData

/// The PresentationData transformer of this zone (GGThemeHooks.presentationData):
/// - own story ring color;
/// - a new theme instance whenever the chat list / avatar look changed, so every screen re-lays
///   out with the new snapshot (ChatListPresentationData takes the row style when it is created).
/// Derived themes are cached per (upstream theme, theme key): the same input always gives the
/// same output object, so nothing re-lays out when nothing changed. With everything at Telegram's
/// defaults the input is returned as is (turning the last option off goes back to the upstream
/// instance, which is again a change of instance).
enum InterfaceTheme {
    private struct CacheEntry {
        weak var base: PresentationTheme?
        let key: GGInterfaceThemeKey
        let iconRevision: Int
        let rowsRevision: Int
        let result: PresentationTheme
    }

    private static let cache = Atomic<[CacheEntry]>(value: [])

    /// Bumped when the icon pack table changes: glyphs cached per theme must be rebuilt.
    static let iconRevision = Atomic<Int>(value: 0)

    /// Bumped when the chats of «Скрытые превью» change: the rows ask for them on layout only, so a
    /// new theme instance makes them lay out again at once (account-scoped, outside the snapshot).
    static let rowsRevision = Atomic<Int>(value: 0)

    /// The chat list rows answer differently now (main thread): every screen re-lays out.
    static func invalidateRows() {
        let _ = InterfaceTheme.rowsRevision.modify { $0 + 1 }
        GGThemeHooks.invalidate()
    }

    static func transform(_ presentationData: PresentationData) -> PresentationData {
        let snapshot = InterfaceSnapshots.shared.current
        let key = snapshot.themeKey
        let iconRevision = InterfaceTheme.iconRevision.with { $0 }
        let rowsRevision = InterfaceTheme.rowsRevision.with { $0 }
        if key.isUpstream && iconRevision == 0 {
            return presentationData
        }
        let base = presentationData.theme
        if let cached = InterfaceTheme.cache.with({ entries -> PresentationTheme? in
            return entries.first(where: { $0.base === base && $0.key == key && $0.iconRevision == iconRevision && $0.rowsRevision == rowsRevision })?.result
        }) {
            return presentationData.withUpdated(theme: cached)
        }
        let derived = InterfaceTheme.derive(base, snapshot: snapshot)
        let _ = InterfaceTheme.cache.modify { entries -> [CacheEntry] in
            var result = entries.filter { $0.base != nil }
            result.append(CacheEntry(base: base, key: key, iconRevision: iconRevision, rowsRevision: rowsRevision, result: derived))
            if result.count > 6 {
                result.removeFirst(result.count - 6)
            }
            return result
        }
        return presentationData.withUpdated(theme: derived)
    }

    private static func derive(_ base: PresentationTheme, snapshot: GGInterfaceSnapshot) -> PresentationTheme {
        var chatList = base.chatList
        if let ringColor = GGColorHex.color(snapshot.storyRingColor) {
            chatList = chatList.withUpdated(storyUnseenColors: PresentationThemeGradientColors(topColor: ringColor, bottomColor: ringColor))
        }
        // Always a new instance, even when no color changed: the instance is what tells the
        // screens to rebuild with the new snapshot.
        let theme = PresentationTheme(
            name: base.name,
            index: base.index,
            referenceTheme: base.referenceTheme,
            overallDarkAppearance: base.overallDarkAppearance,
            intro: base.intro,
            passcode: base.passcode,
            rootController: base.rootController,
            list: base.list,
            chatList: chatList,
            chat: base.chat,
            actionSheet: base.actionSheet,
            contextMenu: base.contextMenu,
            inAppNotification: base.inAppNotification,
            chart: base.chart,
            preview: base.preview
        )
        theme.forceSync = base.forceSync
        theme.starGift = base.starGift
        return theme
    }
}
