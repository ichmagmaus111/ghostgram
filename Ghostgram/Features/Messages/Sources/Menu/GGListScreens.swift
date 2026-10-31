import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import PresentationDataUtils
import PromptUI
import GGCore
import GGSettingsUI
import GGFeaturesShared

// MARK: - Replacement rules

/// One rule set (the old visible and hidden systems are merged). A rule is added or edited with
/// two prompts; the setting is written once per completed edit, never per keystroke.
func ggMakeReplacementRulesScreen(menuContext: GGMenuContext) -> ViewController {
    let context = menuContext.context
    func edit(index: Int?) {
        let rules = GGOutgoingPipeline.replacementRules.value
        let current = index.flatMap { $0 < rules.count ? rules[$0] : nil }
        menuContext.present(promptController(context: context, text: GGStrings.Sending.Rules.sourcePrompt, value: current?.source, characterLimit: 128, apply: { source in
            guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else {
                return
            }
            menuContext.present(promptController(context: context, text: GGStrings.Sending.Rules.replacementPrompt, value: current?.replacement, characterLimit: 512, apply: { replacement in
                guard let replacement else {
                    return
                }
                var updated = GGOutgoingPipeline.replacementRules.value
                let rule = GGTextReplacementRule(source: source, replacement: replacement)
                if let index, index < updated.count {
                    updated[index] = rule
                } else {
                    updated.removeAll(where: { $0.source.lowercased() == source.lowercased() })
                    updated.append(rule)
                }
                GGOutgoingPipeline.replacementRules.set(updated)
            }))
        }))
    }
    return ggMakeEditableListScreen(context: context, content: {
        let items = GGOutgoingPipeline.replacementRules.value.enumerated().map { index, rule in
            return GGEditableListItem(id: "\(index)", title: rule.source + " → " + rule.replacement)
        }
        return GGEditableListContent(title: GGStrings.Sending.Rules.title, addTitle: GGStrings.Sending.Rules.add, emptyText: GGStrings.Sending.Rules.empty, footer: GGStrings.Sending.Rules.footer, items: items)
    }, add: {
        edit(index: nil)
    }, select: { id in
        guard let index = Int(id) else {
            return
        }
        ggPresentActionSheet(context: context, title: nil, actions: [
            (GGStrings.Sending.Rules.edit, false, {
                edit(index: index)
            }),
            (GGStrings.Sending.Rules.delete, true, {
                var updated = GGOutgoingPipeline.replacementRules.value
                if index < updated.count {
                    updated.remove(at: index)
                    GGOutgoingPipeline.replacementRules.set(updated)
                }
            })
        ], present: { menuContext.present($0) })
    })
}

// MARK: - Keyword filter

func ggMakeKeywordsScreen(menuContext: GGMenuContext) -> ViewController {
    let context = menuContext.context
    return ggMakeEditableListScreen(context: context, content: {
        let items = GGMessagesSettings.keywords.value.enumerated().map { index, word in
            return GGEditableListItem(id: "\(index)", title: word)
        }
        return GGEditableListContent(title: GGStrings.Chats.Keywords.title, addTitle: GGStrings.Chats.Keywords.add, emptyText: GGStrings.Chats.Keywords.empty, footer: GGStrings.Chats.Keywords.footer, items: items)
    }, add: {
        menuContext.present(promptController(context: context, text: GGStrings.Chats.Keywords.prompt, value: nil, characterLimit: 128, apply: { value in
            guard let word = value?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else {
                return
            }
            var words = GGMessagesSettings.keywords.value
            if !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                words.append(word)
                GGMessagesSettings.keywords.set(words)
            }
        }))
    }, select: { id in
        guard let index = Int(id) else {
            return
        }
        ggPresentActionSheet(context: context, title: nil, actions: [
            (GGStrings.Chats.Keywords.delete, true, {
                var words = GGMessagesSettings.keywords.value
                if index < words.count {
                    words.remove(at: index)
                    GGMessagesSettings.keywords.set(words)
                }
            })
        ], present: { menuContext.present($0) })
    })
}

