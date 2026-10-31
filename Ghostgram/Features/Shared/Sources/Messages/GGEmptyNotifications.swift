import Foundation
import UserNotifications

/// Pushes that must show nothing: read or deleted on another device, read reactions and stories, a
/// muted chat, logout, a hidden account, a pinned message or a mention whose notifications are turned
/// off. Telegram's extension drops them by handing iOS an empty content, which works only with
/// Apple's `com.apple.developer.usernotifications.filtering` entitlement (the official app only).
/// Without it iOS shows the server's own text («У вас новое сообщение») or an empty banner.
///
/// The old Ghostgram's fix (Swiftgram's, made the default there): such a push is delivered as a
/// passive placeholder — no sound, no banner, no lit screen — in its own thread, and removed from
/// Notification Center: by the extension right after it is delivered, at the next push, and when the
/// app becomes active (what the extension did not live to remove). The thread name is the old
/// client's, so its leftovers go too. Always on, no setting.
public enum GGEmptyNotifications {
    public static let threadIdentifier = "empty-notification"

    private static let queue = DispatchQueue(label: "org.ghostgram.emptyNotifications", qos: .utility)

    /// Nothing visible: no title, subtitle, text (`attributedBody` included — custom emoji, iOS 18)
    /// or attachment.
    public static func isEmpty(_ content: UNNotificationContent) -> Bool {
        if !content.title.isEmpty || !content.subtitle.isEmpty || !content.body.isEmpty || !content.attachments.isEmpty {
            return false
        }
        if #available(iOS 18.0, *), content.responds(to: NSSelectorFromString("attributedBody")) {
            if let attributedBody = content.value(forKey: "attributedBody") as? NSAttributedString, attributedBody.length != 0 {
                return false
            }
        }
        return true
    }

    /// What to hand to the system instead of an empty content; the badge stays (a read on another
    /// device lowers it).
    public static func placeholder(badge: NSNumber?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        // An empty title would make the content empty again: iOS then shows the original push.
        content.title = " "
        content.threadIdentifier = GGEmptyNotifications.threadIdentifier
        content.badge = badge
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
            content.relevanceScore = 0.0
        }
        return content
    }

    /// Removes the placeholders in Notification Center. With `waitingFor`, polls every 0.1 s (up to
    /// `attempts` times) until that request has been delivered: right after `contentHandler` it is not
    /// there yet, and an older placeholder found first must not end the wait.
    public static func removeDelivered(waitingFor requestIdentifier: String? = nil, attempts: Int = 30) {
        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { notifications in
            var identifiers: [String] = []
            var foundRequest = requestIdentifier == nil
            for notification in notifications where notification.request.content.threadIdentifier == GGEmptyNotifications.threadIdentifier {
                identifiers.append(notification.request.identifier)
                if notification.request.identifier == requestIdentifier {
                    foundRequest = true
                }
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            }
            if !foundRequest && attempts > 1 {
                GGEmptyNotifications.queue.asyncAfter(deadline: .now() + 0.1, execute: {
                    GGEmptyNotifications.removeDelivered(waitingFor: requestIdentifier, attempts: attempts - 1)
                })
            }
        })
    }
}
