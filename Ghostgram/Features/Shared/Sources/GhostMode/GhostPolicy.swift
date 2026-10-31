import Foundation
import Postbox
import TelegramCore
import GGCore

/// The parts of ghost mode that can be switched per function and per chat.
public enum GGGhostFunction {
    case readReceipts
    case storyViews
    case online
    case typing
}

/// Why a chat is (or is not) an exception.
public enum GGGhostExceptionSource: Equatable {
    case none
    /// An explicit entry in the chat list of exceptions.
    case explicit(GGGhostException)
    /// «Все каналы» / «Все группы».
    case type
    /// A folder chosen as an exception.
    case folder
    /// The chat's type or folder is an exception, but the chat was pulled back into ghost mode.
    case forced
}

/// Ghost mode resolved for one account. Every answer is computed from the settings snapshot of
/// GGCore (no disk, no UserDefaults, no JSON) plus the in-memory peer kinds, so it may be asked on
/// any queue, inside Postbox transactions included.
public enum GGGhostPolicy {
    /// The master switch.
    public static func isEnabled(_ account: GGAccountID) -> Bool {
        return GGGhostSettings.isEnabled.value(for: account)
    }

    /// Whether the function is switched on for the account, regardless of chat.
    public static func isFunctionOn(_ function: GGGhostFunction, account: GGAccountID) -> Bool {
        if !GGGhostPolicy.isEnabled(account) {
            return false
        }
        switch function {
        case .readReceipts:
            return GGGhostSettings.hideReadReceipts.value(for: account)
        case .storyViews:
            return GGGhostSettings.hideStoryViews.value(for: account)
        case .online:
            return GGGhostSettings.hideOnline.value(for: account)
        case .typing:
            return GGGhostSettings.hideTyping.value(for: account)
        }
    }

    /// Explicit entry of a chat; a secret chat falls back to its user's entry.
    public static func explicitException(for peerId: PeerId, account: GGAccountID) -> GGGhostException? {
        let exceptions = GGGhostSettings.exceptions.value(for: account)
        if exceptions.isEmpty {
            return nil
        }
        if let exception = exceptions[peerId.ggGhostKey] {
            return exception
        }
        if peerId.namespace == Namespaces.Peer.SecretChat, case let .secretChat(user)? = GGGhostPeerTraits.shared.kind(of: peerId, account: account) {
            return exceptions[user.ggGhostKey]
        }
        return nil
    }

    /// Whether the chat's type or one of its folders is an exception.
    public static func isExceptedByTypeOrFolder(_ peerId: PeerId, account: GGAccountID) -> (byType: Bool, byFolder: Bool) {
        let allChannels = GGGhostSettings.exceptAllChannels.value(for: account)
        let allGroups = GGGhostSettings.exceptAllGroups.value(for: account)
        let folders = GGGhostSettings.exceptFolders.value(for: account)
        if !allChannels && !allGroups && folders.isEmpty {
            return (false, false)
        }
        let kind = GGGhostPeerTraits.shared.kind(of: peerId, account: account)
        var byType = false
        if let kind = kind {
            switch kind {
            case .channel:
                byType = allChannels
            case .basicGroup, .supergroup:
                byType = allGroups
            default:
                break
            }
        }
        let byFolder = GGGhostPeerTraits.shared.isInFolders(folders, peerId: peerId, kind: kind, account: account)
        return (byType, byFolder)
    }

    public static func exceptionSource(for peerId: PeerId, account: GGAccountID) -> GGGhostExceptionSource {
        let explicit = GGGhostPolicy.explicitException(for: peerId, account: account)
        if let explicit = explicit, explicit.kind == .exclude {
            return .explicit(explicit)
        }
        let (byType, byFolder) = GGGhostPolicy.isExceptedByTypeOrFolder(peerId, account: account)
        if !byType && !byFolder {
            return .none
        }
        if explicit?.kind == .include {
            return .forced
        }
        return byType ? .type : .folder
    }

