import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import EntityKeyboard
import EmojiStatusSelectionComponent
import GGCore
import GGFeaturesShared

// MARK: - Custom recent reactions (custom_recent_reactions)

enum GGReactionScreens {
    static let maxCount = 16

    /// The user's set: order, delete, add from Telegram's reactions, from recently used ones
    /// (custom emoji included) or a typed emoji.
    static func makeEditor(context: AccountContext) -> ViewController {
        weak var controllerRef: ViewController?
        let files = Promise<[Int64: TelegramMediaFile]>([:])
        files.set(InterfaceSettings.customReactionsList.signal
        |> mapToSignal { list -> Signal<[Int64: TelegramMediaFile], NoError> in
            return GGCustomReactions.resolvedFiles(context: context, entries: list.compactMap(GGCustomReactions.Entry.init))
        })
        let box = GGReactionEditorBox()
        let update = files.get()
        |> deliverOnMainQueue
        |> map { value -> Void in
            box.files = value
            return Void()
        }

        let actions = GGListActions(select: { id in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            switch id {
            case "add.typed":
                ggPresentTextPrompt(from: controllerRef, title: GGStrings.Interface.Reactions.typePrompt, text: "", placeholder: "👍", cancel: presentationData.strings.Common_Cancel, done: presentationData.strings.Common_Done, completion: { text in
                    guard let emoji = GGReactionScreens.singleEmoji(text) else {
                        controllerRef?.present(ggToast(context: context, text: GGStrings.Interface.Reactions.notEmoji), in: .window(.root))
                        return
                    }
                    GGReactionScreens.add("e:" + emoji)
                })
            case "add.standard":
                (controllerRef?.navigationController as? NavigationController)?.pushViewController(GGReactionScreens.makePicker(context: context, recent: false))
            case "add.recent":
                (controllerRef?.navigationController as? NavigationController)?.pushViewController(GGReactionScreens.makePicker(context: context, recent: true))
            case "add.customEmoji":
                GGReactionScreens.pickCustomEmoji(context: context, from: controllerRef)
            case "reset":
                ggConfirmDestructive(context: context, from: controllerRef, title: GGStrings.Interface.Common.resetTitle, text: GGStrings.Interface.Reactions.resetText, confirm: GGStrings.Interface.Common.reset, action: {
                    InterfaceSettings.customReactionsList.reset()
                })
            default:
                let list = InterfaceSettings.customReactionsList.value
                guard list.contains(id) else {
                    return
                }
                var buttons: [(title: String, isDestructive: Bool, action: () -> Void)] = []
                buttons.append((presentationData.strings.Common_Delete, true, {
                    InterfaceSettings.customReactionsList.set(list.filter { $0 != id })
                }))
                ggPresentActionSheet(context: context, from: controllerRef, buttons: buttons)
            }
        }, reorder: { ids in
            // Values the list cannot show keep their place at the end.
            let rest = InterfaceSettings.customReactionsList.value.filter { !ids.contains($0) }
            InterfaceSettings.customReactionsList.set(ids + rest)
        })
        let controller = ggMakeInterfaceList(context: context, title: { GGStrings.Interface.Reactions.editorTitle }, update: update, sections: { _ in
            let list = InterfaceSettings.customReactionsList.value
            var rows: [GGListRow] = [.header(GGStrings.Interface.Reactions.listHeader)]
            for value in list {
                guard let entry = GGCustomReactions.Entry(value) else {
                    continue
                }
                let title = GGReactionScreens.title(entry, files: box.files)
                let label = GGReactionScreens.label(entry)
                if list.count > 1 {
                    rows.append(.reorderable(id: value, title: title, label: label))
                } else {
                    rows.append(.disclosure(id: value, title: title, label: label, icon: nil))
                }
            }
            if list.isEmpty {
                rows.append(.footer(GGStrings.Interface.Reactions.empty))
            } else {
                rows.append(.footer(GGStrings.Interface.Reactions.listFooter))
            }
            var sections = [GGListSection(rows)]
            if list.count < GGReactionScreens.maxCount {
                sections.append(GGListSection([
                    .action(id: "add.standard", title: GGStrings.Interface.Reactions.addStandard, isDestructive: false),
                    .action(id: "add.recent", title: GGStrings.Interface.Reactions.addRecent, isDestructive: false),
                    .action(id: "add.customEmoji", title: GGStrings.Interface.Reactions.addCustomEmoji, isDestructive: false),
                    .action(id: "add.typed", title: GGStrings.Interface.Reactions.addTyped, isDestructive: false)
                ]))
            }
            if !InterfaceSettings.customReactionsList.isDefault {
                sections.append(GGListSection([.action(id: "reset", title: GGStrings.Interface.Common.reset, isDestructive: true)]))
            }
            return sections
        }, actions: actions)
        controllerRef = controller
        return controller
    }

