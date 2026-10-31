import Foundation

/// One-time moves of the old Ghostgram settings (same bundle id, so the old `UserDefaults` are
/// still there after an update). Each feature registers its own "old key → new setting" table in
/// its `register()`; GGCore only runs them.
///
///     GGMigrations.registerGlobal(id: "ghostMode.v1") { legacy in
///         if let value = legacy.bool("GhostMode.hideReadReceipts") {
///             GhostModeSettings.hideReadReceipts.set(value)
///             legacy.removeLegacyKey("GhostMode.hideReadReceipts")
///         }
///     }
///
/// A migration runs once: its id is stored in `global.json` (account migrations: in the account's
/// file) after the body returns. Ids are stable; to migrate again, register a new id. Bodies run
/// in the app process only, global ones on the launch thread, account ones on the thread that
/// creates the `Account`; they may only read `legacy` and write Ghostgram settings.
public enum GGMigrations {
    private struct GlobalEntry {
        let id: String
        let body: (GGLegacyDefaults) -> Void
    }

    private struct AccountEntry {
        let id: String
        let body: (GGLegacyDefaults, GGAccountID) -> Void
    }

    private struct AccountPeerEntry {
        let id: String
        let body: (GGLegacyDefaults, GGAccountID, GGPeerKey) -> Void
    }

    private static let lock = GGUnfairLock()
    private static var globalEntries: [GlobalEntry] = []
    private static var accountEntries: [AccountEntry] = []
    private static var accountPeerEntries: [AccountPeerEntry] = []
    /// The account's own peer, once the TelegramCore bridge reported it in this process.
    private static var accountPeers: [GGAccountID: GGPeerKey] = [:]

    static let completedGlobal = GGSetting<[String]>("core.migrations.done", default: [], flags: [.noExport])
    static let completedAccount = GGAccountSetting<[String]>("core.migrations.accountDone", default: [], flags: [.noExport])

    /// `id` is unique and stable ("ghostMode.v1"). Runs once, the flag is stored in global.json.
    public static func registerGlobal(id: String, _ body: @escaping (GGLegacyDefaults) -> Void) {
        let isDuplicate = GGMigrations.lock.withLock { () -> Bool in
            if GGMigrations.globalEntries.contains(where: { $0.id == id }) {
                return true
            }
            GGMigrations.globalEntries.append(GlobalEntry(id: id, body: body))
            return false
        }
        assert(!isDuplicate, "Duplicate migration id \(id)")
    }

    /// Runs once per account, when the account registers (and for accounts registered before the
    /// migration was declared, from `GGCore.runGlobalMigrations()`).
    public static func registerAccount(id: String, _ body: @escaping (GGLegacyDefaults, GGAccountID) -> Void) {
        let isDuplicate = GGMigrations.lock.withLock { () -> Bool in
            if GGMigrations.isAccountIdTaken(id) {
                return true
            }
            GGMigrations.accountEntries.append(AccountEntry(id: id, body: body))
            return false
        }
        assert(!isDuplicate, "Duplicate migration id \(id)")
    }

    /// Like `registerAccount`, for old data keyed by the account's own peer id (the old client used
    /// `PeerId.toInt64()` of the account: `GGLegacyKeys.legacyInt64(of: peer)`). The peer is known
    /// only once the account starts (`Account.init`), so the body runs then — after the account's
    /// settings are loaded and before the features' `GGAccountHooks.accountWillStart` handlers.
    /// Shares the "done" list (and the id space) with `registerAccount`.
    public static func registerAccountPeer(id: String, _ body: @escaping (GGLegacyDefaults, GGAccountID, GGPeerKey) -> Void) {
        let isDuplicate = GGMigrations.lock.withLock { () -> Bool in
            if GGMigrations.isAccountIdTaken(id) {
                return true
            }
            GGMigrations.accountPeerEntries.append(AccountPeerEntry(id: id, body: body))
            return false
        }
        assert(!isDuplicate, "Duplicate migration id \(id)")
    }

