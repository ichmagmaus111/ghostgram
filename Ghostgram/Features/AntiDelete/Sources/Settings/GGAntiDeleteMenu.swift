import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import GGCore
import GGSettingsUI
import GGFeaturesShared

// Menu rows of «Сообщения › Удалённые и изменённые», the «Сообщения» preview and the bookmark rows
// in «Меню и жесты». One place per setting; titles are computed at display time.

extension GGMenuTabID {
    static let antiDeleteHistory = GGMenuTabID("antiDelete.history")
    static let antiDeleteExclusions = GGMenuTabID("antiDelete.exclusions")
    static let bookmarksAll = GGMenuTabID("bookmarks.all")
}

extension GGMenuSectionID {
    static let antiDeleteEdits = GGMenuSectionID("antiDelete.edits")
    static let antiDeleteStorage = GGMenuSectionID("antiDelete.storage")
}

enum GGAntiDeleteMenu {
    private static var capturesAnything: Bool {
        return GGAntiDeleteSettings.enabled.value || GGAntiDeleteSettings.keepOwn.value || GGAntiDeleteSettings.keepSelfDestructing.value
    }

    private static func percent(_ value: Double) -> String {
        return GGStrings.AntiDelete.Menu.percent(value: "\(Int(value.rounded()))")
    }

