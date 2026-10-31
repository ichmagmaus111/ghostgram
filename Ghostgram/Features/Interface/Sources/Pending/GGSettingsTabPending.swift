import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AvatarNode
import GGCore
import GGHooks

// Uses `GGSettingsTabDynamicRow`, `GGSettingsTabHooks.dynamicRows`, `.itemOrder`, `.invalidate()`
// (GGHooks/UI/Settings).

/// Shortcuts in Telegram's Settings tab (chats, mini apps, sites) and the order of its rows.
/// The tab is rebuilt from cached values only: peers, avatars and favicons arrive through one
/// subscription per account and call `invalidate()` when something visible changed.
enum GGSettingsTabPending {
    private static var peerCaches: [GGAccountID: [EnginePeer.Id: EnginePeer]] = [:]
    private static var iconCache: [String: UIImage] = [:]
    private static var iconDisposables: [String: Disposable] = [:]
    private static var peerDisposables: [GGAccountID: Disposable] = [:]
    private static var listDisposables: [GGAccountID: Disposable] = [:]
    /// The avatar shape the cached peer icons were drawn with; a change drops them.
    private static var iconShape: GGAvatarShape?

    static func register() {
        GGSettingsTabHooks.dynamicRows.register({ context, presentationData in
            return GGSettingsTabPending.rows(context: context, presentationData: presentationData)
        })

        // A logged-out account's subscriptions, peers and icons go with it: nothing here may keep its
        // `Account` (Postbox, network) alive until the process ends.
        GGAccountHooks.accountWillBeRemoved.register({ id in
            let accountID = id.gg
            Queue.mainQueue().async {
                GGSettingsTabPending.dropAccount(accountID)
            }
        })

        GGSettingsTabHooks.itemOrder.register({ section, ids, _ in
            let order = InterfaceSnapshots.shared.current.settingsItemsOrder
            if order.isEmpty {
                return ids
            }
            let ordered = GGSettingsTabLayout.orderedItems(section: section, order: order)
            if ordered.isEmpty {
                return ids
            }
            var result: [AnyHashable] = []
            for item in ordered {
                if let itemId = item.itemId, ids.contains(AnyHashable(itemId)) {
                    result.append(AnyHashable(itemId))
                }
            }
            for id in ids where !result.contains(id) {
                result.append(id)
            }
            return result
        })

        InterfaceSnapshots.shared.settingsTabChanged = {
            GGSettingsTabHooks.invalidate()
        }
    }