    static func title(_ entry: GGCustomReactions.Entry, files: [Int64: TelegramMediaFile]) -> String {
        switch entry {
        case let .builtin(value):
            return value
        case let .custom(id):
            if let file = files[id] {
                for attribute in file.attributes {
                    if case let .CustomEmoji(_, _, alt, _) = attribute, !alt.isEmpty {
                        return alt
                    }
                }
            }
            return GGStrings.Interface.Reactions.customEmoji
        }
    }

    static func label(_ entry: GGCustomReactions.Entry) -> String {
        if case .custom = entry {
            return GGStrings.Interface.Reactions.customLabel
        }
        return ""
    }

    private static func add(_ value: String) {
        var list = InterfaceSettings.customReactionsList.value
        guard GGCustomReactions.Entry(value) != nil, !list.contains(value), list.count < GGReactionScreens.maxCount else {
            return
        }
        list.append(value)
        InterfaceSettings.customReactionsList.set(GGCustomReactions.normalized(list))
    }

    /// Any custom emoji from the user's packs, through Telegram's own emoji picker (the one the
    /// profile background icon uses); the file is remembered, nothing is resolved later.
    private static func pickCustomEmoji(context: AccountContext, from controller: ViewController?) {
        guard let controller else {
            return
        }
        let sourceView: UIView = controller.displayNode.view
        let selection = EmojiStatusSelectionController(
            context: context,
            mode: .backgroundSelection(completion: { file in
                guard let file else {
                    return
                }
                GGCustomReactions.remember(file)
                GGReactionScreens.add("doc:\(file.fileId.id)")
            }),
            sourceView: sourceView,
            emojiContent: EmojiPagerContentComponent.emojiInputData(
                context: context,
                animationCache: context.animationCache,
                animationRenderer: context.animationRenderer,
                isStandalone: false,
                subject: .backgroundIcon,
                hasTrending: false,
                topReactionItems: [],
                areUnicodeEmojiEnabled: false,
                areCustomEmojiEnabled: true,
                chatPeerId: context.account.peerId
            ),
            currentSelection: nil,
            destinationItemView: {
                return nil
            }
        )
        controller.present(selection, in: .window(.root))
    }

