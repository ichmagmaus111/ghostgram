import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import AlertUI
import GGCore
import GGSettingsUI
import GGFeaturesShared

extension GGMenuTabID {
    static let ghostActivities = GGMenuTabID("ghostMode.activities")
}

extension GGMenuSectionID {
    static let ghostActivitiesMain = GGMenuSectionID("ghostMode.activities.main")
    static let ghostExceptionTypes = GGMenuSectionID("ghostMode.exceptions.types")
}

/// Rows of the «Приватность» category (PLAN §2.1): preview, the ghost-mode group and its rows, the
/// exceptions and send-delay tabs, «Следы»; plus «Скрыть сообщения заблокированных» in the
/// «Сообщения › Чаты» section where PLAN §2.2 puts it.
enum GGGhostMenu {
    static func register() {
        GGGhostPreview.register()
        GGGhostMenu.registerGhostSection()
        GGGhostMenu.registerActivitiesTab()
        GGGhostMenu.registerExceptionsTab()
        GGGhostMenu.registerSendDelayTab()
        GGGhostMenu.registerTraces()
        GGGhostMenu.registerChatsSection()
    }

    // MARK: Ghost mode

    private static func registerGhostSection() {
        let section = GGMenuSectionID.privacyGhostMode

        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.group",
            section: section,
            order: 100,
            title: { GGStrings.GhostMode.Menu.group },
            subtitle: { GGStrings.GhostMode.Menu.groupInfo },
            kind: .expandableGroup(master: .account(GGGhostSettings.isEnabled), children: [
                GGMenuRow(id: "ghostMode.hideReadReceipts", section: section, order: 100, title: { GGStrings.GhostMode.Menu.hideReadReceipts }, subtitle: { GGStrings.GhostMode.Menu.hideReadReceiptsInfo }, kind: .toggle(.account(GGGhostSettings.hideReadReceipts)), searchKeywords: { [GGStrings.GhostMode.Menu.keywordRead] }),
                GGMenuRow(id: "ghostMode.hideStoryViews", section: section, order: 200, title: { GGStrings.GhostMode.Menu.hideStoryViews }, subtitle: { GGStrings.GhostMode.Menu.hideStoryViewsInfo }, kind: .toggle(.account(GGGhostSettings.hideStoryViews)), searchKeywords: { [GGStrings.GhostMode.Menu.keywordStories] }),
                GGMenuRow(id: "ghostMode.hideOnline", section: section, order: 300, title: { GGStrings.GhostMode.Menu.hideOnline }, subtitle: { GGStrings.GhostMode.Menu.hideOnlineInfo }, kind: .toggle(.account(GGGhostSettings.hideOnline)), searchKeywords: { [GGStrings.GhostMode.Menu.keywordOnline] }),
                GGMenuRow(id: "ghostMode.hideTyping", section: section, order: 400, title: { GGStrings.GhostMode.Menu.hideTyping }, subtitle: { GGStrings.GhostMode.Menu.hideTypingInfo }, kind: .toggle(.account(GGGhostSettings.hideTyping)), searchKeywords: { [GGStrings.GhostMode.Menu.keywordTyping] })
            ]),
            searchKeywords: { [GGStrings.GhostMode.Menu.keywordGhost] }
        ))

        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.readOnAction",
            section: section,
            order: 300,
            title: { GGStrings.GhostMode.Menu.readOnAction },
            subtitle: { GGStrings.GhostMode.Menu.readOnActionInfo },
            kind: .toggle(.account(GGGhostSettings.readOnAction)),
            isEnabled: { context in
                return GGGhostSettings.isEnabled.value(for: context.accountID)
            }
        ))

        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.alwaysOnline",
            section: section,
            order: 400,
            title: { GGStrings.GhostMode.Menu.alwaysOnline },
            subtitle: { GGStrings.GhostMode.Menu.alwaysOnlineInfo },
            kind: .toggle(.account(GGGhostSettings.alwaysOnline)),
            searchKeywords: { [GGStrings.GhostMode.Menu.keywordOnline] },
            // Grey while ghost mode hides "online": the switch must not look active when it is not.
            isEnabled: { context in
                return !GGGhostPolicy.isFunctionOn(.online, account: context.accountID)
            }
        ))

        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.readLocally",
            section: section,
            order: 700,
            title: { GGStrings.GhostMode.Menu.readLocally },
            subtitle: { GGStrings.GhostMode.Menu.readLocallyInfo },
            icon: .bundle("Chat/Context Menu/ReadAll"),
            kind: .action({ context in
                GGGhostMenu.confirm(context, title: GGStrings.GhostMode.Menu.readLocallyConfirmTitle, text: GGStrings.GhostMode.Menu.readLocallyConfirmText, action: GGStrings.GhostMode.Menu.readLocally, perform: {
                    let accountContext = context.context
                    let _ = (GGGhostReadAll.readLocally(context: accountContext)
                    |> deliverOnMainQueue).start(next: { count in
                        context.presentToast(GGStrings.GhostMode.Menu.readLocallyDone(count: count))
                    })
                })
            }),
            searchKeywords: { [GGStrings.GhostMode.Menu.keywordRead] },
            label: { context in
                let count = GGGhostReadLedger.shared.localReadCount(account: context.accountID)
                return count > 0 ? "\(count)" : nil
            }
        ))

        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.readOnServer",
            section: section,
            order: 800,
            title: { GGStrings.GhostMode.Menu.readOnServer },
            subtitle: { GGStrings.GhostMode.Menu.readOnServerInfo },
            icon: .bundle("Chat/Context Menu/MarkAsRead"),
            kind: .action({ context in
                GGGhostMenu.confirm(context, title: GGStrings.GhostMode.Menu.readOnServerConfirmTitle, text: GGStrings.GhostMode.Menu.readOnServerConfirmText, action: GGStrings.GhostMode.Menu.readOnServer, perform: {
                    let accountContext = context.context
                    let _ = (GGGhostReadAll.readOnServer(context: accountContext)
                    |> deliverOnMainQueue).start(next: { count in
                        context.presentToast(GGStrings.GhostMode.Menu.readOnServerDone(count: count))
                    })
                })
            }),
            searchKeywords: { [GGStrings.GhostMode.Menu.keywordRead] },
            label: { context in
                let pending = GGGhostReadLedger.shared.pendingKeys(account: context.accountID)
                let count = pending.kept.count + pending.local.count
                return count > 0 ? "\(count)" : nil
            }
        ))
    }

    static func confirm(_ context: GGMenuContext, title: String, text: String, action: String, perform: @escaping () -> Void) {
        let presentationData = context.presentationData
        let alert = textAlertController(context: context.context, title: title, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: action, action: perform)
        ])
        context.present(alert)
    }

    // MARK: Activity statuses

    static func activityTitle(_ kind: GGGhostActivityKind) -> String {
        switch kind {
        case .typingText:
            return GGStrings.GhostMode.Activity.typingText
        case .recordingVoice:
            return GGStrings.GhostMode.Activity.recordingVoice
        case .recordingInstantVideo:
            return GGStrings.GhostMode.Activity.recordingInstantVideo
        case .uploadingInstantVideo:
            return GGStrings.GhostMode.Activity.uploadingInstantVideo
        case .uploadingVideo:
            return GGStrings.GhostMode.Activity.uploadingVideo
        case .uploadingPhoto:
            return GGStrings.GhostMode.Activity.uploadingPhoto
        case .uploadingFile:
            return GGStrings.GhostMode.Activity.uploadingFile
        case .choosingSticker:
            return GGStrings.GhostMode.Activity.choosingSticker
        case .playingGame:
            return GGStrings.GhostMode.Activity.playingGame
        case .speakingInGroupCall:
            return GGStrings.GhostMode.Activity.speakingInGroupCall
        case .interactingWithEmoji:
            return GGStrings.GhostMode.Activity.interactingWithEmoji
        case .seeingEmojiInteraction:
            return GGStrings.GhostMode.Activity.seeingEmojiInteraction
        }
    }

    private static func registerActivitiesTab() {
        // Shown only while «Не отправлять «печатает»» is on: an empty tab has no link (no dead screen).
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: .ghostActivities,
                parent: .category(.privacy),
                title: { GGStrings.GhostMode.Menu.activities },
                topView: GGMenuTopView(content: .emoji("✍️"), text: { GGStrings.GhostMode.Menu.activitiesInfo }),
                searchKeywords: { [GGStrings.GhostMode.Menu.keywordTyping] }
            ),
            linkIn: .privacyGhostMode,
            order: 200,
            subtitle: { GGStrings.GhostMode.Menu.activitiesInfo },
            icon: .bundle("Chat/Context Menu/Edit"),
            label: { context in
                let account = context.accountID
                var shown = 0
                for kind in GGGhostActivityKind.allCases where GGGhostSettings.shownActivity(kind).value(for: account) {
                    shown += 1
                }
                return GGStrings.GhostMode.Menu.activitiesShown(shown: "\(shown)", total: "\(GGGhostActivityKind.allCases.count)")
            }
        )
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: .ghostActivitiesMain,
            screen: .tab(.ghostActivities),
            order: 200,
            header: { GGStrings.GhostMode.Menu.activitiesHeader },
            footer: { _ in GGStrings.GhostMode.Menu.activitiesFooter },
            isVisible: { context in
                return GGGhostSettings.hideTyping.value(for: context.accountID)
            }
        ))
        var order = 100
        for kind in GGGhostActivityKind.allCases {
            GGMenuRegistry.register(GGMenuRow(
                id: "ghostMode.activityShown.\(kind.rawValue)",
                section: .ghostActivitiesMain,
                order: order,
                title: { GGGhostMenu.activityTitle(kind) },
                kind: .toggle(.account(GGGhostSettings.shownActivity(kind)))
            ))
            order += 100
        }
    }

    // MARK: Exceptions

    /// PLAN §2.1: «Чаты / Папки / Типы» as a segment in the navbar of the skeleton's tab. Chats and
    /// folders are runtime rows of their sections (GGGhostExceptionRows); the types are settings.
    private static func registerExceptionsTab() {
        let tab = GGMenuTabID.privacyGhostExceptions
        GGMenuRegistry.register(segments: [
            GGMenuSegment(id: "chats", title: { GGStrings.GhostMode.Exceptions.chats }),
            GGMenuSegment(id: "folders", title: { GGStrings.GhostMode.Exceptions.folders }),
            GGMenuSegment(id: "types", title: { GGStrings.GhostMode.Exceptions.typesSegment })
        ], for: tab)

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: GGGhostExceptionRows.chatsSection,
            screen: .tab(tab),
            order: 300,
            segment: "chats",
            footer: { _ in GGStrings.GhostMode.Exceptions.chatsInfo }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.exceptions.add",
            section: GGGhostExceptionRows.chatsSection,
            order: 100,
            title: { GGStrings.GhostMode.Exceptions.add },
            icon: .bundle("Chat/Context Menu/AddUser"),
            kind: .action({ context in
                GGGhostExceptionRows.presentPicker(context)
            }),
            searchKeywords: { [GGStrings.GhostMode.Exceptions.chatsInfo] },
            label: { context in
                let count = GGGhostSettings.exceptions.value(for: context.accountID).count
                return count > 0 ? "\(count)" : nil
            }
        ))
        GGMenuRegistry.register(dynamicRowsIn: GGGhostExceptionRows.chatsSection, { context in
            return GGGhostExceptionRows.chatRows(context)
        })

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: GGGhostExceptionRows.foldersSection,
            screen: .tab(tab),
            order: 400,
            segment: "folders",
            header: { GGStrings.GhostMode.Exceptions.foldersInfo },
            footer: { _ in GGStrings.GhostMode.Exceptions.foldersFooter }
        ))
        GGMenuRegistry.register(dynamicRowsIn: GGGhostExceptionRows.foldersSection, { context in
            return GGGhostExceptionRows.folderRows(context)
        })

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: .ghostExceptionTypes,
            screen: .tab(tab),
            order: 500,
            segment: "types",
            header: { GGStrings.GhostMode.Exceptions.typesHeader },
            footer: { _ in GGStrings.GhostMode.Exceptions.typesFooter }
        ))
        GGMenuRegistry.register(GGMenuRow(id: "ghostMode.exceptAllChannels", section: .ghostExceptionTypes, order: 100, title: { GGStrings.GhostMode.Exceptions.allChannels }, kind: .toggle(.account(GGGhostSettings.exceptAllChannels))))
        GGMenuRegistry.register(GGMenuRow(id: "ghostMode.exceptAllGroups", section: .ghostExceptionTypes, order: 200, title: { GGStrings.GhostMode.Exceptions.allGroups }, kind: .toggle(.account(GGGhostSettings.exceptAllGroups))))
    }

    // MARK: Send delay

    private static func registerSendDelayTab() {
        let main = GGMenuSectionID.main(of: .privacySendDelay)
        GGMenuRegistry.register(GGMenuRow(
            id: "sendDelay.isEnabled",
            section: main,
            order: 100,
            title: { GGStrings.GhostMode.SendDelay.toggle },
            subtitle: { GGStrings.GhostMode.SendDelay.toggleInfo },
            kind: .toggle(.account(GGGhostSettings.sendDelayEnabled))
        ))
        // One delay for text and media since 2026-10-27 (were two sliders).
        GGMenuRegistry.register(GGMenuRow(
            id: "sendDelay.seconds",
            section: main,
            order: 200,
            title: { GGStrings.GhostMode.SendDelay.delay },
            kind: .slider(.account(GGGhostSettings.sendDelaySeconds), range: GGSendDelaySeconds.range, step: 1.0, format: { value in
                return GGStrings.GhostMode.SendDelay.seconds(count: Int(value))
            }),
            isVisible: { context in
                return GGGhostSettings.sendDelayEnabled.value(for: context.accountID)
            }
        ))
    }

    // MARK: Traces

    private static func registerTraces() {
        GGMenuRegistry.register(GGMenuRow(id: "ghostMode.confirmCalls", section: .privacyTraces, order: 100, title: { GGStrings.GhostMode.Traces.confirmCalls }, subtitle: { GGStrings.GhostMode.Traces.confirmCallsInfo }, kind: .toggle(.global(GGGhostSettings.confirmCalls))))
        GGMenuRegistry.register(GGMenuRow(id: "ghostMode.warnBeforeStories", section: .privacyTraces, order: 200, title: { GGStrings.GhostMode.Traces.warnBeforeStories }, subtitle: { GGStrings.GhostMode.Traces.warnBeforeStoriesInfo }, kind: .toggle(.global(GGGhostSettings.warnBeforeStories))))
        GGMenuRegistry.register(GGMenuRow(id: "ghostMode.hidePhoneInSettings", section: .privacyTraces, order: 300, title: { GGStrings.GhostMode.Traces.hidePhone }, subtitle: { GGStrings.GhostMode.Traces.hidePhoneInfo }, kind: .toggle(.global(GGGhostSettings.hidePhoneInSettings))))
    }

    // MARK: Messages › Chats

    private static func registerChatsSection() {
        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.hideBlockedMessages",
            section: .messagesChats,
            order: 450,
            title: { GGStrings.GhostMode.Blocked.toggle },
            subtitle: { GGStrings.GhostMode.Blocked.toggleInfo },
            kind: .toggle(.account(GGGhostSettings.hideBlockedMessages))
        ))
    }
}
