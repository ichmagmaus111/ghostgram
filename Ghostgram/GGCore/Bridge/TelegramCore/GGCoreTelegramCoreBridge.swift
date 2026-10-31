// Compiled into TelegramCore (filegroup //Ghostgram/GGCore:TelegramCoreBridgeSources): the parts of
// GGCore that need TelegramCore / Postbox types. GGCore itself can not see them, since
// TelegramCore depends on GGCore.

import Foundation
import Postbox
import SwiftSignalKit
import GGCore

// MARK: - Canonical keys

public extension AccountRecordId {
    /// The account's Ghostgram key (same raw value).
    var gg: GGAccountID {
        return GGAccountID(rawValue: self.int64)
    }

    init(gg: GGAccountID) {
        self.init(rawValue: gg.rawValue)
    }
}

public extension PeerId {
    /// The whole PeerId, namespace included. Use this, never `toInt64()`, as a stored key.
    var ggKey: GGPeerKey {
        guard let key = GGPeerKey(namespace: self.namespace._internalGetInt32Value(), id: self.id._internalGetInt64Value()) else {
            preconditionFailure("PeerId namespace out of range")
        }
        return key
    }

    init(ggKey: GGPeerKey) {
        self.init(namespace: PeerId.Namespace._internalFromInt32Value(ggKey.namespace), id: PeerId.Id._internalFromInt64Value(ggKey.id))
    }
}

public extension MessageId {
    /// Peer, message namespace and id.
    var ggKey: GGMessageKey {
        return GGMessageKey(peer: self.peerId.ggKey, namespace: self.namespace, id: self.id)
    }

    init(ggKey: GGMessageKey) {
        self.init(peerId: PeerId(ggKey: ggKey.peer), namespace: ggKey.namespace, id: ggKey.id)
    }
}

// MARK: - Account lifecycle

/// GHOST hook target: call from `Account.init`, before the account's network starts. Loads the
/// account's Ghostgram settings (`<basePath>/ghostgram/settings.json`) and runs its migrations.
public func ggCoreAccountDidLoad(id: AccountRecordId, basePath: String) {
    #if DEBUG
    ggCoreBridgeSelfCheckOnce()
    #endif
    GGSettingsStore.shared.registerAccount(id.gg, basePath: basePath)
}

/// GHOST hook target: call right after `ggCoreAccountDidLoad`, once the account's own peer is known
/// (`Account.init`, the notification service's standalone state manager). Runs the account's
/// migrations of old data keyed by that peer (`GGMigrations.registerAccountPeer`, app only).
public func ggCoreAccountPeerDidLoad(id: AccountRecordId, peerId: PeerId) {
    GGMigrations.accountPeerDidLoad(id.gg, peer: peerId.ggKey)
}

/// GHOST hook target: call when the account is logged out / removed.
public func ggCoreAccountWillBeRemoved(id: AccountRecordId) {
    GGSettingsStore.shared.unregisterAccount(id.gg)
}

// MARK: - Proxy for GGNetwork

/// The SOCKS5 proxy for Ghostgram's own requests, or nil (MTProxy and WEB proxies can not carry
/// a `URLSession` request).
public func ggProxy(from server: ProxyServerSettings?) -> GGProxy? {
    guard let server = server else {
        return nil
    }
    switch server.connection {
    case let .socks5(username, password):
        return .socks5(host: server.host, port: Int(server.port), username: username, password: password)
    case .mtp, .web:
        return nil
    }
}

private struct GGProxyBridgeState {
    let proxy: GGProxy?
    let isDirectConnectionAllowed: Bool
}

private let ggProxyBridgeState = Atomic<GGProxyBridgeState>(value: GGProxyBridgeState(proxy: nil, isDirectConnectionAllowed: true))
private let ggProxyBridgeAttached = Atomic<Bool>(value: false)
private let ggProxyBridgeDisposable = MetaDisposable()

/// GHOST hook target: call once after the `AccountManager` is created (app and extensions).
/// Keeps `GGNetwork.shared` on the user's active proxy: SOCKS5 is used, any other active proxy
/// blocks direct requests. Later calls do nothing.
public func ggCoreAttachProxySettings(accountManager: AccountManager<TelegramAccountManagerTypes>) {
    if ggProxyBridgeAttached.swap(true) {
        return
    }
    GGNetwork.shared.proxyProvider = {
        return ggProxyBridgeState.with { state in
            return state.proxy
        }
    }
    GGNetwork.shared.isDirectConnectionAllowedProvider = {
        return ggProxyBridgeState.with { state in
            return state.isDirectConnectionAllowed
        }
    }
    ggProxyBridgeDisposable.set((accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
    |> map { sharedData -> ProxyServerSettings? in
        return sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self)?.effectiveActiveServer
    }
    |> distinctUntilChanged).start(next: { server in
        let state = GGProxyBridgeState(proxy: ggProxy(from: server), isDirectConnectionAllowed: server == nil)
        let _ = ggProxyBridgeState.swap(state)
    }))
}

// MARK: - Debug self-check

#if DEBUG
private let ggCoreBridgeSelfChecked = Atomic<Bool>(value: false)

/// GGLegacyKeys mirrors the bit layout of `PeerId(Int64)`; make sure it still does.
private func ggCoreBridgeSelfCheckOnce() {
    if ggCoreBridgeSelfChecked.swap(true) {
        return
    }
    let samples: [PeerId] = [
        PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(777000)),
        PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(123456789)),
        PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1234567890123)),
        PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt64Value(-5)),
        PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(5000000000))
    ]
    for peerId in samples {
        assert(GGLegacyKeys.peerKey(fromLegacyInt64: peerId.toInt64()) == peerId.ggKey, "GGLegacyKeys diverged from PeerId(Int64)")
        assert(GGLegacyKeys.legacyInt64(of: peerId.ggKey) == peerId.toInt64(), "GGLegacyKeys diverged from PeerId.toInt64()")
        assert(PeerId(ggKey: peerId.ggKey) == peerId, "PeerId(ggKey:) does not round-trip")
    }
}
#endif