    /// One emoji (a single extended grapheme cluster that renders as emoji), without U+FE0F.
    static func singleEmoji(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first else {
            return nil
        }
        let isEmoji = character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) })
        if !isEmoji {
            return nil
        }
        return trimmed.replacingOccurrences(of: "\u{FE0F}", with: "")
    }

    /// Telegram's standard reactions, or the recently used ones (custom emoji included). A check
    /// adds or removes the reaction from the set.
    private static func makePicker(context: AccountContext, recent: Bool) -> ViewController {
        let items = Promise<[(value: String, title: String, label: String)]>([])
        if recent {
            items.set(combineLatest(
                context.engine.data.subscribe(TelegramEngine.EngineData.Item.OrderedLists.ListItems(collectionId: Namespaces.OrderedItemList.CloudRecentReactions)),
                context.engine.data.subscribe(TelegramEngine.EngineData.Item.OrderedLists.ListItems(collectionId: Namespaces.OrderedItemList.CloudTopReactions))
            )
            |> map { recentItems, topItems -> [(value: String, title: String, label: String)] in
                var result: [(value: String, title: String, label: String)] = []
                var seen = Set<String>()
                for item in recentItems + topItems {
                    guard let reaction = item.contents.get(RecentReactionItem.self) else {
                        continue
                    }
                    switch reaction.content {
                    case let .builtin(value):
                        let key = "e:" + value.replacingOccurrences(of: "\u{FE0F}", with: "")
                        if seen.insert(key).inserted {
                            result.append((key, value, ""))
                        }
                    case let .custom(accessor):
                        let file = accessor._parse()
                        GGCustomReactions.remember(file)
                        let key = "doc:\(file.fileId.id)"
                        if seen.insert(key).inserted {
                            result.append((key, GGReactionScreens.title(.custom(file.fileId.id), files: [file.fileId.id: file]), GGStrings.Interface.Reactions.customLabel))
                        }
                    case .stars:
                        break
                    }
                }
                return result
            })
        } else {
            items.set(context.engine.stickers.availableReactions()
            |> map { available -> [(value: String, title: String, label: String)] in
                guard let available else {
                    return []
                }
                var result: [(value: String, title: String, label: String)] = []
                for reaction in available.reactions where reaction.isEnabled {
                    if case let .builtin(value) = reaction.value {
                        result.append(("e:" + value.replacingOccurrences(of: "\u{FE0F}", with: ""), value + "  " + reaction.title, reaction.isPremium ? GGStrings.Interface.Reactions.premiumLabel : ""))
                    }
                }
                return result
            })
        }
        let box = GGReactionPickerBox()
        let update = items.get()
        |> deliverOnMainQueue
        |> map { value -> Void in
            box.items = value
            return Void()
        }
        let actions = GGListActions(select: { value in
            var list = InterfaceSettings.customReactionsList.value
            if let index = list.firstIndex(of: value) {
                list.remove(at: index)
                InterfaceSettings.customReactionsList.set(list)
            } else {
                GGReactionScreens.add(value)
            }
        })
        return ggMakeInterfaceList(context: context, title: { recent ? GGStrings.Interface.Reactions.addRecent : GGStrings.Interface.Reactions.addStandard }, update: update, sections: { _ in
            let list = Set(InterfaceSettings.customReactionsList.value)
            var rows: [GGListRow] = []
            for item in box.items {
                rows.append(.check(id: item.value, title: item.title, subtitle: item.label.isEmpty ? nil : item.label, checked: list.contains(item.value)))
            }
            if rows.isEmpty {
                rows.append(.footer(GGStrings.Interface.Reactions.nothingToAdd))
            }
            return [GGListSection(rows)]
        }, actions: actions)
    }
}

private final class GGReactionEditorBox {
    var files: [Int64: TelegramMediaFile] = [:]
}

private final class GGReactionPickerBox {
    var items: [(value: String, title: String, label: String)] = []
}

// MARK: - Quick buttons (bind_buttons)

enum GGQuickButtonScreens {
    /// Which of the registered buttons are shown. A button is on unless the user switched it off.
    static func makeScreen(context: AccountContext) -> ViewController {
        let actions = GGListActions(toggle: { id, value in
            var hidden = InterfaceSettings.bindButtonsHidden.value
            if value {
                hidden.removeAll(where: { $0 == id })
            } else if !hidden.contains(id) {
                hidden.append(id)
            }
            InterfaceSettings.bindButtonsHidden.set(hidden)
        })
        return ggMakeInterfaceList(context: context, title: { GGStrings.Interface.Binds.buttonsTitle }, sections: { _ in
            let hidden = Set(InterfaceSettings.bindButtonsHidden.value)
            var rows: [GGListRow] = [.header(GGStrings.Interface.Binds.buttonsHeader)]
            for action in GGQuickActions.all {
                rows.append(.toggle(id: action.id, title: action.title(), value: !hidden.contains(action.id), enabled: true))
            }
            rows.append(.footer(GGStrings.Interface.Binds.buttonsFooter))
            return [GGListSection(rows)]
        }, actions: actions)
    }
}

