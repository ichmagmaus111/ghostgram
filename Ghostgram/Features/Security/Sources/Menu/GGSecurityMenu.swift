import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ItemListPeerItem
import LocalizedPeerData
import GGCore
import GGSettingsUI
import GGFeaturesShared

/// «Безопасность»: «Защита чатов», «Код-пароль», «Аккаунты». «Двойное дно» registers nothing (not
/// ported, owner 2026-10-22), so that tab is not shown. The category, and the export / import / reset
/// of the settings, ask the common check while any protection is on — switching a protection off is
/// what an intruder with an unlocked phone would do.
enum GGSecurityMenu {
    static let chatsSection = GGMenuSectionID("security.chatProtection.chats")
    static let folderSection = GGMenuSectionID("security.chatProtection.folder")
    static let folderListSection = GGMenuSectionID("security.chatProtection.folderList")
    static let moreSection = GGMenuSectionID("security.chatProtection.more")
    static let passcodeOptionsSection = GGMenuSectionID("security.passcode.options")
    static let accountSettingsSection = GGMenuSectionID("security.accounts.settings")

    static func register() {
        GGSecurityMenu.registerAccessGate()
        GGSecurityMenu.registerChatProtection()
        GGSecurityMenu.registerPasscode()
        GGSecurityMenu.registerAccounts()
    }

    // MARK: Access

    /// A protection is on: entering «Безопасность» or exporting / importing / resetting needs the check.
    static func isAnyProtectionOn(account: GGAccountID) -> Bool {
        if GGSecuritySharedSettings.chatLockEnabled.value || GGSecuritySettings.accountSwitchAuth.value || GGSecuritySettings.passcodeLockOnLaunch.value {
            return true
        }
        return GGSecuritySettings.secretFolderId.value(for: account) != 0
    }

    private static let guardedActions: Set<String> = ["menu.export", "menu.import", "menu.reset"]

    private static func registerAccessGate() {
        GGMenuAccessGates.gate.register({ request, proceed in
            let isSecurity = request.path.contains(.category(.security)) && !request.unlocked.contains(.category(.security))
            var isGuardedAction = false
            if case let .action(rowId) = request.target {
                isGuardedAction = GGSecurityMenu.guardedActions.contains(rowId)
            }
            guard isSecurity || isGuardedAction else {
                return false
            }
            if !GGSecurityMenu.isAnyProtectionOn(account: request.context.account.id.gg) {
                return false
            }
            GGLocalAuthGate.shared.authenticate(context: request.context, reason: GGStrings.Security.Auth.reasonSettings, completion: { granted in
                if granted {
                    proceed()
                }
            })
            return true
        }, order: 100)
    }

    // MARK: Защита чатов

