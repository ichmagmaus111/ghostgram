import Foundation
import GGCore

/// The old client's keys of the «Безопасность» zone → the new settings. App process only; registered
/// from `GGSecurityShared.register()`, i.e. before the feature modules, so the Misc master switch is
/// still there when the screenshot setting is read (W2-3 removes it in its own migration).
///
/// Not moved on purpose: the double bottom (`GG.fb.*`), session import and the session backup (not
/// ported, owner 2026-10-22); «collapse accounts in Settings» (removed, owner 2026-10-27). The old
/// shared `secretFolderId` (`SGSimpleSettings`, per-account profiles off) is moved only when the
/// device has one account: folder ids are per account, and with several the old key could not say
/// which account it meant (moving it to every account is exactly the old bug of a random folder
/// becoming «secret»). With the profiles on, each account takes its own value (`migrateAccount`).
enum GGSecurityMigrations {
    static func register() {
        GGMigrations.registerGlobal(id: "security.v1") { legacy in
            GGSecurityMigrations.migrateGlobal(legacy)
        }
        GGMigrations.registerAccount(id: "security.account.v1") { legacy, account in
            GGSecurityMigrations.migrateAccount(legacy, account: account)
        }
        // «Сворачивать аккаунты в Настройках» was removed (owner, 2026-10-27): its switch and the
        // collapsed state of builds ≤ 186 go too.
        GGMigrations.registerGlobal(id: "security.accounts.collapse.removed.v1") { legacy in
            GGRetiredSettings.remove(keys: ["security.accounts.collapsible", "security.accounts.collapsed"])
            legacy.removeLegacyKey("GG.fontCustomization.settingsAccountsCollapsed")
        }
    }

    private static func migrateGlobal(_ legacy: GGLegacyDefaults) {
        if let value = legacy.bool("chatProtectionEnabled") {
            GGSecuritySharedSettings.chatLockEnabled.set(value)
            legacy.removeLegacyKey("chatProtectionEnabled")
        }
        if let value = legacy.string("chatProtectionTargetMode") {
            GGSecuritySharedSettings.chatLockAllChats.set(value == "all")
            legacy.removeLegacyKey("chatProtectionTargetMode")
        }
        if let value = legacy.bool("sensitiveChatsAutolockEnabled") {
            GGSecuritySettings.chatLockAutolock.set(value)
            legacy.removeLegacyKey("sensitiveChatsAutolockEnabled")
        }
        if let value = legacy.int("sensitiveChatsAutolockTimeout") {
            GGSecuritySettings.chatLockAutolockTimeout.set(GGSecurityMigrations.nearestTimeout(value))
            legacy.removeLegacyKey("sensitiveChatsAutolockTimeout")
        }
        if let value = legacy.bool("accountSwitchAuthEnabled") {
            GGSecuritySettings.accountSwitchAuth.set(value)
            legacy.removeLegacyKey("accountSwitchAuthEnabled")
        }
        // The old «Прочее» master gated every Misc switch; only both on meant «on». The master key
        // itself belongs to W2-3's migration and is left in place.
        if let value = legacy.bool("MiscSettings.screenshotPrivacyMode") {
            let master = legacy.bool("MiscSettings.isEnabled") ?? false
            GGSecuritySettings.screenshotPrivacy.set(value && master)
            legacy.removeLegacyKey("MiscSettings.screenshotPrivacyMode")
        }
        if let value = legacy.bool("GG.fontCustomization.showChatListAccountSwitcher") {
            GGSecuritySettings.accountsHeaderButton.set(value)
            legacy.removeLegacyKey("GG.fontCustomization.showChatListAccountSwitcher")
        }
    }

    /// The chosen chats were a list of `PeerId.toInt64()` strings; a user's peer id is the same in every
    /// account. With the old per-account profiles off every account takes the shared values — the
    /// secret folder only when the device has one account (folder ids are an account's own); with them
    /// on the shared keys are the active account's live values and any other account takes its own
    /// profile only (`legacyAccountValue`). The shared keys stay until every account has run this.
    private static func migrateAccount(_ legacy: GGLegacyDefaults, account: GGAccountID) {
        let raw = legacy.legacyAccountValue("chatProtectionSelectedChats", for: account) as? [String]
        if let raw, !raw.isEmpty {
            var keys = Set<GGPeerKey>()
            for text in raw {
                if let value = Int64(text) {
                    keys.insert(GGLegacyKeys.peerKey(fromLegacyInt64: value))
                }
            }
            if !keys.isEmpty {
                GGSecuritySharedSettings.chatLockPeers.set(keys, for: account)
            }
        }
        if legacy.legacyAccountProfilesEnabled || GGLegacyAccounts.isSingleAccount {
            if let folderId = legacy.legacyAccountValue("secretFolderId", for: account) as? NSNumber, folderId.int32Value != 0 {
                GGSecuritySettings.secretFolderId.set(folderId.int32Value, for: account)
            }
        }
    }

    private static func nearestTimeout(_ seconds: Int) -> String {
        let allowed = [0, 15, 30, 60, 300]
        var best = 0
        for value in allowed where value <= max(0, seconds) {
            best = value
        }
        return "\(best)"
    }
}
