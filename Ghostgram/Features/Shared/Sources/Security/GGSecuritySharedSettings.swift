import Foundation
import GGCore

/// Settings of «Безопасность» that the extensions read (notification service, Siri): which chats are
/// protected. The policies are global on purpose (the old client made them per-account by accident and
/// lost them on an account without a snapshot); the lists are per account, because peer ids and
/// folder ids belong to an account.
public enum GGSecuritySharedSettings {
    /// «Пароль на чаты».
    public static let chatLockEnabled = GGSetting<Bool>("security.chatLock.enabled", default: false, scope: .appGroup, flags: [.extensions])
    /// «Применять к»: every chat instead of the chosen ones.
    public static let chatLockAllChats = GGSetting<Bool>("security.chatLock.allChats", default: false, scope: .appGroup, flags: [.extensions])
    /// «Выбранные чаты» of the account.
    public static let chatLockPeers = GGAccountSetting<Set<GGPeerKey>>("security.chatLock.peers", default: [], flags: [.extensions])
    /// Members of the account's secret folder whose chats are protected while the folder is locked
    /// («Защищать чаты папки»). Kept by the app from a live view of the folder, read by the
    /// notification service; derived data, so never exported.
    public static let secretFolderPeers = GGAccountSetting<Set<GGPeerKey>>("security.secretFolder.peers", default: [], flags: [.extensions, .noExport])
    /// The app's resolved Ghostgram language, for the texts the notification service writes (the
    /// extension does not know Telegram's language). Written by the app, never exported.
    public static let extensionLanguage = GGSetting<String>("security.extensionLanguage", default: "", scope: .appGroup, flags: [.extensions, .noExport])

    static func declare() {
        let _ = GGSecuritySharedSettings.chatLockEnabled
        let _ = GGSecuritySharedSettings.chatLockAllChats
        let _ = GGSecuritySharedSettings.chatLockPeers
        let _ = GGSecuritySharedSettings.secretFolderPeers
        let _ = GGSecuritySharedSettings.extensionLanguage
    }
}