    /// Called by the TelegramCore bridge when an account starts and its own peer is known: runs the
    /// account's pending `registerAccountPeer` migrations. App process only; other processes only
    /// remember the peer.
    public static func accountPeerDidLoad(_ account: GGAccountID, peer: GGPeerKey) {
        GGMigrations.lock.withLock {
            GGMigrations.accountPeers[account] = peer
        }
        GGMigrations.runPendingAccountPeerMigrations(for: account, peer: peer)
    }

    /// Lock held.
    private static func isAccountIdTaken(_ id: String) -> Bool {
        if GGMigrations.accountEntries.contains(where: { $0.id == id }) {
            return true
        }
        return GGMigrations.accountPeerEntries.contains(where: { $0.id == id })
    }

    /// `GGCore.runGlobalMigrations()`: every pending global migration, then the pending account
    /// migrations of the accounts already registered. App process only.
    static func runPending(legacy: GGLegacyDefaults? = nil) {
        guard GGSettingsStore.shared.processKind == .app else {
            return
        }
        let legacyDefaults = legacy ?? GGLegacyDefaults.current()
        let entries = GGMigrations.lock.withLock {
            return GGMigrations.globalEntries
        }
        var completed = GGMigrations.completedGlobal.value
        var didRun = false
        for entry in entries where !completed.contains(entry.id) {
            GGLog.info("migrations", "running \(entry.id)")
            entry.body(legacyDefaults)
            completed.append(entry.id)
            didRun = true
        }
        if didRun {
            GGMigrations.completedGlobal.set(completed)
        }
        for account in GGSettingsStore.shared.registeredAccounts {
            GGMigrations.runPendingAccountMigrations(for: account, legacy: legacyDefaults)
            let peer = GGMigrations.lock.withLock {
                return GGMigrations.accountPeers[account]
            }
            if let peer = peer {
                GGMigrations.runPendingAccountPeerMigrations(for: account, peer: peer, legacy: legacyDefaults)
            }
        }
        if didRun {
            GGSettingsStore.shared.flush()
        }
    }

    static func runPendingAccountMigrations(for account: GGAccountID, legacy: GGLegacyDefaults? = nil) {
        guard GGSettingsStore.shared.processKind == .app else {
            return
        }
        let entries = GGMigrations.lock.withLock {
            return GGMigrations.accountEntries
        }
        if entries.isEmpty {
            return
        }
        var legacyDefaults = legacy
        var completed = GGMigrations.completedAccount.value(for: account)
        var didRun = false
        for entry in entries where !completed.contains(entry.id) {
            if legacyDefaults == nil {
                legacyDefaults = GGLegacyDefaults.current()
            }
            guard let defaults = legacyDefaults else {
                continue
            }
            GGLog.info("migrations", "running \(entry.id) for an account")
            entry.body(defaults, account)
            completed.append(entry.id)
            didRun = true
        }
        if didRun {
            GGMigrations.completedAccount.set(completed, for: account)
        }
    }

    static func runPendingAccountPeerMigrations(for account: GGAccountID, peer: GGPeerKey, legacy: GGLegacyDefaults? = nil) {
        guard GGSettingsStore.shared.processKind == .app else {
            return
        }
        let entries = GGMigrations.lock.withLock {
            return GGMigrations.accountPeerEntries
        }
        if entries.isEmpty || !GGSettingsStore.shared.registeredAccounts.contains(account) {
            return
        }
        var legacyDefaults = legacy
        var completed = GGMigrations.completedAccount.value(for: account)
        var didRun = false
        for entry in entries where !completed.contains(entry.id) {
            if legacyDefaults == nil {
                legacyDefaults = GGLegacyDefaults.current()
            }
            guard let defaults = legacyDefaults else {
                continue
            }
            GGLog.info("migrations", "running \(entry.id) for an account")
            entry.body(defaults, account, peer)
            completed.append(entry.id)
            didRun = true
        }
        if didRun {
            GGMigrations.completedAccount.set(completed, for: account)
        }
    }

    /// Tests only.
    static func resetForTesting() {
        GGMigrations.lock.withLock {
            GGMigrations.globalEntries.removeAll()
            GGMigrations.accountEntries.removeAll()
            GGMigrations.accountPeerEntries.removeAll()
            GGMigrations.accountPeers.removeAll()
        }
    }
}