    static func register() {
        let main = GGMenuSectionID.main(of: .messagesAntiDelete)

        // MARK: Previews

        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.categoryPreview",
            section: .messagesPreview,
            order: 100,
            title: { "" },
            kind: .preview(.miniChat(GGMiniChatConfiguration(scope: "antiDelete", height: 300.0, content: { context in
                return GGAntiDeleteMenu.previewContent(context)
            })))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.preview",
            section: .preview(of: .messagesAntiDelete),
            order: 100,
            title: { "" },
            kind: .preview(.miniChat(GGMiniChatConfiguration(scope: "antiDelete", height: 300.0, content: { context in
                return GGAntiDeleteMenu.previewContent(context)
            })))
        ))

        // MARK: Deleted messages

        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.enabled",
            section: main,
            order: 100,
            title: { GGStrings.AntiDelete.Menu.enabled },
            subtitle: { GGStrings.AntiDelete.Menu.enabledInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.enabled)),
            searchKeywords: { [GGStrings.AntiDelete.Menu.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.keepOwn",
            section: main,
            order: 200,
            title: { GGStrings.AntiDelete.Menu.keepOwn },
            subtitle: { GGStrings.AntiDelete.Menu.keepOwnInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.keepOwn))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.keepSelfDestructing",
            section: main,
            order: 300,
            title: { GGStrings.AntiDelete.Menu.keepSelfDestructing },
            subtitle: { GGStrings.AntiDelete.Menu.keepSelfDestructingInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.keepSelfDestructing))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.secretChats",
            section: main,
            order: 400,
            title: { GGStrings.AntiDelete.Menu.secretChats },
            subtitle: { GGStrings.AntiDelete.Menu.secretChatsInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.secretChats)),
            isVisible: { _ in GGAntiDeleteMenu.capturesAnything || GGAntiDeleteSettings.editHistory.value }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.keepMedia",
            section: main,
            order: 500,
            title: { GGStrings.AntiDelete.Menu.keepMedia },
            subtitle: { GGStrings.AntiDelete.Menu.keepMediaInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.keepMedia)),
            isVisible: { _ in GGAntiDeleteMenu.capturesAnything }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.transparency",
            section: main,
            order: 600,
            title: { GGStrings.AntiDelete.Menu.transparency },
            kind: .slider(.global(GGAntiDeleteSettings.transparency), range: GGAntiDeleteSettings.transparencyRange, step: 5.0, format: { value in
                return GGAntiDeleteMenu.percent(value)
            })
        ))
        // A reply to a deleted message needs no setting: it always goes as AyuGram's pseudo-reply
        // (an ordinary message with the quote on top) — the preview and «Сохранять удалённые» say so.

        // MARK: Edits and local edits — one section (owner, 2026-10-27: «сожмём вкладку»)

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .antiDeleteEdits, screen: .tab(.messagesAntiDelete), order: 300, header: { GGStrings.AntiDelete.Menu.editsHeader }, footer: { _ in GGStrings.AntiDelete.Menu.editsFooter }))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.editHistory",
            section: .antiDeleteEdits,
            order: 100,
            title: { GGStrings.AntiDelete.Menu.editHistory },
            subtitle: { GGStrings.AntiDelete.Menu.editHistoryInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.editHistory)),
            searchKeywords: { [GGStrings.AntiDelete.Menu.editKeywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.editHistoryInline",
            section: .antiDeleteEdits,
            order: 200,
            title: { GGStrings.AntiDelete.Menu.editHistoryInline },
            subtitle: { GGStrings.AntiDelete.Menu.editHistoryInlineInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.editHistoryInline)),
            isVisible: { _ in GGAntiDeleteSettings.editHistory.value }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.versionsTransparency",
            section: .antiDeleteEdits,
            order: 300,
            title: { GGStrings.AntiDelete.Menu.versionsTransparency },
            kind: .slider(.global(GGAntiDeleteSettings.versionsTransparency), range: GGAntiDeleteSettings.transparencyRange, step: 5.0, format: { value in
                return GGAntiDeleteMenu.percent(value)
            }),
            isVisible: { _ in GGAntiDeleteSettings.editHistory.value && GGAntiDeleteSettings.editHistoryInline.value }
        ))

        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.localEdit",
            section: .antiDeleteEdits,
            order: 500,
            title: { GGStrings.AntiDelete.Menu.localEdit },
            subtitle: { GGStrings.AntiDelete.Menu.localEditInfo },
            kind: .toggle(.global(GGAntiDeleteSettings.localEdit))
        ))

        // MARK: Storage

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .antiDeleteStorage, screen: .tab(.messagesAntiDelete), order: 600, header: { GGStrings.AntiDelete.Menu.storageHeader }, footer: { _ in GGStrings.AntiDelete.Menu.autoClearFooter }))
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: .antiDeleteHistory,
                parent: .tab(.messagesAntiDelete),
                title: { GGStrings.AntiDelete.History.title },
                makeScreen: { context in
                    return ggMakeAntiDeleteHistoryController(context: context.context, kind: .deleted)
                },
                searchKeywords: { [GGStrings.AntiDelete.Menu.historyKeywords] }
            ),
            linkIn: .antiDeleteStorage,
            order: 100,
            subtitle: { GGStrings.AntiDelete.Menu.historyInfo },
            icon: .bundle("Chat/Context Menu/Time"),
            label: { context in
                let deleted = GGAntiDeleteAccounts.shared.summary(account: context.context.account.id, kind: .deleted).totalCount
                let edited = GGAntiDeleteAccounts.shared.summary(account: context.context.account.id, kind: .edited).totalCount
                if deleted + edited == 0 {
                    return nil
                }
                return "\(deleted + edited)"
            }
        )
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: .antiDeleteExclusions,
                parent: .tab(.messagesAntiDelete),
                title: { GGStrings.AntiDelete.Exclusions.title },
                makeScreen: { context in
                    return ggMakeAntiDeleteExclusionsController(context: context.context)
                },
                searchKeywords: { [GGStrings.AntiDelete.Menu.exclusionsKeywords] }
            ),
            linkIn: .antiDeleteStorage,
            order: 200,
            subtitle: { GGStrings.AntiDelete.Menu.exclusionsInfo },
            icon: .bundle("Chat/Context Menu/Ban"),
            label: { context in
                let account = context.accountID
                var count = GGAntiDeleteSettings.excludedPeers.value(for: account).count + GGAntiDeleteSettings.excludedFolders.value(for: account).count
                for setting in [GGAntiDeleteSettings.excludeGroups, GGAntiDeleteSettings.excludeBots, GGAntiDeleteSettings.excludeChannels] where setting.value {
                    count += 1
                }
                return count == 0 ? nil : "\(count)"
            }
        )
        GGMenuRegistry.register(GGMenuRow(
            id: "antiDelete.autoClear",
            section: .antiDeleteStorage,
            order: 300,
            title: { GGStrings.AntiDelete.Menu.autoClear },
            icon: .bundle("Chat/Context Menu/Timer"),
            kind: .choice(.global(GGAntiDeleteSettings.autoClear), options: GGAntiDeleteRetention.allCases.map { retention in
                return GGMenuChoiceOption(value: retention.rawValue, title: { GGAntiDeleteMenu.retentionTitle(retention) })
            })
        ))

        // MARK: Bookmarks («Меню и жесты»)

        let gestures = GGMenuSectionID.main(of: .messagesMenuGestures)
        GGMenuRegistry.register(GGMenuRow(
            id: "bookmarks.enabled",
            section: gestures,
            order: 800,
            title: { GGStrings.Bookmarks.Menu.enabled },
            subtitle: { GGStrings.Bookmarks.Menu.enabledInfo },
            icon: .bundle("Chat/Context Menu/Tag"),
            kind: .toggle(.global(GGBookmarkSettings.enabled)),
            searchKeywords: { [GGStrings.Bookmarks.Menu.keywords] }
        ))
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: .bookmarksAll,
                parent: .tab(.messagesMenuGestures),
                title: { GGStrings.Bookmarks.All.title },
                makeScreen: { context in
                    return ggMakeBookmarksController(context: context.context, peerId: nil)
                },
                searchKeywords: { [GGStrings.Bookmarks.Menu.keywords] }
            ),
            linkIn: gestures,
            order: 900,
            subtitle: { GGStrings.Bookmarks.Menu.allInfo },
            icon: .bundle("Chat/Context Menu/ReadingList")
        )
    }

    static func retentionTitle(_ retention: GGAntiDeleteRetention) -> String {
        switch retention {
        case .never:
            return GGStrings.AntiDelete.AutoClear.never
        case .day:
            return GGStrings.AntiDelete.AutoClear.day
        case .week:
            return GGStrings.AntiDelete.AutoClear.week
        case .month:
            return GGStrings.AntiDelete.AutoClear.month
        case .quarter:
            return GGStrings.AntiDelete.AutoClear.quarter
        case .year:
            return GGStrings.AntiDelete.AutoClear.year
        }
    }

    /// The «Сообщения» preview, as the chat shows it with the current switches: while deleted
    /// messages are kept, a deleted one with the current transparency and a reply to it exactly as
    /// it is sent — AyuGram's pseudo-reply, the quote on top (no author line: a one-to-one chat with
    /// that author); with them off neither exists, as in Telegram. The edited message carries the
    /// history mark only while the history is kept.
    static func previewContent(_ context: GGMenuContext) -> GGMiniChatContent {
        let keepsDeleted = GGAntiDeleteSettings.enabled.value
        let deletedText = GGStrings.AntiDelete.Preview.deletedText
        let transparency = context.displayValue(.global(GGAntiDeleteSettings.transparency))
        var messages: [GGPreviewMessage] = []
        messages.append(GGPreviewMessage(id: 1, isOutgoing: false, text: GGStrings.AntiDelete.Preview.firstText, ageSeconds: 900))
        if keepsDeleted {
            messages.append(GGPreviewMessage(id: 2, isOutgoing: false, text: deletedText, alpha: GGAntiDeleteSettings.alpha(forTransparency: transparency), mark: GGPreviewMark(statusText: GGAntiDeleteDecorations.deletedMark), ageSeconds: 840))
        }
        let historyMark: GGPreviewMark? = GGAntiDeleteSettings.editHistory.value ? GGPreviewMark(statusText: GGAntiDeleteDecorations.historyMark(versionCount: 1)) : nil
        messages.append(GGPreviewMessage(id: 3, isOutgoing: false, text: GGStrings.AntiDelete.Preview.editedText, isEdited: true, mark: historyMark, ageSeconds: 600))
        if keepsDeleted {
            messages.append(GGPreviewMessage(id: 4, isOutgoing: true, text: GGStrings.AntiDelete.Preview.replyText, quote: deletedText, ageSeconds: 300))
        }
        return GGMiniChatContent(header: GGMiniChatContent.sampleHeader(), messages: messages)
    }
}
