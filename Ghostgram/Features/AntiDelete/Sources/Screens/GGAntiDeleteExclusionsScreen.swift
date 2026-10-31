import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatListUI
import LocalizedPeerData
import GGCore
import GGFeaturesShared

// «Исключения»: kinds of chats (groups, bots, channels), chats picked by hand, folders of THIS
// account. Folder membership is computed by the app (category folders included) and kept in an
// account setting the notification service reads too; it follows folder changes while the
// account runs and is refreshed when the app comes back.

enum GGAntiDeleteFolderSync {
    private static var started: [AccountRecordId: Disposable] = [:]
    private static var activeAccountsDisposable: Disposable?

    /// Recomputes the chats of the excluded folders of one account.
    static func sync(context: AccountContext) -> Signal<Never, NoError> {
        let account = context.account.id.gg
        let folderIds = GGAntiDeleteSettings.excludedFolders.value(for: account)
        if folderIds.isEmpty {
            return Signal { subscriber in
                if !GGAntiDeleteSettings.excludedFolderPeers.value(for: account).isEmpty {
                    GGAntiDeleteSettings.excludedFolderPeers.set([], for: account)
                }
                subscriber.putCompletion()
                return EmptyDisposable
            }
        }
        let accountPeerId = context.account.peerId
        let postbox = context.account.postbox
        return context.engine.peers.currentChatListFilters()
        |> take(1)
        |> mapToSignal { filters -> Signal<Set<GGPeerKey>, NoError> in
            var selected: [ChatListFilterData] = []
            for filter in filters {
                if case let .filter(id, _, _, data) = filter, folderIds.contains(id) {
                    selected.append(data)
                }
            }
            return postbox.transaction { transaction -> Set<GGPeerKey> in
                var result = Set<GGPeerKey>()
                for var data in selected {
                    // Membership must not change on every read or mute.
                    data.excludeRead = false
                    data.excludeMuted = false
                    let predicate = chatListFilterPredicate(filter: data, accountPeerId: accountPeerId)
                    for peer in transaction.getChatListPeers(groupId: .root, filterPredicate: predicate, additionalFilter: nil) {
                        result.insert(peer.id.ggKey)
                    }
                    if !data.excludeArchived {
                        for peer in transaction.getChatListPeers(groupId: Namespaces.PeerGroup.archive, filterPredicate: predicate, additionalFilter: nil) {
                            result.insert(peer.id.ggKey)
                        }
                    }
                    for peerId in data.includePeers.peers + data.includePeers.pinnedPeers {
                        result.insert(peerId.ggKey)
                    }
                }
                return result
            }
        }
        |> deliverOn(GGAntiDeleteAccounts.shared.queue)
        |> map { peers -> Void in
            if GGAntiDeleteSettings.excludedFolderPeers.value(for: account) != peers {
                GGAntiDeleteSettings.excludedFolderPeers.set(peers, for: account)
            }
            return Void()
        }
        |> ignoreValues
    }

    /// Follows the folders and the excluded-folder setting of every running account (main thread).
    static func start(sharedContext: SharedAccountContext) {
        if GGAntiDeleteFolderSync.activeAccountsDisposable != nil {
            return
        }
        GGAntiDeleteFolderSync.activeAccountsDisposable = (sharedContext.activeAccountContexts
        |> deliverOnMainQueue).start(next: { accounts in
            var alive = Set<AccountRecordId>()
            for (id, context, _) in accounts.accounts {
                alive.insert(id)
                if GGAntiDeleteFolderSync.started[id] != nil {
                    continue
                }
                let trigger = combineLatest(context.engine.peers.updatedChatListFilters(), GGAntiDeleteSettings.excludedFolders.signal(for: id.gg))
                // A burst of folder updates becomes one recomputation (the previous wait is dropped).
                GGAntiDeleteFolderSync.started[id] = (trigger
                |> mapToSignal { _ -> Signal<Never, NoError> in
                    return Signal<Void, NoError>.single(Void())
                    |> delay(1.0, queue: GGAntiDeleteAccounts.shared.queue)
                    |> mapToSignal { _ -> Signal<Never, NoError> in
                        return GGAntiDeleteFolderSync.sync(context: context)
                    }
                }).start()
            }
            for (id, disposable) in GGAntiDeleteFolderSync.started where !alive.contains(id) {
                disposable.dispose()
                GGAntiDeleteFolderSync.started.removeValue(forKey: id)
            }
        })
    }

    /// Foreground refresh: chats move between category folders without a folder change.
    static func refreshAll(sharedContext: SharedAccountContext) -> Signal<Never, NoError> {
        return sharedContext.activeAccountContexts
        |> take(1)
        |> mapToSignal { accounts -> Signal<Never, NoError> in
            var signal: Signal<Never, NoError> = .complete()
            for (_, context, _) in accounts.accounts {
                signal = signal |> then(GGAntiDeleteFolderSync.sync(context: context))
            }
            return signal
        }
    }
}