    /// The exception that applies to the chat, nil when ghost mode applies in full.
    public static func effectiveException(for peerId: PeerId, account: GGAccountID) -> GGGhostException? {
        switch GGGhostPolicy.exceptionSource(for: peerId, account: account) {
        case .none, .forced:
            return nil
        case let .explicit(exception):
            return exception
        case .type, .folder:
            return .fullExclusion
        }
    }

    /// Whether ghost mode keeps `function` from the chat (`peerId == nil`: "any chat", i.e. the
    /// function itself).
    public static func hides(_ function: GGGhostFunction, peerId: PeerId?, account: GGAccountID) -> Bool {
        if !GGGhostPolicy.isFunctionOn(function, account: account) {
            return false
        }
        guard let peerId = peerId else {
            return true
        }
        guard let exception = GGGhostPolicy.effectiveException(for: peerId, account: account) else {
            return true
        }
        switch function {
        case .readReceipts:
            return !exception.readMessages
        case .storyViews:
            return !exception.readStories
        case .online:
            return !exception.showOnline
        case .typing:
            return !exception.showTyping
        }
    }

    /// Statuses still sent in the chat while «печатает» is hidden there.
    public static func shownActivities(for peerId: PeerId, account: GGAccountID) -> Set<GGGhostActivityKind> {
        if let exception = GGGhostPolicy.effectiveException(for: peerId, account: account), let own = exception.ownShownActivities {
            return Set(own)
        }
        var result = Set<GGGhostActivityKind>()
        for kind in GGGhostActivityKind.allCases where GGGhostSettings.shownActivity(kind).value(for: account) {
            result.insert(kind)
        }
        return result
    }

    /// «Читать при действиях» for the chat: the exception's own value, else the global switch. Only
    /// meaningful while ghost mode keeps read receipts there.
    public static func readsOnAction(in peerId: PeerId, account: GGAccountID) -> Bool {
        if let exception = GGGhostPolicy.effectiveException(for: peerId, account: account), let value = exception.readOnAction {
            return value
        }
        return GGGhostSettings.readOnAction.value(for: account)
    }
}

/// Send delay («Отложенная отправка»): the one decision every path uses — the stored sends and the
/// standalone senders (share extension, quick forward, Siri) ask the same `GGOutgoingHooks.sendDelay`.
public enum GGSendDelayPolicy {
    /// nil = send now. One delay for text and media. `peer` is the chat as stored (asked inside the
    /// transaction); only when Postbox does not know it does the peer kind cache decide «bot».
    public static func scheduleTime(account: GGAccountID, accountPeerId: PeerId, peerId: PeerId, peer: Peer?, serverTime: Double) -> Int32? {
        if !GGGhostSettings.sendDelayEnabled.value(for: account) {
            return nil
        }
        // «Избранное» is a notebook: a scheduled message there is a reminder, not a hidden send.
        if peerId == accountPeerId {
            return nil
        }
        // Secret chats can not schedule; bots refuse scheduled messages (SCHEDULE_BOT_NOT_ALLOWED).
        if peerId.namespace == Namespaces.Peer.SecretChat {
            return nil
        }
        if let peer {
            if let user = peer as? TelegramUser, user.botInfo != nil {
                return nil
            }
        } else if GGGhostPeerTraits.shared.isBot(peerId, account: account) {
            return nil
        }
        // The server sends at once anything scheduled less than ~10 s ahead: the range keeps a margin.
        let delay = GGSendDelaySeconds.clamped(GGGhostSettings.sendDelaySeconds.value(for: account))
        return Int32(serverTime + delay)
    }

    /// Whether a batch must go out as is: already scheduled, paid, or self-destructing. `attributes`
    /// — of every message of the batch.
    public static func mustSendImmediately(_ attributes: [[MessageAttribute]]) -> Bool {
        for messageAttributes in attributes {
            for attribute in messageAttributes {
                if attribute is OutgoingScheduleInfoMessageAttribute {
                    return true
                }
                if attribute is PaidStarsMessageAttribute {
                    return true
                }
                if let attribute = attribute as? AutoremoveTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout {
                    return true
                }
                if let attribute = attribute as? AutoclearTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout {
                    return true
                }
            }
        }
        return false
    }
}