// MARK: - Peers of the account (local creator mode, notification exceptions)

/// Peers for a list screen: loaded once per set of keys, the list rebuilds when they arrive.
private final class GGPeerTitles {
    private(set) var peers: [GGPeerKey: EnginePeer] = [:]
    private let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    private var counter = 0
    private var requested = Set<GGPeerKey>()

    var signal: Signal<Void, NoError> {
        return self.updated.get() |> map { _ in Void() }
    }

    func load(_ keys: [GGPeerKey], context: AccountContext) {
        let missing = keys.filter { !self.requested.contains($0) }
        if missing.isEmpty {
            return
        }
        for key in missing {
            self.requested.insert(key)
        }
        let _ = (context.engine.data.get(EngineDataMap(missing.map { TelegramEngine.EngineData.Item.Peer.Peer(id: PeerId(ggKey: $0)) }))
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else {
                return
            }
            for (peerId, peer) in result {
                if let peer {
                    self.peers[peerId.ggKey] = peer
                }
            }
            self.counter += 1
            self.updated.set(self.counter)
        })
    }
}

func ggMakeLocalCreatorScreen(menuContext: GGMenuContext) -> ViewController {
    let context = menuContext.context
    let accountId = menuContext.accountID
    let titles = GGPeerTitles()
    return ggMakeEditableListScreen(context: context, extra: titles.signal, content: {
        let keys = GGMessagesSettings.localCreatorChannels.value(for: accountId).sorted()
        titles.load(keys, context: context)
        let items = keys.map { key -> GGEditableListItem in
            let peer = titles.peers[key]
            return GGEditableListItem(id: key.stringValue, title: peer?.debugDisplayTitle ?? key.stringValue, peer: peer)
        }
        return GGEditableListContent(title: GGStrings.Chats.LocalCreator.title, addTitle: nil, emptyText: GGStrings.Chats.LocalCreator.empty, footer: GGStrings.Chats.LocalCreator.footer, items: items)
    }, add: nil, select: { id in
        guard let key = GGPeerKey(string: id) else {
            return
        }
        ggPresentActionSheet(context: context, title: nil, actions: [
            (GGStrings.Chats.LocalCreator.disable, true, {
                GGLocalCreatorMode.setLocalMode(false, peerId: PeerId(ggKey: key), accountId: accountId)
            })
        ], present: { menuContext.present($0) })
    })
}

/// Per-chat exceptions of SG-H1 (the old client read them in the extension, nothing wrote them).
enum GGNotificationExceptions {
    static func peerKeys(accountId: GGAccountID) -> [GGPeerKey] {
        let pinned = GGMessagesSettings.pinnedNotificationExceptions.value(for: accountId)
        let mentions = GGMessagesSettings.mentionNotificationExceptions.value(for: accountId)
        var keys = Set<GGPeerKey>()
        for key in pinned.keys {
            if let value = GGPeerKey(string: key) {
                keys.insert(value)
            }
        }
        for key in mentions.keys {
            if let value = GGPeerKey(string: key) {
                keys.insert(value)
            }
        }
        return keys.sorted()
    }

    static func modeTitle(_ value: String?) -> String {
        guard let value, let mode = GGNotificationDeliveryMode(rawValue: value) else {
            return GGStrings.Notifications.Exceptions.general
        }
        switch mode {
        case .standard:
            return GGStrings.Notifications.Menu.modeStandard
        case .silent:
            return GGStrings.Notifications.Menu.modeSilent
        case .disabled:
            return GGStrings.Notifications.Menu.modeDisabled
        }
    }

    static func set(_ mode: GGNotificationDeliveryMode?, kind: GGNotificationFilter.Kind, peer: GGPeerKey, accountId: GGAccountID) {
        let setting: GGAccountSetting<[String: String]>
        switch kind {
        case .pinnedMessage:
            setting = GGMessagesSettings.pinnedNotificationExceptions
        case .mentionOrReply:
            setting = GGMessagesSettings.mentionNotificationExceptions
        }
        var values = setting.value(for: accountId)
        values[peer.stringValue] = mode?.rawValue
        setting.set(values, for: accountId)
    }