    private static func registerChatProtection() {
        let tab = GGMenuTabID.securityChatProtection
        let main = GGMenuSectionID.main(of: tab)
        let enabled: (GGMenuContext) -> Bool = { _ in GGSecuritySharedSettings.chatLockEnabled.value }

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: GGSecurityMenu.chatsSection,
            screen: .tab(tab),
            order: 250,
            footer: { _ in GGStrings.Security.ChatLock.footer },
            isVisible: enabled
        ))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGSecurityMenu.folderSection, screen: .tab(tab), order: 300, header: { GGStrings.Security.Folder.header }, footer: { _ in GGStrings.Security.Folder.footer }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGSecurityMenu.folderListSection, screen: .tab(tab), order: 350, header: { GGStrings.Security.Folder.chooseHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGSecurityMenu.moreSection, screen: .tab(tab), order: 400, footer: { _ in GGStrings.Security.Screenshot.footer }))

        GGMenuRegistry.register(GGMenuRow(
            id: "security.chatLock.enabled",
            section: main,
            order: 100,
            title: { GGStrings.Security.ChatLock.toggle },
            subtitle: { GGStrings.Security.ChatLock.toggleInfo },
            kind: .toggle(.global(GGSecuritySharedSettings.chatLockEnabled)),
            searchKeywords: { [GGStrings.Security.ChatLock.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.chatLock.allChats",
            section: main,
            order: 200,
            title: { GGStrings.Security.ChatLock.allChats },
            subtitle: { GGStrings.Security.ChatLock.allChatsInfo },
            kind: .toggle(.global(GGSecuritySharedSettings.chatLockAllChats)),
            isVisible: enabled
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.chatLock.autolock",
            section: main,
            order: 300,
            title: { GGStrings.Security.ChatLock.autolock },
            subtitle: { GGStrings.Security.ChatLock.autolockInfo },
            kind: .toggle(.global(GGSecuritySettings.chatLockAutolock)),
            isVisible: enabled
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.chatLock.autolockTimeout",
            section: main,
            order: 400,
            title: { GGStrings.Security.ChatLock.timeout },
            kind: .choice(.global(GGSecuritySettings.chatLockAutolockTimeout), options: [
                GGMenuChoiceOption(value: "0", title: { GGStrings.Security.ChatLock.timeoutImmediately }),
                GGMenuChoiceOption(value: "15", title: { GGStrings.Security.ChatLock.timeoutSeconds(count: 15) }),
                GGMenuChoiceOption(value: "30", title: { GGStrings.Security.ChatLock.timeoutSeconds(count: 30) }),
                GGMenuChoiceOption(value: "60", title: { GGStrings.Security.ChatLock.timeoutMinutes(count: 1) }),
                GGMenuChoiceOption(value: "300", title: { GGStrings.Security.ChatLock.timeoutMinutes(count: 5) })
            ]),
            isVisible: { _ in GGSecuritySharedSettings.chatLockEnabled.value && GGSecuritySettings.chatLockAutolock.value }
        ))

        // The chosen chats of the account.
        GGMenuRegistry.register(GGMenuRow(
            id: "security.chatLock.choose",
            section: GGSecurityMenu.chatsSection,
            order: 100,
            title: { GGStrings.Security.ChatLock.choose },
            icon: .bundle("Chat/Context Menu/AddUser"),
            kind: .action({ context in
                GGSecurityMenu.presentChatPicker(context)
            }),
            isVisible: { _ in !GGSecuritySharedSettings.chatLockAllChats.value },
            label: { context in
                let count = GGSecuritySharedSettings.chatLockPeers.value(for: context.accountID).count
                return count > 0 ? "\(count)" : nil
            }
        ))
        GGMenuRegistry.register(dynamicRowsIn: GGSecurityMenu.chatsSection, { context in
            return GGSecurityMenu.chatRows(context)
        })

        // Secret folder.
        GGMenuRegistry.register(GGMenuRow(
            id: "security.secretFolder.open",
            section: GGSecurityMenu.folderSection,
            order: 100,
            title: { GGStrings.Security.Folder.open },
            icon: .bundle("Chat/Context Menu/Lock"),
            kind: .action({ context in
                GGSecretFolder.shared.open(context)
            }),
            isVisible: { context in GGSecuritySettings.secretFolderId.value(for: context.accountID) != 0 },
            searchKeywords: { [GGStrings.Security.Folder.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.secretFolder.protectChats",
            section: GGSecurityMenu.folderSection,
            order: 200,
            title: { GGStrings.Security.Folder.protectChats },
            subtitle: { GGStrings.Security.Folder.protectChatsInfo },
            kind: .toggle(.account(GGSecuritySettings.secretFolderProtectChats)),
            isVisible: { context in GGSecuritySettings.secretFolderId.value(for: context.accountID) != 0 }
        ))
        GGMenuRegistry.register(dynamicRowsIn: GGSecurityMenu.folderListSection, { context in
            return GGSecurityMenu.folderRows(context)
        })

        // Accounts and screenshots.
        GGMenuRegistry.register(GGMenuRow(
            id: "security.accountSwitchAuth",
            section: GGSecurityMenu.moreSection,
            order: 100,
            title: { GGStrings.Security.Accounts.switchAuth },
            subtitle: { GGStrings.Security.Accounts.switchAuthInfo },
            kind: .toggle(.global(GGSecuritySettings.accountSwitchAuth))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.screenshotPrivacy",
            section: GGSecurityMenu.moreSection,
            order: 200,
            title: { GGStrings.Security.Screenshot.toggle },
            subtitle: { GGStrings.Security.Screenshot.toggleInfo },
            kind: .toggle(.global(GGSecuritySettings.screenshotPrivacy)),
            searchKeywords: { [GGStrings.Security.Screenshot.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.screenshotPrivacyChatList",
            section: GGSecurityMenu.moreSection,
            order: 300,
            title: { GGStrings.Security.Screenshot.chatList },
            kind: .toggle(.global(GGSecuritySettings.screenshotPrivacyChatList)),
            isVisible: { _ in GGSecuritySettings.screenshotPrivacy.value }
        ))
    }

    /// «Выбрать чаты»: Telegram's chat picker over the chats protected so far.
    private static func presentChatPicker(_ menuContext: GGMenuContext) {
        let context = menuContext.context
        let account = context.account.id.gg
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var selected = Set<EnginePeer.Id>()
        for key in GGSecuritySharedSettings.chatLockPeers.value(for: account) {
            selected.insert(PeerId(ggKey: key))
        }
        let controller = context.sharedContext.makeContactMultiselectionController(ContactMultiselectionControllerParams(context: context, mode: .chatSelection(ContactMultiselectionControllerMode.ChatSelection(
            title: GGStrings.Security.ChatLock.choose,
            searchPlaceholder: presentationData.strings.Common_Search,
            selectedChats: selected,
            additionalCategories: nil,
            chatListFilters: nil
        )), alwaysEnabled: true))
        let _ = (controller.result
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak controller] result in
            guard case let .result(peerIds, _) = result else {
                controller?.dismiss()
                return
            }
            var keys = Set<GGPeerKey>()
            for peerId in peerIds {
                if case let .peer(value) = peerId {
                    keys.insert(value.ggKey)
                }
            }
            GGSecuritySharedSettings.chatLockPeers.set(keys, for: account)
            controller?.dismiss()
        })
        menuContext.present(controller, arguments: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }

    /// The protected chats of the account, sorted by name; swipe to remove.
    private static func chatRows(_ providerContext: GGMenuContext) -> Signal<[GGMenuRow], NoError> {
        let context = providerContext.context
        let account = context.account.id.gg
        let revealed = ValuePromise<EnginePeer.Id?>(nil, ignoreRepeated: true)
        let peers: Signal<[EnginePeer], NoError> = GGSecuritySharedSettings.chatLockPeers.signal(for: account)
        |> map { keys -> [EnginePeer.Id] in
            return keys.map { PeerId(ggKey: $0) }
        }
        |> mapToSignal { peerIds -> Signal<[EnginePeer], NoError> in
            return context.engine.data.subscribe(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
            |> map { map -> [EnginePeer] in
                return map.values.compactMap { $0 }
            }
        }
        return combineLatest(peers, revealed.get(), context.sharedContext.presentationData, GGSecuritySharedSettings.chatLockAllChats.signal)
        |> map { peers, revealedPeerId, presentationData, allChats -> [GGMenuRow] in
            if allChats {
                return []
            }
            let sorted = peers.sorted(by: { lhs, rhs in
                let lhsTitle = lhs.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                let rhsTitle = rhs.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            })
            var rows: [GGMenuRow] = []
            for (index, peer) in sorted.enumerated() {
                let peerId = peer.id
                let isRevealed = revealedPeerId == peerId
                rows.append(GGMenuRow(id: "security.chatLock.peer.\(peerId.ggKey.stringValue)", section: GGSecurityMenu.chatsSection, order: 1000 + index, title: { "" }, kind: .custom({ rowContext in
                    let presentationData = rowContext.presentationData
                    let remove: (EnginePeer.Id) -> Void = { peerId in
                        var keys = GGSecuritySharedSettings.chatLockPeers.value(for: account)
                        keys.remove(peerId.ggKey)
                        GGSecuritySharedSettings.chatLockPeers.set(keys, for: account)
                    }
                    return ItemListPeerItem(presentationData: rowContext.itemListPresentationData, systemStyle: .glass, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, context: rowContext.context, peer: peer, presence: nil, text: .none, label: .none, editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: isRevealed), revealOptions: ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .destructive, title: GGStrings.Security.ChatLock.remove, action: {
                        remove(peerId)
                    })]), switchValue: nil, enabled: true, selectable: false, sectionId: rowContext.sectionId, action: nil, setPeerIdWithRevealedOptions: { peerId, fromPeerId in
                        if peerId != nil || fromPeerId != nil {
                            revealed.set(peerId)
                        }
                    }, removePeer: { peerId in
                        remove(peerId)
                    })
                })))
            }
            return rows
        }
    }

    /// The account's folders as a single choice («Нет» first).
    private static func folderRows(_ providerContext: GGMenuContext) -> Signal<[GGMenuRow], NoError> {
        let context = providerContext.context
        let account = context.account.id.gg
        return combineLatest(GGSecretFolder.folderChoices(context: context), GGSecuritySettings.secretFolderId.signal(for: account))
        |> map { folders, selectedId -> [GGMenuRow] in
            var choices: [(Int32, String?)] = [(0, nil)]
            for (id, title) in folders {
                choices.append((id, title))
            }
            var rows: [GGMenuRow] = []
            for (index, choice) in choices.enumerated() {
                let id = choice.0
                let title = choice.1
                let checked = id == selectedId
                rows.append(GGMenuRow(id: "security.secretFolder.choice.\(id)", section: GGSecurityMenu.folderListSection, order: 1000 + index, title: { title ?? GGStrings.Security.Folder.none }, kind: .custom({ rowContext in
                    return ItemListCheckboxItem(presentationData: rowContext.itemListPresentationData, systemStyle: .glass, title: title ?? GGStrings.Security.Folder.none, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: rowContext.sectionId, action: {
                        if GGSecuritySettings.secretFolderId.value(for: account) != id {
                            GGSecuritySettings.secretFolderId.set(id, for: account)
                            // A newly chosen folder starts locked.
                            GGSecretFolder.shared.lockAll()
                        }
                    })
                })))
            }
            if folders.isEmpty {
                rows.append(GGMenuRow(id: "security.secretFolder.empty", section: GGSecurityMenu.folderListSection, order: 5000, title: { "" }, kind: .custom({ rowContext in
                    return ItemListTextItem(presentationData: rowContext.itemListPresentationData, text: .plain(GGStrings.Security.Folder.noFolders), sectionId: rowContext.sectionId)
                })))
            }
            return rows
        }
    }

    // MARK: Код-пароль

    private static func registerPasscode() {
        let tab = GGMenuTabID.securityPasscode
        let main = GGMenuSectionID.main(of: tab)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGSecurityMenu.passcodeOptionsSection, screen: .tab(tab), order: 300, footer: { _ in GGStrings.Security.Passcode.footer }))

        GGMenuRegistry.register(GGMenuRow(
            id: "security.passcode.open",
            section: main,
            order: 100,
            title: { GGStrings.Security.Passcode.open },
            icon: .bundle("Chat/Context Menu/Lock"),
            kind: .action({ context in
                GGPasscodeExtras.openTelegramPasscode(context)
            }),
            searchKeywords: { [GGStrings.Security.Passcode.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.passcode.lockNow",
            section: main,
            order: 200,
            title: { GGStrings.Security.Passcode.lockNow },
            subtitle: { GGStrings.Security.Passcode.lockNowInfo },
            kind: .action({ context in
                GGPasscodeExtras.lockNow(context)
            })
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.passcode.lockOnLaunch",
            section: GGSecurityMenu.passcodeOptionsSection,
            order: 100,
            title: { GGStrings.Security.Passcode.lockOnLaunch },
            subtitle: { GGStrings.Security.Passcode.lockOnLaunchInfo },
            kind: .toggle(.global(GGSecuritySettings.passcodeLockOnLaunch))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.passcode.moreAutolockOptions",
            section: GGSecurityMenu.passcodeOptionsSection,
            order: 200,
            title: { GGStrings.Security.Passcode.moreAutolock },
            subtitle: { GGStrings.Security.Passcode.moreAutolockInfo },
            kind: .toggle(.global(GGSecuritySettings.passcodeMoreAutolockOptions))
        ))
    }

    // MARK: Аккаунты

    private static func registerAccounts() {
        let tab = GGMenuTabID.securityAccounts
        let main = GGMenuSectionID.main(of: tab)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGSecurityMenu.accountSettingsSection, screen: .tab(tab), order: 300, header: { GGStrings.Security.AccountSettings.header }, footer: { _ in GGStrings.Security.AccountSettings.footer }))

        GGMenuRegistry.register(GGMenuRow(
            id: "security.accounts.headerButton",
            section: main,
            order: 100,
            title: { GGStrings.Security.Accounts.headerButton },
            subtitle: { GGStrings.Security.Accounts.headerButtonInfo },
            kind: .toggle(.global(GGSecuritySettings.accountsHeaderButton))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "security.accounts.copySettings",
            section: GGSecurityMenu.accountSettingsSection,
            order: 100,
            title: { GGStrings.Security.AccountSettings.copy },
            icon: .bundle("Chat/Context Menu/Copy"),
            kind: .action({ context in
                GGAccountSettingsCopy.present(context)
            }),
            searchKeywords: { [GGStrings.Security.AccountSettings.keywords] }
        ))
    }
}
