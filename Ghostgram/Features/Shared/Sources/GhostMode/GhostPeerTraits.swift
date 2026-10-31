import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import GGCore

/// What kind of chat a peer is, as far as ghost-mode exceptions care.
public enum GGGhostPeerKind: Equatable {
    case user
    case bot
    case basicGroup
    case supergroup
    case channel
    /// A secret chat with this user.
    case secretChat(user: PeerId)

    public init?(peer: Peer) {
        if let user = peer as? TelegramUser {
            self = user.botInfo != nil ? .bot : .user
        } else if peer is TelegramGroup {
            self = .basicGroup
        } else if let channel = peer as? TelegramChannel {
            switch channel.info {
            case .broadcast:
                self = .channel
            case .group:
                self = .supergroup
            }
        } else if let secretChat = peer as? TelegramSecretChat {
            self = .secretChat(user: secretChat.regularPeerId)
        } else {
            return nil
        }
    }
}

/// Per-account knowledge the exception checks need synchronously (they run on network and Postbox
/// queues, with only a peer id at hand): peer kinds, the folders chosen as exceptions, contacts.
///
/// Kinds are learned from every place that has a `Peer` (typing requests, consumed messages, chat
/// screens, menus) and, for an unknown peer, resolved once in the background from the account's
/// Postbox. Until then the peer counts as "not an exception" — the privacy-safe answer.
public final class GGGhostPeerTraits {
    public static let shared = GGGhostPeerTraits()

    private struct AccountState {
        var kinds: [PeerId: GGGhostPeerKind] = [:]
        var resolving: Set<PeerId> = []
        /// Folder id → its definition; only folders chosen as exceptions are kept fresh by the app.
        var folders: [Int32: ChatListFilterData] = [:]
        var contacts: Set<PeerId> = []
        weak var postbox: Postbox?
    }

    private let state = Atomic<[GGAccountID: AccountState]>(value: [:])
    private let maxKindsPerAccount = 4096

    private init() {
    }

    // MARK: Accounts

    func accountDidStart(_ account: GGAccountID, postbox: Postbox) {
        let _ = self.state.modify { current in
            var current = current
            var accountState = current[account] ?? AccountState()
            accountState.postbox = postbox
            current[account] = accountState
            return current
        }
    }

    func accountWillBeRemoved(_ account: GGAccountID) {
        let _ = self.state.modify { current in
            var current = current
            current.removeValue(forKey: account)
            return current
        }
    }

    // MARK: Kinds

    public func learn(_ peer: Peer, account: GGAccountID) {
        guard let kind = GGGhostPeerKind(peer: peer) else {
            return
        }
        self.store(kind, peerId: peer.id, account: account)
    }

    public func learn(_ peer: EnginePeer, account: GGAccountID) {
        self.learn(peer._asPeer(), account: account)
    }

    private func store(_ kind: GGGhostPeerKind, peerId: PeerId, account: GGAccountID) {
        let _ = self.state.modify { current in
            var current = current
            var accountState = current[account] ?? AccountState()
            if accountState.kinds[peerId] == kind {
                return current
            }
            if accountState.kinds.count >= self.maxKindsPerAccount {
                accountState.kinds.removeAll(keepingCapacity: true)
            }
            accountState.kinds[peerId] = kind
            accountState.resolving.remove(peerId)
            current[account] = accountState
            return current
        }
    }

    /// The kind if known. Namespaces that settle it on their own answer at once; otherwise an
    /// unknown peer is looked up in the background and nil is returned this time.
    public func kind(of peerId: PeerId, account: GGAccountID) -> GGGhostPeerKind? {
        if peerId.namespace == Namespaces.Peer.CloudGroup {
            return .basicGroup
        }
        var postboxToResolve: Postbox?
        let known: GGGhostPeerKind? = self.state.modify { current in
            var current = current
            guard var accountState = current[account] else {
                return current
            }
            if accountState.kinds[peerId] == nil, !accountState.resolving.contains(peerId), let postbox = accountState.postbox {
                accountState.resolving.insert(peerId)
                postboxToResolve = postbox
                current[account] = accountState
            }
            return current
        }[account]?.kinds[peerId]
        if let known = known {
            return known
        }
        if let postbox = postboxToResolve {
            let _ = (postbox.transaction { transaction -> Peer? in
                return transaction.getPeer(peerId)
            }).start(next: { [weak self] peer in
                guard let self = self else {
                    return
                }
                if let peer = peer {
                    self.learn(peer, account: account)
                } else {
                    let _ = self.state.modify { current in
                        var current = current
                        current[account]?.resolving.remove(peerId)
                        return current
                    }
                }
            })
        }
        return nil
    }

    public func isBot(_ peerId: PeerId, account: GGAccountID) -> Bool {
        if peerId.namespace != Namespaces.Peer.CloudUser {
            return false
        }
        return self.kind(of: peerId, account: account) == .bot
    }

    // MARK: Folders and contacts (fed by the app while folder exceptions exist)

    public func updateFolders(_ folders: [Int32: ChatListFilterData], account: GGAccountID) {
        let _ = self.state.modify { current in
            var current = current
            var accountState = current[account] ?? AccountState()
            accountState.folders = folders
            current[account] = accountState
            return current
        }
    }

    public func updateContacts(_ contacts: Set<PeerId>, account: GGAccountID) {
        let _ = self.state.modify { current in
            var current = current
            var accountState = current[account] ?? AccountState()
            accountState.contacts = contacts
            current[account] = accountState
            return current
        }
    }

    /// Whether the chat belongs to one of `folderIds`: the folder's own chat list plus its categories
    /// (contacts, non-contacts, groups, channels, bots), minus its excluded chats. The "hide muted /
    /// read / archived" flags are deliberately ignored: a chat must not leave the exception because
    /// it was just read.
    public func isInFolders(_ folderIds: Set<Int32>, peerId: PeerId, kind: GGGhostPeerKind?, account: GGAccountID) -> Bool {
        if folderIds.isEmpty {
            return false
        }
        guard let accountState = self.state.with({ $0[account] }) else {
            return false
        }
        var categoryPeerId = peerId
        var categoryKind = kind
        if case let .secretChat(user)? = kind {
            categoryPeerId = user
            categoryKind = .user
        }
        for folderId in folderIds {
            guard let data = accountState.folders[folderId] else {
                continue
            }
            if data.excludePeers.contains(peerId) {
                continue
            }
            if data.includePeers.peers.contains(peerId) || data.includePeers.peers.contains(categoryPeerId) {
                return true
            }
            guard let resolvedKind = categoryKind else {
                continue
            }
            switch resolvedKind {
            case .user, .secretChat:
                if accountState.contacts.contains(categoryPeerId) {
                    if data.categories.contains(.contacts) {
                        return true
                    }
                } else if data.categories.contains(.nonContacts) {
                    return true
                }
            case .bot:
                if data.categories.contains(.bots) {
                    return true
                }
            case .basicGroup, .supergroup:
                if data.categories.contains(.groups) {
                    return true
                }
            case .channel:
                if data.categories.contains(.channels) {
                    return true
                }
            }
        }
        return false
    }
}
