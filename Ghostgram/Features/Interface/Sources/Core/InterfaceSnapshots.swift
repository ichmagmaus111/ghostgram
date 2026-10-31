import Foundation
import UIKit
import SwiftSignalKit
import TelegramPresentationData
import AvatarNode
import TabBarComponent
import ChatListTitleView
import GGCore

/// Everything the hot paths of this zone read, computed from InterfaceSettings in one place.
/// Recomputed when any setting changes (`GGSettingsStore.revision`, a dozen plain reads), then
/// published at once; cells, layout and scroll only read the published value.
struct GGInterfaceSnapshot: Equatable {
    var rowStyle: GGChatListRowStyle
    var avatarShape: GGAvatarShape
    var tabBarStyle: GGTabBarStyle
    var titleStyle: GGChatListTitleStyle
    /// "RRGGBB" or "" (the theme's colors).
    var storyRingColor: String
    var hideSearchField: Bool
    var folderAllChatsTitle: String
    var compactFolderTabs: Bool
    var folderBarHeightOffset: CGFloat
    var foldersAtBottom: Bool
    var hideAllChats: Bool
    var tabOrder: [String]
    var hiddenTabs: [String]
    var hiddenSettingsItems: Set<String>
    var settingsItemsOrder: [String]
    var inputBarGeometry: GGInputBarGeometry
    var characterCounter: Bool
    var formattingToolbar: Bool
    var typingAnimation: GGTypingAnimationParameters?
    /// What the chat list rows ask on their layout (hidden previews, swipe actions); "" = Telegram's.
    /// Part of the theme key, so a change re-lays out every row at once instead of row by row as new
    /// messages arrive.
    var rowContentKey: String

    /// What the published theme depends on: a change re-emits PresentationData with a new theme
    /// instance, which recreates ChatListPresentationData (row style) and redraws avatars.
    var themeKey: GGInterfaceThemeKey {
        return GGInterfaceThemeKey(rowStyle: self.rowStyle, avatarShape: self.avatarShape, storyRingColor: self.storyRingColor, titleStyle: self.titleStyle, hideSearchField: self.hideSearchField, folderKey: "\(self.folderAllChatsTitle)|\(self.compactFolderTabs)|\(self.folderBarHeightOffset)|\(self.foldersAtBottom)", rowContentKey: self.rowContentKey)
    }

    static func rowContentKey(hidePreview: Bool, hidePreviewScope: String, swipeActions: String) -> String {
        var parts: [String] = []
        if hidePreview {
            parts.append("preview:\(hidePreviewScope)")
        }
        if swipeActions != "all" {
            parts.append("swipe:\(swipeActions)")
        }
        return parts.joined(separator: "|")
    }