    private static func rows(context: AccountContext, presentationData: PresentationData) -> [GGSettingsTabDynamicRow] {
        assert(Thread.isMainThread)
        let accountID = context.account.id.gg
        GGSettingsTabPending.ensureSubscriptions(context: context)
        let shortcuts = InterfaceSettings.settingsShortcuts.value(for: accountID)
        if shortcuts.isEmpty {
            return []
        }
        let peers = GGSettingsTabPending.peerCaches[accountID] ?? [:]
        // «Скругление углов» changes how the icons are drawn: drop the ones drawn with another shape.
        let shape = GGAvatarHooks.currentShape()
        if GGSettingsTabPending.iconShape != shape {
            if GGSettingsTabPending.iconShape != nil {
                GGSettingsTabPending.dropIcons(prefix: "peer:")
            }
            GGSettingsTabPending.iconShape = shape
        }
        var result: [GGSettingsTabDynamicRow] = []
        for shortcut in shortcuts {
            let action: (AccountContext, NavigationController?) -> Void = { context, navigationController in
                GGShortcutActions.open(shortcut, context: context, navigationController: navigationController)
            }
            switch shortcut.kind {
            case .chat, .miniApp:
                guard let peerKey = shortcut.peer, let peer = peers[EnginePeer.Id(ggKey: peerKey)] else {
                    continue
                }
                let iconKey = "peer:\(accountID)|\(peer.id.toInt64())|\(peer.smallProfileImage?.resource.id.stringRepresentation ?? "")|\(shape.squareAvatars)-\(shape.cornerFraction)-\(shape.roundForums)"
                GGSettingsTabPending.loadIcon(key: iconKey, signal: peerAvatarCompleteImage(account: context.account, peer: peer, size: CGSize(width: 30.0, height: 30.0)))
                result.append(GGSettingsTabDynamicRow(
                    id: shortcut.id,
                    title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder),
                    label: shortcut.kind == .miniApp ? GGStrings.Interface.SettingsTab.miniAppBadge : nil,
                    icon: GGSettingsTabPending.iconCache[iconKey],
                    action: action
                ))
            case .site:
                guard let url = shortcut.url else {
                    continue
                }
                let host = GGSiteShortcut.displayHost(of: url)
                let iconKey = "site:" + url
                GGSettingsTabPending.loadIcon(key: iconKey, signal: GGFaviconStore.shared.icon(url: url, size: 30.0))
                result.append(GGSettingsTabDynamicRow(
                    id: shortcut.id,
                    title: shortcut.title.flatMap { $0.isEmpty ? nil : $0 } ?? host,
                    label: GGStrings.Interface.SettingsTab.siteBadge,
                    icon: GGSettingsTabPending.iconCache[iconKey] ?? GGFaviconStore.monogram(for: host, size: 30.0),
                    action: action
                ))
            }
        }
        return result
    }

    /// Starts loading an icon once per key; its arrival rebuilds the tab.
    private static func loadIcon(key: String, signal: Signal<UIImage?, NoError>) {
        if GGSettingsTabPending.iconCache[key] != nil || GGSettingsTabPending.iconDisposables[key] != nil {
            return
        }
        GGSettingsTabPending.iconDisposables[key] = (signal
        |> deliverOnMainQueue).start(next: { image in
            guard let image else {
                return
            }
            GGSettingsTabPending.iconCache[key] = image
            GGSettingsTabHooks.invalidate()
        })
    }

    private static func dropIcons(prefix: String) {
        for key in Array(GGSettingsTabPending.iconDisposables.keys) where key.hasPrefix(prefix) {
            GGSettingsTabPending.iconDisposables.removeValue(forKey: key)?.dispose()
        }
        for key in Array(GGSettingsTabPending.iconCache.keys) where key.hasPrefix(prefix) {
            GGSettingsTabPending.iconCache.removeValue(forKey: key)
        }
    }

    private static func dropAccount(_ accountID: GGAccountID) {
        GGSettingsTabPending.peerDisposables.removeValue(forKey: accountID)?.dispose()
        GGSettingsTabPending.listDisposables.removeValue(forKey: accountID)?.dispose()
        GGSettingsTabPending.peerCaches.removeValue(forKey: accountID)
        GGSettingsTabPending.dropIcons(prefix: "peer:\(accountID)|")
    }

    /// One subscription per account: shortcuts → their peers; the list itself rebuilds the tab.
    /// The engine is held weakly: an account without shortcuts is not kept by the subscription at all,
    /// and the peer subscription of one with shortcuts ends at its logout (`dropAccount`).
    private static func ensureSubscriptions(context: AccountContext) {
        let accountID = context.account.id.gg
        if GGSettingsTabPending.peerDisposables[accountID] != nil {
            return
        }
        let engine = context.engine
        let signal = InterfaceSettings.settingsShortcuts.signal(for: accountID)
        |> map { shortcuts -> [EnginePeer.Id] in
            return shortcuts.compactMap { shortcut -> EnginePeer.Id? in
                guard shortcut.kind != .site, let peerKey = shortcut.peer else {
                    return nil
                }
                return EnginePeer.Id(ggKey: peerKey)
            }
        }
        |> distinctUntilChanged
        |> mapToSignal { [weak engine] peerIds -> Signal<[EnginePeer.Id: EnginePeer], NoError> in
            guard let engine, !peerIds.isEmpty else {
                return .single([:])
            }
            return engine.data.subscribe(EngineDataMap(peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
            |> map { peers -> [EnginePeer.Id: EnginePeer] in
                var result: [EnginePeer.Id: EnginePeer] = [:]
                for (id, maybePeer) in peers {
                    if let peer = maybePeer {
                        result[id] = peer
                    }
                }
                return result
            }
        }
        |> deliverOnMainQueue
        GGSettingsTabPending.peerDisposables[accountID] = signal.start(next: { peers in
            let previous = GGSettingsTabPending.peerCaches[accountID]
            GGSettingsTabPending.peerCaches[accountID] = peers
            if let previous, Set(previous.keys) == Set(peers.keys), GGSettingsTabPending.sameTitles(previous, peers) {
                return
            }
            GGSettingsTabHooks.invalidate()
        })
        // Shortcut list changes (add, remove, rename a site) rebuild the tab too.
        GGSettingsTabPending.listDisposables[accountID] = (InterfaceSettings.settingsShortcuts.signal(for: accountID)
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { _ in
            GGSettingsTabHooks.invalidate()
        })
    }

    private static func sameTitles(_ lhs: [EnginePeer.Id: EnginePeer], _ rhs: [EnginePeer.Id: EnginePeer]) -> Bool {
        for (id, peer) in lhs {
            guard let other = rhs[id] else {
                return false
            }
            if peer.compactDisplayTitle != other.compactDisplayTitle || peer.smallProfileImage?.resource.id != other.smallProfileImage?.resource.id {
                return false
            }
        }
        return true
    }
}