    static func chooseMode(kind: GGNotificationFilter.Kind, peer: GGPeerKey, accountId: GGAccountID, menuContext: GGMenuContext) {
        let title = kind == .pinnedMessage ? GGStrings.Notifications.Menu.pinned : GGStrings.Notifications.Menu.mentions
        ggPresentActionSheet(context: menuContext.context, title: title, actions: [
            (GGStrings.Notifications.Exceptions.general, false, {
                GGNotificationExceptions.set(nil, kind: kind, peer: peer, accountId: accountId)
            }),
            (GGStrings.Notifications.Menu.modeStandard, false, {
                GGNotificationExceptions.set(.standard, kind: kind, peer: peer, accountId: accountId)
            }),
            (GGStrings.Notifications.Menu.modeSilent, false, {
                GGNotificationExceptions.set(.silent, kind: kind, peer: peer, accountId: accountId)
            }),
            (GGStrings.Notifications.Menu.modeDisabled, false, {
                GGNotificationExceptions.set(.disabled, kind: kind, peer: peer, accountId: accountId)
            })
        ], present: { menuContext.present($0) })
    }
}

func ggMakeNotificationExceptionsScreen(menuContext: GGMenuContext) -> ViewController {
    let context = menuContext.context
    let accountId = menuContext.accountID
    let titles = GGPeerTitles()
    let edit: (GGPeerKey) -> Void = { key in
        ggPresentActionSheet(context: context, title: nil, actions: [
            (GGStrings.Notifications.Menu.pinned, false, {
                GGNotificationExceptions.chooseMode(kind: .pinnedMessage, peer: key, accountId: accountId, menuContext: menuContext)
            }),
            (GGStrings.Notifications.Menu.mentions, false, {
                GGNotificationExceptions.chooseMode(kind: .mentionOrReply, peer: key, accountId: accountId, menuContext: menuContext)
            }),
            (GGStrings.Notifications.Exceptions.remove, true, {
                GGNotificationExceptions.set(nil, kind: .pinnedMessage, peer: key, accountId: accountId)
                GGNotificationExceptions.set(nil, kind: .mentionOrReply, peer: key, accountId: accountId)
            })
        ], present: { menuContext.present($0) })
    }
    return ggMakeEditableListScreen(context: context, extra: titles.signal, content: {
        let keys = GGNotificationExceptions.peerKeys(accountId: accountId)
        titles.load(keys, context: context)
        let pinned = GGMessagesSettings.pinnedNotificationExceptions.value(for: accountId)
        let mentions = GGMessagesSettings.mentionNotificationExceptions.value(for: accountId)
        let items = keys.map { key -> GGEditableListItem in
            let peer = titles.peers[key]
            let label = GGStrings.Notifications.Exceptions.pinnedValue(mode: GGNotificationExceptions.modeTitle(pinned[key.stringValue])) + " · " + GGStrings.Notifications.Exceptions.mentionsValue(mode: GGNotificationExceptions.modeTitle(mentions[key.stringValue]))
            return GGEditableListItem(id: key.stringValue, title: peer?.debugDisplayTitle ?? key.stringValue, label: label, peer: peer)
        }
        return GGEditableListContent(title: GGStrings.Notifications.Exceptions.title, addTitle: GGStrings.Notifications.Exceptions.add, emptyText: GGStrings.Notifications.Exceptions.empty, footer: GGStrings.Notifications.Menu.footer, items: items)
    }, add: {
        guard let navigationController = menuContext.navigationController else {
            return
        }
        let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeSecretChats, .doNotSearchMessages], hasFilters: true, hasContactSelector: false))
        controller.peerSelected = { [weak controller] peer, _ in
            controller?.dismiss()
            edit(peer.id.ggKey)
        }
        navigationController.pushViewController(controller)
    }, select: { id in
        if let key = GGPeerKey(string: id) {
            edit(key)
        }
    })
}
