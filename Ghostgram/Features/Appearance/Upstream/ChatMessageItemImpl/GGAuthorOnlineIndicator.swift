// Compiled into ChatMessageItemImpl (filegroup //Ghostgram/Features/Appearance:ChatMessageItemImplSources,
// owner W2-4). «Сеть человека в чате» (appearance.messages.authorOnline): an online dot on the avatar
// next to a group member's messages.
//
// The old feature opened a Postbox peerView per author and re-created it on every settings
// notification. Here every author has ONE lightweight presence view (`.peerPresences`, not a peer
// view) per account, shared by all avatar headers showing that author and kept only while one is on
// screen. Nothing is created while the setting is off.

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PeerOnlineMarkerNode
import GGAppearanceSettings

final class GGAuthorOnlineIndicator {
    let peerId: EnginePeer.Id
    private let markerNode: PeerOnlineMarkerNode
    private var disposable: Disposable?
    private var isOnline = false
    private var avatarSize: CGFloat = 0.0

    fileprivate init(context: AccountContext, peerId: EnginePeer.Id, host: ASDisplayNode, theme: PresentationTheme) {
        self.peerId = peerId
        self.markerNode = PeerOnlineMarkerNode()
        self.markerNode.setImage(PresentationResourcesChatList.recentStatusOnlineIcon(theme, state: .regular), color: nil, transition: .immediate)
        host.addSubnode(self.markerNode)

        self.disposable = (GGAuthorPresenceCache.shared.online(context: context, peerId: peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] isOnline in
            guard let self else {
                return
            }
            self.isOnline = isOnline
            self.apply(animated: true)
        })
    }

    deinit {
        self.disposable?.dispose()
        self.markerNode.removeFromSupernode()
    }

    func update(theme: PresentationTheme) {
        self.markerNode.setImage(PresentationResourcesChatList.recentStatusOnlineIcon(theme, state: .regular), color: nil, transition: .immediate)
    }

    func layout(avatarSize: CGFloat) {
        self.avatarSize = avatarSize
        self.apply(animated: false)
    }

    private func apply(animated: Bool) {
        let (size, apply) = self.markerNode.asyncLayout()(self.isOnline, false)
        self.markerNode.frame = CGRect(origin: CGPoint(x: self.avatarSize - size.width + 1.0, y: self.avatarSize - size.height + 1.0), size: size)
        apply(animated)
    }
}

/// Creates, keeps or drops the indicator of an avatar header. Main thread.
func ggUpdateAuthorOnlineIndicator(_ current: GGAuthorOnlineIndicator?, host: ASDisplayNode, context: AccountContext, peer: EnginePeer?, theme: PresentationTheme) -> GGAuthorOnlineIndicator? {
    guard GGAppearanceSnapshot.current.authorOnlineIndicator, let peer, peer.id.namespace == Namespaces.Peer.CloudUser, peer.id != context.account.peerId else {
        return nil
    }
    if case let .user(user) = peer, user.botInfo != nil {
        return nil
    }
    if let current, current.peerId == peer.id {
        current.update(theme: theme)
        return current
    }
    return GGAuthorOnlineIndicator(context: context, peerId: peer.id, host: host, theme: theme)
}

/// One presence view per (account, author), shared while somebody listens.
private final class GGAuthorPresenceCache {
    static let shared = GGAuthorPresenceCache()

    private struct Key: Hashable {
        let accountPeerId: EnginePeer.Id
        let peerId: EnginePeer.Id
    }

    private final class Entry {
        var disposable: Disposable?
        var isOnline = false
        let listeners = Bag<(Bool) -> Void>()
    }

    private var entries: [Key: Entry] = [:]

    func online(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Bool, NoError> {
        let key = Key(accountPeerId: context.account.peerId, peerId: peerId)
        return Signal { [weak self] subscriber in
            assert(Thread.isMainThread)
            guard let self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let entry: Entry
            var startsView = false
            if let current = self.entries[key] {
                entry = current
                subscriber.putNext(current.isOnline)
            } else {
                entry = Entry()
                self.entries[key] = entry
                startsView = true
            }
            let index = entry.listeners.add({ isOnline in
                subscriber.putNext(isOnline)
            })
            if startsView {
                entry.disposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Presence(id: peerId))
                |> map { presence -> Int32? in
                    if let presence, case let .present(until) = presence.status {
                        return until
                    }
                    return nil
                }
                |> distinctUntilChanged
                // «Online until» runs out without any update: for members outside the contacts the
                // server sends no «went offline». One timer per author on screen, until that moment
                // (as upstream's PeerPresenceStatusManager does), so the dot goes out by itself.
                |> mapToSignal { until -> Signal<Bool, NoError> in
                    guard let until else {
                        return .single(false)
                    }
                    let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                    if until < now {
                        return .single(false)
                    }
                    return .single(true)
                    |> then(.single(false) |> delay(Double(until - now) + 1.0, queue: Queue.mainQueue()))
                }
                |> distinctUntilChanged
                |> deliverOnMainQueue).startStrict(next: { [weak entry] isOnline in
                    guard let entry else {
                        return
                    }
                    entry.isOnline = isOnline
                    for listener in entry.listeners.copyItems() {
                        listener(isOnline)
                    }
                })
            }
            return ActionDisposable { [weak self, weak entry] in
                Queue.mainQueue().async {
                    guard let self, let entry, let current = self.entries[key], current === entry else {
                        return
                    }
                    entry.listeners.remove(index)
                    if entry.listeners.isEmpty {
                        entry.disposable?.dispose()
                        self.entries.removeValue(forKey: key)
                    }
                }
            }
        }
    }
}
