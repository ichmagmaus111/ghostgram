import Foundation
import Postbox
import TelegramCore
import GGCore

/// Which chats are protected — configuration only (the app's unlock state is GGSecurity's). One
/// answer for every place that must not show a protected chat's content: the chat list preview and
/// the search (app), the push text (notification service), in-app banners, the widget and Siri.
public enum GGChatProtection {
    /// The chat is protected by «Пароль на чаты» or belongs to the locked-away secret folder.
    /// Snapshot reads only: layout paths, signal maps, the extensions.
    public static func isProtected(account: GGAccountID, peerId: PeerId) -> Bool {
        let key = peerId.ggKey
        if GGSecuritySharedSettings.chatLockEnabled.value {
            if GGSecuritySharedSettings.chatLockAllChats.value {
                return GGChatProtection.isLockable(peerId)
            }
            if GGSecuritySharedSettings.chatLockPeers.value(for: account).contains(key) {
                return true
            }
        }
        return GGSecuritySharedSettings.secretFolderPeers.value(for: account).contains(key)
    }

    /// «Все чаты» means every chat except Telegram's service notifications (777000): login codes must
    /// stay readable in their pushes.
    public static func isLockable(_ peerId: PeerId) -> Bool {
        if peerId.namespace == Namespaces.Peer.CloudUser && peerId.id._internalGetInt64Value() == 777000 {
            return false
        }
        return true
    }

    /// Notification service, Siri, in-app banners, widget (GGContentPrivacyHooks.hidesContent) and the
    /// push text (GGNotificationServiceHooks.content).
    static func register() {
        GGContentPrivacyHooks.hidesContent.register({ accountId, peerId in
            return GGChatProtection.isProtected(account: accountId.gg, peerId: peerId)
        })
        GGNotificationServiceHooks.content.register({ content, context in
            guard let accountId = context.accountId, let peerId = context.peerId, !content.isHidden else {
                return
            }
            if !GGChatProtection.isProtected(account: accountId.gg, peerId: peerId) {
                return
            }
            GGChatProtection.adoptAppLanguage()
            content.body = GGStrings.Security.Notifications.hiddenText
            content.hidesAttachments = true
        }, order: 10000)
    }

    /// The extension does not learn Telegram's language from a PresentationData; the app leaves it in
    /// `extensionLanguage` (the user's manual Ghostgram language still wins inside GGLocalization).
    private static func adoptAppLanguage() {
        if GGCore.environment?.process.isApp ?? true {
            return
        }
        let code = GGSecuritySharedSettings.extensionLanguage.value
        if !code.isEmpty {
            GGLocalization.shared.setTelegramLanguageCode(code)
        }
    }
}
