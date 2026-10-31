import Foundation
import GGCore

/// App-side settings of «Безопасность» (GGSecurity reads them; the extensions do not). Declared here,
/// next to the shared ones, so that the old client's keys can be moved in one place before the other
/// zones' migrations run (W2-3 consumes `MiscSettings.isEnabled`).
///
/// Scope rule (fixes the old «конфиги для аккаунтов» trap): every policy is global and says so in its
/// footer; what names a chat or a folder of an account is per account.
public enum GGSecuritySettings {
    // MARK: Chat lock

    /// «Автоблокировка»: one unlock opens every protected chat of the account until the app has been
    /// in the background for `chatLockAutolockTimeout`. Off: a chat is unlocked for as long as it
    /// stays open and asks again next time.
    public static let chatLockAutolock = GGSetting<Bool>("security.chatLock.autolock", default: false)
    /// Seconds in the background before the lock comes back: "0", "15", "30", "60", "300".
    /// "0" also closes an open protected chat when the app goes to the background.
    public static let chatLockAutolockTimeout = GGSetting<String>("security.chatLock.autolockTimeout", default: "0")

    // MARK: Secret folder

    /// The account's secret folder (`ChatListFilter.id`); 0 = none. Folder ids are per account.
    public static let secretFolderId = GGAccountSetting<Int32>("security.secretFolder.id", default: 0)
    /// «Защищать чаты папки»: while the folder is locked its chats are protected everywhere else too.
    public static let secretFolderProtectChats = GGAccountSetting<Bool>("security.secretFolder.protectChats", default: false)

    // MARK: Accounts

    /// «Face ID при смене аккаунта» — one key for every way of switching.
    public static let accountSwitchAuth = GGSetting<Bool>("security.accountSwitchAuth", default: false)
    /// The next account's avatar in the «Чаты» header: tap — switch, long press — the accounts menu.
    public static let accountsHeaderButton = GGSetting<Bool>("security.accounts.headerButton", default: false)

    // MARK: Screenshots

    /// «Скрывать чат на скриншотах»: the chat's header, input and panels come out empty.
    public static let screenshotPrivacy = GGSetting<Bool>("security.screenshotPrivacy", default: false)
    /// The same for the whole chat list.
    public static let screenshotPrivacyChatList = GGSetting<Bool>("security.screenshotPrivacyChatList", default: false)

    // MARK: Passcode

    /// Lock on every cold start (when a passcode is set), whatever the auto-lock timeout says.
    public static let passcodeLockOnLaunch = GGSetting<Bool>("security.passcode.lockOnLaunch", default: false)
    /// More auto-lock values in Telegram's passcode screen.
    public static let passcodeMoreAutolockOptions = GGSetting<Bool>("security.passcode.moreAutolockOptions", default: false)
    /// Whether a Telegram passcode is set, as last seen by the app (AppLock's init asks before any
    /// signal has delivered). Cache, not exported.
    public static let passcodeIsSet = GGSetting<Bool>("security.passcode.isSet", default: false, flags: [.noExport])

    static func declare() {
        let _ = GGSecuritySettings.chatLockAutolock
        let _ = GGSecuritySettings.chatLockAutolockTimeout
        let _ = GGSecuritySettings.secretFolderId
        let _ = GGSecuritySettings.secretFolderProtectChats
        let _ = GGSecuritySettings.accountSwitchAuth
        let _ = GGSecuritySettings.accountsHeaderButton
        let _ = GGSecuritySettings.screenshotPrivacy
        let _ = GGSecuritySettings.screenshotPrivacyChatList
        let _ = GGSecuritySettings.passcodeLockOnLaunch
        let _ = GGSecuritySettings.passcodeMoreAutolockOptions
        let _ = GGSecuritySettings.passcodeIsSet
    }

    /// The timeout as seconds.
    public static var chatLockAutolockSeconds: Double {
        return Double(GGSecuritySettings.chatLockAutolockTimeout.value) ?? 0.0
    }
}
