// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// Notification service extension: features see and change the final content of every push
// (hide the text of locked chats, hide pushes of hidden accounts). Handlers are registered
// from `GG<Zone>Shared.register()` (GGFeaturesShared is what the extension links) and read
// settings with `.extensions` / scope `appGroup` or the push account's settings.
// Deletions arriving in the extension go through `GGUpdateHooks.messagesWillBeDeleted`
// (`request.isExtension == true`): hand work to the app via `GGSharedInbox`.

import Foundation
import Postbox
import GGCore

/// The visible part of a notification. Upstream builds it; features may rewrite it.
public struct GGNotificationContent: Equatable {
    public var title: String
    public var subtitle: String
    public var body: String
    public var threadIdentifier: String
    public var categoryIdentifier: String
    /// Deliver an empty notification (nothing shown): upstream's way to drop a push.
    public var isHidden: Bool
    /// Deliver it without a sound (the banner stays).
    public var isSilent: Bool
    /// Drop the attachments (media thumbnails) — set together with a hidden body (W3-4 chat lock).
    public var hidesAttachments: Bool

    public init(title: String, subtitle: String, body: String, threadIdentifier: String, categoryIdentifier: String, isHidden: Bool, isSilent: Bool = false, hidesAttachments: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.isHidden = isHidden
        self.isSilent = isSilent
        self.hidesAttachments = hidesAttachments
    }
}

public struct GGNotificationContext {
    /// The account the push was delivered to (nil when it could not be decrypted).
    public let accountId: AccountRecordId?
    public let peerId: PeerId?
    public let messageId: MessageId?
    /// The push is about a pinned message (`PINNED_*` key or a fetched «pinned» service message).
    public let isPinnedMessage: Bool
    /// The push mentions the user or replies to them (`mention` in the payload).
    public let isMentionOrReply: Bool

    public init(accountId: AccountRecordId?, peerId: PeerId?, messageId: MessageId?, isPinnedMessage: Bool, isMentionOrReply: Bool) {
        self.accountId = accountId
        self.peerId = peerId
        self.messageId = messageId
        self.isPinnedMessage = isPinnedMessage
        self.isMentionOrReply = isMentionOrReply
    }
}

public enum GGNotificationServiceHooks {
    /// Transformer of the content handed to the system, in the order of `order`.
    public static let content = GGHookPoint<(inout GGNotificationContent, GGNotificationContext) -> Void>("notificationService.content")

    /// For the extension (outside TelegramCore).
    public static func transform(_ content: GGNotificationContent, context: GGNotificationContext) -> GGNotificationContent {
        var result = content
        for handler in GGNotificationServiceHooks.content.handlers {
            handler(&result, context)
        }
        return result
    }
}

public extension GGUpdateHooks {
    /// `messagesWillBeDeleted` for call sites outside TelegramCore (the notification service).
    static func messageIdsToDelete(_ ids: [MessageId], source: GGDeletionSource, transaction: Transaction, accountPeerId: PeerId?) -> [MessageId] {
        return ggMessageIdsToDelete(ids, source: source, transaction: transaction, accountPeerId: accountPeerId)
    }
}