func ggMakeAntiDeleteExclusionsController(context: AccountContext) -> ViewController {
    let account = context.account.id.gg
    weak var weakController: ViewController?

    let peers = GGAntiDeleteSettings.excludedPeers.signal(for: account)
    |> mapToSignal { keys -> Signal<[EnginePeer], NoError> in
        let ids = keys.sorted().map { PeerId(ggKey: $0) }
        return context.engine.data.get(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
        |> map { result -> [EnginePeer] in
            return ids.compactMap { id in
                return result[id] ?? nil
            }
        }
    }

    // A folder hidden from the app (a locked secret folder) is not listed; an exclusion already set
    // on it stays in force (the folder sync reads every folder).
    let model = combineLatest(queue: .mainQueue(), GGSettingsStore.shared.revision, peers, ggChatListFolders(context.engine.peers.updatedChatListFilters(), context: context))
    |> map { _, peers, filters -> GGADScreenModel in
        var model = GGADScreenModel(title: .text(GGStrings.AntiDelete.Exclusions.title), sections: [])

        let kinds: [(id: String, title: String, setting: GGSetting<Bool>)] = [
            ("groups", GGStrings.AntiDelete.Exclusions.groups, GGAntiDeleteSettings.excludeGroups),
            ("bots", GGStrings.AntiDelete.Exclusions.bots, GGAntiDeleteSettings.excludeBots),
            ("channels", GGStrings.AntiDelete.Exclusions.channels, GGAntiDeleteSettings.excludeChannels)
        ]
        var kindRows: [GGADRow] = [GGADRow(id: "kinds.header", kind: .header(GGStrings.AntiDelete.Exclusions.kindsHeader))]
        for item in kinds {
            kindRows.append(GGADRow(id: "kind.\(item.id)", kind: .toggle(title: item.title, value: item.setting.value)))
            let setting = item.setting
            model.toggle["kind.\(item.id)"] = { value in
                setting.set(value)
            }
        }
        kindRows.append(GGADRow(id: "kind.edits", kind: .toggle(title: GGStrings.AntiDelete.Exclusions.editsInExclusions, value: GGAntiDeleteSettings.editsInExclusions.value)))
        model.toggle["kind.edits"] = { value in
            GGAntiDeleteSettings.editsInExclusions.set(value)
        }
        kindRows.append(GGADRow(id: "kinds.footer", kind: .footer(GGStrings.AntiDelete.Exclusions.kindsFooter)))
        model.sections.append(GGADSection(id: "kinds", rows: kindRows))

        var chatRows: [GGADRow] = [GGADRow(id: "chats.header", kind: .header(GGStrings.AntiDelete.Exclusions.chatsHeader))]
        chatRows.append(GGADRow(id: "chats.add", kind: .action(title: GGStrings.AntiDelete.Exclusions.addChat, destructive: false)))
        model.tap["chats.add"] = {
            let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeSavedMessages, .doNotSearchMessages], hasContactSelector: false, title: GGStrings.AntiDelete.Exclusions.addChat))
            controller.peerSelected = { [weak controller] peer, _ in
                var current = GGAntiDeleteSettings.excludedPeers.value(for: account)
                current.insert(peer.id.ggKey)
                GGAntiDeleteSettings.excludedPeers.set(current, for: account)
                controller?.dismiss()
            }
            (weakController?.navigationController as? NavigationController)?.pushViewController(controller)
        }
        for peer in peers {
            let rowId = "chat.\(peer.id.ggKey.stringValue)"
            chatRows.append(GGADRow(id: rowId, kind: .peer(peer: peer, text: "", label: "", removeTitle: GGStrings.AntiDelete.Exclusions.remove)))
            let key = peer.id.ggKey
            model.remove[rowId] = {
                var current = GGAntiDeleteSettings.excludedPeers.value(for: account)
                current.remove(key)
                GGAntiDeleteSettings.excludedPeers.set(current, for: account)
            }
        }
        chatRows.append(GGADRow(id: "chats.footer", kind: .footer(GGStrings.AntiDelete.Exclusions.chatsFooter)))
        model.sections.append(GGADSection(id: "chats", rows: chatRows))

        var folderRows: [GGADRow] = [GGADRow(id: "folders.header", kind: .header(GGStrings.AntiDelete.Exclusions.foldersHeader))]
        let excludedFolders = GGAntiDeleteSettings.excludedFolders.value(for: account)
        var hasFolders = false
        for filter in filters {
            guard case let .filter(id, title, emoticon, _) = filter else {
                continue
            }
            hasFolders = true
            let rowId = "folder.\(id)"
            folderRows.append(GGADRow(id: rowId, kind: .toggle(title: (emoticon.map { $0 + " " } ?? "") + title.text, value: excludedFolders.contains(id))))
            model.toggle[rowId] = { value in
                var current = GGAntiDeleteSettings.excludedFolders.value(for: account)
                if value {
                    current.insert(id)
                } else {
                    current.remove(id)
                }
                GGAntiDeleteSettings.excludedFolders.set(current, for: account)
                let _ = GGAntiDeleteFolderSync.sync(context: context).start()
            }
        }
        folderRows.append(GGADRow(id: "folders.footer", kind: .footer(hasFolders ? GGStrings.AntiDelete.Exclusions.foldersFooter : GGStrings.AntiDelete.Exclusions.foldersEmpty)))
        model.sections.append(GGADSection(id: "folders", rows: folderRows))
        return model
    }

    let controller = ggMakeADListController(context: context, model: model)
    weakController = controller
    return controller
}