// MARK: - Chats without message preview (chatlist_tweaks)

enum GGHiddenPreviewScreens {
    /// The chats of «Только выбранные». Adding goes through Telegram's own chat picker.
    static func makeScreen(context: AccountContext) -> ViewController {
        weak var controllerRef: ViewController?
        let account = context.account.id.gg
        let peers = Promise<[EnginePeer]>([])
        peers.set(InterfaceSettings.hidePreviewPeers.signal(for: account)
        |> mapToSignal { keys -> Signal<[EnginePeer], NoError> in
            let ids = keys.map { EnginePeer.Id(ggKey: $0) }
            if ids.isEmpty {
                return .single([])
            }
            return context.engine.data.subscribe(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))))
            |> map { result -> [EnginePeer] in
                // The setting is a set: a stable order (by name) keeps rows from swapping places
                // whenever a chat is added or removed.
                return GGHiddenPreviewScreens.sorted(ids.compactMap { result[$0] ?? nil })
            }
        })
        let box = GGHiddenPreviewBox()
        let update = peers.get()
        |> deliverOnMainQueue
        |> map { value -> Void in
            box.peers = value
            return Void()
        }
        let actions = GGListActions(select: { id in
            if id == "add" {
                GGHiddenPreviewScreens.pickChat(context: context, from: controllerRef)
                return
            }
            guard let peer = box.peers.first(where: { "\($0.id.ggKey)" == id }) else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            ggPresentActionSheet(context: context, from: controllerRef, title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder), buttons: [(GGStrings.Interface.ChatList.showPreviewAgain, true, {
                var keys = InterfaceSettings.hidePreviewPeers.value(for: account)
                keys.remove(peer.id.ggKey)
                InterfaceSettings.hidePreviewPeers.set(keys, for: account)
                GGHiddenPreviewScreens.chatsDidChange()
            })])
        })
        let controller = ggMakeInterfaceList(context: context, title: { GGStrings.Interface.ChatList.hiddenPreviewChats }, update: update, sections: { presentationData in
            var rows: [GGListRow] = [.header(GGStrings.Interface.ChatList.hiddenPreviewHeader)]
            for peer in box.peers {
                rows.append(.peer(id: "\(peer.id.ggKey)", peer: peer, title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder), label: ""))
            }
            rows.append(.action(id: "add", title: GGStrings.Interface.ChatList.addChat, isDestructive: false))
            rows.append(.footer(GGStrings.Interface.ChatList.hiddenPreviewFooter))
            return [GGListSection(rows)]
        }, actions: actions)
        controllerRef = controller
        return controller
    }

    private static func pickChat(context: AccountContext, from controller: ViewController?) {
        let account = context.account.id.gg
        let picker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeRecent, .doNotSearchMessages], hasContactSelector: false, title: GGStrings.Interface.ChatList.addChat))
        picker.peerSelected = { [weak picker] peer, _ in
            var keys = InterfaceSettings.hidePreviewPeers.value(for: account)
            keys.insert(peer.id.ggKey)
            InterfaceSettings.hidePreviewPeers.set(keys, for: account)
            GGHiddenPreviewScreens.chatsDidChange()
            picker?.dismiss()
        }
        (controller?.navigationController as? NavigationController)?.pushViewController(picker)
    }

    /// The rows of the chat list ask for the chosen chats only on layout: lay them out again now.
    private static func chatsDidChange() {
        if InterfaceSettings.hidePreview.value && InterfaceSettings.hidePreviewScope.value == "selected" {
            InterfaceTheme.invalidateRows()
        }
    }

    static func sorted(_ peers: [EnginePeer]) -> [EnginePeer] {
        return peers.sorted(by: { lhs, rhs in
            let order = lhs.compactDisplayTitle.localizedStandardCompare(rhs.compactDisplayTitle)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.id.toInt64() < rhs.id.toInt64()
        })
    }
}

private final class GGHiddenPreviewBox {
    var peers: [EnginePeer] = []
}
