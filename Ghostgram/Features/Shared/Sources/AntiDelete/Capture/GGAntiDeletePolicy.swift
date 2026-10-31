import Foundation
import Postbox
import TelegramCore
import GGCore

/// What kind of chat a message is in, for the exclusions and the secret-chat switch.
enum GGAntiDeleteChatKind {
    case privateChat
    case bot
    case group
    case channel
    case secretChat
    case other
}

func ggAntiDeleteChatKind(_ peer: Peer?) -> GGAntiDeleteChatKind {
    guard let peer else {
        return .other
    }
    if let user = peer as? TelegramUser {
        return user.botInfo != nil ? .bot : .privateChat
    }
    if peer is TelegramGroup || peer is TelegramCommunity {
        return .group
    }
    if let channel = peer as? TelegramChannel {
        if case .broadcast = channel.info {
            return .channel
        }
        return .group
    }
    if peer is TelegramSecretChat {
        return .secretChat
    }
    return .other
}

/// The settings that decide capture, read ONCE per batch (one transaction handler call): the
/// registry snapshot is cheap, but the account sets are copied, so not per message.
struct GGAntiDeletePolicy {
    let enabled: Bool
    let keepOwn: Bool
    let keepSelfDestructing: Bool
    let secretChats: Bool
    let editHistory: Bool
    let excludeGroups: Bool
    let excludeBots: Bool
    let excludeChannels: Bool
    let editsInExclusions: Bool
    let excludedPeers: Set<GGPeerKey>
    let excludedFolderPeers: Set<GGPeerKey>

    /// Only the global switches: enough to decide «nothing to do» without touching the account.
    static var capturesDeletions: Bool {
        return GGAntiDeleteSettings.enabled.value || GGAntiDeleteSettings.keepOwn.value || GGAntiDeleteSettings.keepSelfDestructing.value
    }

    static func current(account: AccountRecordId?) -> GGAntiDeletePolicy {
        var excludedPeers = Set<GGPeerKey>()
        var excludedFolderPeers = Set<GGPeerKey>()
        if let account {
            excludedPeers = GGAntiDeleteSettings.excludedPeers.value(for: account.gg)
            excludedFolderPeers = GGAntiDeleteSettings.excludedFolderPeers.value(for: account.gg)
        }
        return GGAntiDeletePolicy(
            enabled: GGAntiDeleteSettings.enabled.value,
            keepOwn: GGAntiDeleteSettings.keepOwn.value,
            keepSelfDestructing: GGAntiDeleteSettings.keepSelfDestructing.value,
            secretChats: GGAntiDeleteSettings.secretChats.value,
            editHistory: GGAntiDeleteSettings.editHistory.value,
            excludeGroups: GGAntiDeleteSettings.excludeGroups.value,
            excludeBots: GGAntiDeleteSettings.excludeBots.value,
            excludeChannels: GGAntiDeleteSettings.excludeChannels.value,
            editsInExclusions: GGAntiDeleteSettings.editsInExclusions.value,
            excludedPeers: excludedPeers,
            excludedFolderPeers: excludedFolderPeers
        )
    }

    /// The chat is excluded from capture: by hand (a secret chat follows its user), by folder or
    /// by its kind.
    func isExcluded(chatPeerId: PeerId, chatPeer: Peer?, kind: GGAntiDeleteChatKind) -> Bool {
        let key = chatPeerId.ggKey
        if self.excludedPeers.contains(key) || self.excludedFolderPeers.contains(key) {
            return true
        }
        if let secretChat = chatPeer as? TelegramSecretChat {
            let userKey = secretChat.regularPeerId.ggKey
            if self.excludedPeers.contains(userKey) || self.excludedFolderPeers.contains(userKey) {
                return true
            }
        }
        switch kind {
        case .group:
            return self.excludeGroups
        case .bot:
            return self.excludeBots
        case .channel:
            return self.excludeChannels
        case .privateChat, .secretChat, .other:
            return false
        }
    }

    /// Whether a deletion of `message` from `source` keeps it.
    func keepsDeleted(_ message: Message, source: GGDeletionSource, chatPeer: Peer?) -> Bool {
        // A message the server has not got (still sending, failed) is cancelled, not deleted: kept,
        // it would stay in the send queue and go out after all («Отменить отправку», the cross on an
        // upload). Scheduled and quick-reply messages were never delivered either.
        if message.flags.contains(.Unsent) || message.flags.contains(.Failed) {
            return false
        }
        if Namespaces.Message.allNonRegular.contains(message.id.namespace) {
            return false
        }
        let kind = ggAntiDeleteChatKind(chatPeer)
        // A secret chat's timer is the self-destructing message itself: «Сохранять исчезающие» keeps it
        // without «Секретные чаты», as the old client did (report on build 196: the timers of secret
        // chats were not kept, and the migration never sets the switch). The switch is about what the
        // other side deletes, clears or edits there.
        if kind == .secretChat && !self.secretChats && source != .autoremoveTimer {
            return false
        }
        if self.isExcluded(chatPeerId: message.id.peerId, chatPeer: chatPeer, kind: kind) {
            return false
        }
        let isIncoming = message.flags.contains(.Incoming)
        switch source {
        case .remoteUpdate, .historyValidation, .secretChat:
            // Somebody else deleted it; one's own messages deleted from another device count as own.
            return isIncoming ? self.enabled : self.keepOwn
        case .autoremoveTimer:
            // Only what others sent: one's own self-destructing messages disappear as usual.
            return isIncoming && self.keepSelfDestructing
        case .localForEveryone:
            // «Delete for everyone» here: only one's own messages stay.
            return !isIncoming && self.keepOwn
        }
    }

    /// Whether a cleared history (server «clear up to», a secret chat cleared by the other side)
    /// keeps its messages in this chat.
    func keepsClearedHistory(chatPeerId: PeerId, chatPeer: Peer?) -> Bool {
        let kind = ggAntiDeleteChatKind(chatPeer)
        if kind == .secretChat && !self.secretChats {
            return false
        }
        if self.isExcluded(chatPeerId: chatPeerId, chatPeer: chatPeer, kind: kind) {
            return false
        }
        return self.enabled
    }

    func keepsEdits(chatPeerId: PeerId, chatPeer: Peer?) -> Bool {
        if !self.editHistory {
            return false
        }
        let kind = ggAntiDeleteChatKind(chatPeer)
        if kind == .secretChat && !self.secretChats {
            return false
        }
        if self.isExcluded(chatPeerId: chatPeerId, chatPeer: chatPeer, kind: kind) {
            return self.editsInExclusions
        }
        return true
    }
}