    static func compute() -> GGInterfaceSnapshot {
        let compact = InterfaceSettings.compactList.value
        var rowScale = CGFloat(Double(InterfaceSettings.rowScale.value) ?? 100.0) / 100.0
        var avatarScale = CGFloat(Double(InterfaceSettings.avatarScale.value) ?? 100.0) / 100.0
        if compact {
            // SG-B1: the compact list is a preset on top of the user's own sizes.
            rowScale *= 0.84
            avatarScale *= 0.8
        }
        let previewLines = Int(InterfaceSettings.previewLines.value) ?? 2
        let rowStyle = GGChatListRowStyle(
            avatarScale: max(0.5, min(1.4, avatarScale)),
            heightScale: max(0.6, min(1.4, rowScale)),
            previewLines: max(1, min(3, previewLines)),
            hidesStoryRing: InterfaceSettings.hideStoryRings.value,
            hidesEmojiStatus: InterfaceSettings.hideEmojiStatus.value,
            senderAvatarSize: InterfaceSettings.senderAvatars.value ? 18.0 : 0.0
        )

        let corners = InterfaceSettings.avatarCorners.value
        let squareness = CGFloat(GGAvatarCorners.squareness(corners))
        let avatarShape = GGAvatarShape(
            squareAvatars: GGAvatarCorners.isSquare(corners),
            cornerFraction: 0.5 + (0.12 - 0.5) * squareness,
            roundForums: InterfaceSettings.roundAvatarsInForums.value
        )

        let titles = InterfaceSettings.tabTitles.value
        var titlesRevision = 0
        if !titles.isEmpty {
            titlesRevision = titles.keys.sorted().map { "\($0)=\(titles[$0] ?? "")" }.joined(separator: "\n").hashValue
            if titlesRevision == 0 {
                titlesRevision = 1
            }
        }
        let tabBarStyle = GGTabBarStyle(
            hidesTitles: InterfaceSettings.hideTabTitles.value,
            isWide: InterfaceSettings.wideTabBar.value,
            fitsItems: !InterfaceSettings.wideTabBar.value,
            hidesBar: InterfaceSettings.hideTabBar.value,
            heightOffset: CGFloat(GGTabBarLayout.clampHeightOffset(InterfaceSettings.tabBarHeightOffset.value)),
            bottomOffset: CGFloat(GGTabBarLayout.clampBottomOffset(InterfaceSettings.tabBarBottomOffset.value)),
            titlesRevision: titlesRevision
        )

        let titleStyle = GGChatListTitleStyle(
            hidesConnectionText: InterfaceSettings.hideConnectionText.value
        )

        var typingAnimation: GGTypingAnimationParameters?
        if InterfaceSettings.typingAnimation.value {
            typingAnimation = GGTypingAnimationParameters(
                preset: InterfaceSettings.typingAnimationPreset.value,
                intensity: InterfaceSettings.typingAnimationIntensity.value,
                speed: InterfaceSettings.typingAnimationSpeed.value,
                scale: InterfaceSettings.typingAnimationScale.value,
                offset: InterfaceSettings.typingAnimationOffset.value,
                glow: InterfaceSettings.typingAnimationGlow.value
            )
        }

        return GGInterfaceSnapshot(
            rowStyle: rowStyle,
            avatarShape: avatarShape,
            tabBarStyle: tabBarStyle,
            titleStyle: titleStyle,
            storyRingColor: GGColorHex.normalized(InterfaceSettings.storyRingColor.value) ?? "",
            hideSearchField: InterfaceSettings.hideSearchField.value,
            folderAllChatsTitle: InterfaceSettings.allChatsTitle.value,
            compactFolderTabs: InterfaceSettings.compactFolderTabs.value,
            folderBarHeightOffset: CGFloat(min(24.0, max(0.0, InterfaceSettings.folderBarHeightOffset.value))),
            foldersAtBottom: InterfaceSettings.foldersAtBottom.value,
            hideAllChats: InterfaceSettings.hideAllChats.value,
            tabOrder: GGTabBarLayout.normalizedOrder(InterfaceSettings.tabOrder.value),
            hiddenTabs: InterfaceSettings.hiddenTabs.value.filter { GGTabBarLayout.hideableIds.contains($0) },
            hiddenSettingsItems: Set(InterfaceSettings.hiddenSettingsItems.value),
            settingsItemsOrder: InterfaceSettings.settingsItemsOrder.value,
            inputBarGeometry: InterfaceSettings.inputBarGeometry.value.clamped,
            characterCounter: InterfaceSettings.characterCounter.value,
            formattingToolbar: InterfaceSettings.formattingToolbar.value,
            typingAnimation: typingAnimation,
            rowContentKey: GGInterfaceSnapshot.rowContentKey(hidePreview: InterfaceSettings.hidePreview.value, hidePreviewScope: InterfaceSettings.hidePreviewScope.value, swipeActions: InterfaceSettings.swipeActions.value)
        )
    }
}

struct GGInterfaceThemeKey: Equatable {
    var rowStyle: GGChatListRowStyle
    var avatarShape: GGAvatarShape
    var storyRingColor: String
    var titleStyle: GGChatListTitleStyle
    var hideSearchField: Bool
    var folderKey: String
    var rowContentKey: String

    var isUpstream: Bool {
        let upstreamLook: Bool = self.rowStyle == GGChatListRowStyle.upstream && self.avatarShape == GGAvatarShape.upstream && self.titleStyle == GGChatListTitleStyle.upstream
        let upstreamContent: Bool = self.storyRingColor.isEmpty && !self.hideSearchField && self.folderKey == GGInterfaceThemeKey.upstreamFolderKey && self.rowContentKey.isEmpty
        return upstreamLook && upstreamContent
    }

    static let upstreamFolderKey = "default|false|0.0|false"
}

final class InterfaceSnapshots {
    static let shared = InterfaceSnapshots()

    private let box: GGSnapshotBox<GGInterfaceSnapshot>
    private var disposable: Disposable?

    /// Side effects a change needs, run on the main thread after the new snapshot is published.
    var tabBarStyleChanged: (() -> Void)?
    var tabArrangementChanged: (() -> Void)?
    var settingsTabChanged: (() -> Void)?

    private init() {
        self.box = GGSnapshotBox(GGInterfaceSnapshot.compute())
    }

    var current: GGInterfaceSnapshot {
        return self.box.value
    }

    /// Main thread, once from `register()`. The subscription lives as long as the app.
    func start() {
        assert(Thread.isMainThread)
        if self.disposable != nil {
            return
        }
        self.disposable = (GGSettingsStore.shared.revision
        |> map { _ -> GGInterfaceSnapshot in
            return GGInterfaceSnapshot.compute()
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] snapshot in
            self?.publish(snapshot)
        })
    }

    private func publish(_ snapshot: GGInterfaceSnapshot) {
        let previous = self.box.swap(snapshot)
        if previous == snapshot {
            return
        }
        if previous.themeKey != snapshot.themeKey {
            GGThemeHooks.invalidate()
        }
        if previous.tabBarStyle != snapshot.tabBarStyle {
            self.tabBarStyleChanged?()
        }
        if previous.tabOrder != snapshot.tabOrder || previous.hiddenTabs != snapshot.hiddenTabs {
            self.tabArrangementChanged?()
        }
        if previous.hiddenSettingsItems != snapshot.hiddenSettingsItems || previous.settingsItemsOrder != snapshot.settingsItemsOrder {
            self.settingsTabChanged?()
        }
    }
}