/// Read access to the settings of the old Ghostgram: `UserDefaults.standard` and the old App
/// Group suite. Typed getters return nil when the key is absent or holds another type.
public struct GGLegacyDefaults {
    private let stores: [UserDefaults]

    init(stores: [UserDefaults]) {
        self.stores = stores
    }

    /// `UserDefaults.standard` plus `group.<main bundle id>` (or the environment's legacy group).
    static func current() -> GGLegacyDefaults {
        var stores: [UserDefaults] = [UserDefaults.standard]
        var groupIdentifier = GGCore.environment?.legacyAppGroupIdentifier
        if groupIdentifier == nil, let bundleIdentifier = Bundle.main.bundleIdentifier {
            groupIdentifier = "group.\(bundleIdentifier)"
        }
        if let groupIdentifier = groupIdentifier, let group = UserDefaults(suiteName: groupIdentifier) {
            stores.append(group)
        }
        return GGLegacyDefaults(stores: stores)
    }

    public func object(_ key: String) -> Any? {
        for store in self.stores {
            if let value = store.object(forKey: key) {
                return value
            }
        }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = self.object(key) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    public func int(_ key: String) -> Int? {
        guard let value = self.object(key) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    public func double(_ key: String) -> Double? {
        guard let value = self.object(key) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    public func string(_ key: String) -> String? {
        return self.object(key) as? String
    }

    public func data(_ key: String) -> Data? {
        return self.object(key) as? Data
    }

    public func stringArray(_ key: String) -> [String]? {
        guard let array = self.object(key) as? [Any] else {
            return nil
        }
        var result: [String] = []
        for item in array {
            guard let string = item as? String else {
                return nil
            }
            result.append(string)
        }
        return result
    }

    /// Removes the key from every store, after its value has been moved.
    public func removeLegacyKey(_ key: String) {
        for store in self.stores {
            store.removeObject(forKey: key)
        }
    }

    /// The per-account profile of the old `GGAccountConfigManager` (`GG.accountConfigs.snapshots.
    /// <client>.<sanitized account>`): the old account-scoped `GhostMode.*` / `MiscSettings.*` /
    /// `DeviceSpoof.*` values of that account, or nil when profiles were never saved for it.
    /// The old code keyed it by the sanitized `"\(AccountRecordId)"` text, which loses the sign of
    /// the id; a profile of the negated id would also match (practically never, ids are random).
    public func legacyAccountProfile(for account: GGAccountID) -> [String: Any]? {
        let sanitized = GGLegacyDefaults.sanitizedAccountText(account)
        for client in ["ghostgram", "glegram"] {
            if let profile = self.object("GG.accountConfigs.snapshots.\(client).\(sanitized)") as? [String: Any] {
                return profile
            }
        }
        return nil
    }

    /// Whether the old per-account profiles were switched on (`GG.accountConfigs.enabled.ghostgram`).
    public var legacyAccountProfilesEnabled: Bool {
        return self.bool("GG.accountConfigs.enabled.ghostgram") ?? false
    }

    /// The value an old account-scoped key had for `account`. Profiles off: the one shared value.
    /// Profiles on: the shared keys hold the live values of the account that was active
    /// (`GG.accountConfigs.activeAccountId.ghostgram`; its profile was saved only when switching
    /// away and may be stale); any other account has its profile only — a key missing there was
    /// unset for that account, never the active account's value.
    public func legacyAccountValue(_ key: String, for account: GGAccountID) -> Any? {
        if !self.legacyAccountProfilesEnabled {
            return self.object(key)
        }
        if self.string("GG.accountConfigs.activeAccountId.ghostgram") == GGLegacyDefaults.sanitizedAccountText(account) {
            return self.object(key)
        }
        return self.legacyAccountProfile(for: account)?[key]
    }

    static func sanitizedAccountText(_ account: GGAccountID) -> String {
        let text = "AccountRecordId(rawValue: \(account.rawValue))"
        var result = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
        return result
    }
}
