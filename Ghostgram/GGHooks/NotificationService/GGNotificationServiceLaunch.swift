// Compiled into NotificationServiceExtensionLib (filegroup
// //Ghostgram/GGHooks:NotificationServiceHookSources). Launch of Ghostgram in the notification
// service extension and the content point applied to what is handed to the system.

import Foundation
import UserNotifications
import Postbox
import TelegramCore
import GGCore
import GGFeaturesShared

private var ggNotificationServiceStarted = false
private let ggNotificationServiceLock = NSLock()

/// GHOST hook target: at the start of every push, before `initializeAccountManagement()` (feature
/// attribute declarations) and before any account is opened. The first call starts Ghostgram in the
/// process; iOS keeps the process alive and reuses it for the next pushes, so every later call reads
/// the settings files again (chat protection, notification modes, «Удалённые» changed in the app).
func ggNotificationServiceDidStart(appGroupPath: String) {
    ggNotificationServiceLock.lock()
    defer {
        ggNotificationServiceLock.unlock()
    }
    if ggNotificationServiceStarted {
        GGCore.reloadSettings()
        return
    }
    ggNotificationServiceStarted = true
    GGCore.bootstrap(GGCoreEnvironment(appGroupPath: appGroupPath, process: .notificationService))
    // Handlers register on the main thread (GGHookPoint contract); the extension calls this
    // from its handler queue, before anything reads the points.
    if Thread.isMainThread {
        GGFeaturesShared.registerForExtension()
    } else {
        DispatchQueue.main.sync {
            GGFeaturesShared.registerForExtension()
        }
    }
    GGHookRegistry.freeze()
}

// Marks the extension puts into the content's userInfo while it builds it, read back (and
// removed) when the final content is handed to the system. Only set while the point has handlers.
private let ggPinnedMessageKey = "gg.pinnedMessage"
private let ggMentionOrReplyKey = "gg.mentionOrReply"

/// GHOST hook target: the payload of a message push (`mention`, `loc-key`), right after the
/// content is created.
func ggMarkNotificationContent(_ userInfo: inout [AnyHashable: Any], payload: [String: Any]) {
    if GGNotificationServiceHooks.content.isEmpty {
        return
    }
    if let mention = payload["mention"] as? String, mention == "1" {
        userInfo[ggMentionOrReplyKey] = true
    }
    if let locKey = payload["loc-key"] as? String, locKey.hasPrefix("PINNED_") {
        userInfo[ggPinnedMessageKey] = true
    }
}

/// GHOST hook target: the message fetched for the push is a «pinned» service message.
func ggMarkNotificationContent(_ userInfo: inout [AnyHashable: Any], media: Media?) {
    if GGNotificationServiceHooks.content.isEmpty {
        return
    }
    if let action = media as? TelegramMediaAction, case .pinnedMessageUpdated = action.action {
        userInfo[ggPinnedMessageKey] = true
    }
}

/// What the content point decides about a push before upstream builds the final content.
enum GGNotificationPreparation {
    case unchanged
    /// Deliver nothing (no content is generated, no Siri intent is donated).
    case hidden
    /// Show this text instead of the message: no custom emoji (`attributedBody`), no attachments and
    /// no donated Siri intent, which would all carry the real text.
    case hiddenBody(String)
}

/// GHOST hook target: called with upstream's content fields BEFORE `generate()`, which writes the
/// text into `attributedBody` (custom emoji, iOS 18+) and donates an `INSendMessageIntent` with it.
/// `ggNotificationContent` still runs on the generated content (titles, sound, marks).
func ggNotificationPreparation(title: String?, subtitle: String?, body: String?, userInfo: [AnyHashable: Any]) -> GGNotificationPreparation {
    if GGNotificationServiceHooks.content.isEmpty {
        return .unchanged
    }
    let original = GGNotificationContent(title: title ?? "", subtitle: subtitle ?? "", body: body ?? "", threadIdentifier: "", categoryIdentifier: "", isHidden: false, isSilent: false)
    let updated = GGNotificationServiceHooks.transform(original, context: ggNotificationContext(userInfo))
    if updated.isHidden {
        return .hidden
    }
    if updated.hidesAttachments || updated.body != original.body {
        return .hiddenBody(updated.body)
    }
    return .unchanged
}

private func ggNotificationContext(_ userInfo: [AnyHashable: Any]) -> GGNotificationContext {
    var accountId: AccountRecordId?
    if let value = userInfo["accountId"] as? String, let rawValue = Int64(value) {
        accountId = AccountRecordId(rawValue: rawValue)
    }
    var peerId: PeerId?
    if let value = userInfo["peerId"] as? String, let rawValue = Int64(value) {
        peerId = PeerId(rawValue)
    }
    var messageId: MessageId?
    if let peerId, let value = userInfo["msg_id"] as? String, let rawValue = Int32(value) {
        messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: rawValue)
    }
    let isPinnedMessage = (userInfo[ggPinnedMessageKey] as? Bool) ?? false
    let isMentionOrReply = (userInfo[ggMentionOrReplyKey] as? Bool) ?? false
    return GGNotificationContext(accountId: accountId, peerId: peerId, messageId: messageId, isPinnedMessage: isPinnedMessage, isMentionOrReply: isMentionOrReply)
}

/// GHOST hook target: the content handed to `contentHandler` (GGNotificationServiceHooks.content).
func ggNotificationContent(_ content: UNNotificationContent) -> UNNotificationContent {
    if GGNotificationServiceHooks.content.isEmpty {
        return content
    }
    let userInfo = content.userInfo
    let hasMarks = userInfo[ggPinnedMessageKey] != nil || userInfo[ggMentionOrReplyKey] != nil
    let original = GGNotificationContent(title: content.title, subtitle: content.subtitle, body: content.body, threadIdentifier: content.threadIdentifier, categoryIdentifier: content.categoryIdentifier, isHidden: false, isSilent: false)
    let updated = GGNotificationServiceHooks.transform(original, context: ggNotificationContext(userInfo))
    if updated == original && !hasMarks {
        return content
    }
    if updated.isHidden {
        return UNNotificationContent()
    }
    guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else {
        return content
    }
    if hasMarks {
        var cleanUserInfo = userInfo
        cleanUserInfo.removeValue(forKey: ggPinnedMessageKey)
        cleanUserInfo.removeValue(forKey: ggMentionOrReplyKey)
        mutable.userInfo = cleanUserInfo
    }
    mutable.title = updated.title
    mutable.subtitle = updated.subtitle
    mutable.body = updated.body
    mutable.threadIdentifier = updated.threadIdentifier
    mutable.categoryIdentifier = updated.categoryIdentifier
    if updated.isSilent {
        mutable.sound = nil
    }
    if updated.hidesAttachments {
        mutable.attachments = []
    }
    return mutable
}

/// GHOST hook target: every content the extension hands to the system, after the content point.
/// An empty one (upstream's way to drop a push, or hidden by the content point) goes as a passive
/// placeholder that is removed once delivered: without the filtering entitlement iOS would show the
/// server's own push instead (GGEmptyNotifications). Placeholders left by earlier pushes go first.
func ggDeliverNotificationContent(_ content: UNNotificationContent, requestIdentifier: String, to contentHandler: (UNNotificationContent) -> Void) {
    GGEmptyNotifications.removeDelivered()
    if GGEmptyNotifications.isEmpty(content) {
        contentHandler(GGEmptyNotifications.placeholder(badge: content.badge))
        GGEmptyNotifications.removeDelivered(waitingFor: requestIdentifier)
    } else {
        contentHandler(content)
    }
}
