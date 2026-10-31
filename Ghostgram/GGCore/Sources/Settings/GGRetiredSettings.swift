import Foundation

/// Settings this build no longer declares: a removed feature, or rows merged into one setting.
///
/// The registry keeps keys it does not know when it rewrites a file (`GGSettingsStore`), so a
/// retired key stays in the user's files forever unless a migration drops it. A migration reads the
/// last stored value first when its meaning moves to a new setting:
///
///     GGMigrations.registerGlobal(id: "appearance.merge.v1") { _ in
///         let chats = GGRetiredSettings.value("appearance.messages.hideReactionsInChats", as: Bool.self)
///         …
///         GGRetiredSettings.remove(keys: ["appearance.messages.hideReactionsInChats"])
///     }
///
/// An absent value means the old default (defaults were never written). A declared key is never
/// read or removed here. App process only: extensions read nothing and drop nothing.
public enum GGRetiredSettings {
    /// The stored value of a retired global or App Group key; nil when absent or of another type.
    public static func value<Value: GGSettingValue>(_ key: String, as type: Value.Type) -> Value? {
        guard let fragment = GGSettingsStore.shared.retiredFragment(key, account: nil) else {
            return nil
        }
        return GGSettingCodec.decode(Value.self, from: fragment)
    }

    /// The stored value of a retired account key; nil when absent or of another type.
    public static func value<Value: GGSettingValue>(_ key: String, as type: Value.Type, account: GGAccountID) -> Value? {
        guard let fragment = GGSettingsStore.shared.retiredFragment(key, account: account) else {
            return nil
        }
        return GGSettingCodec.decode(Value.self, from: fragment)
    }

    /// Drops retired keys from global.json and shared.json: `keys` exactly, `prefixes` as the start
    /// of a key ("feed." drops every key of a removed feature).
    public static func remove(keys: [String] = [], prefixes: [String] = []) {
        GGSettingsStore.shared.removeRetired(keys: keys, prefixes: prefixes, account: nil)
    }

    /// Drops retired keys from the account's settings file.
    public static func remove(keys: [String] = [], prefixes: [String] = [], account: GGAccountID) {
        GGSettingsStore.shared.removeRetired(keys: keys, prefixes: prefixes, account: account)
    }

    /// Deletes files a removed feature kept next to the account's settings
    /// (`<account.basePath>/ghostgram/<name>`), on a utility queue. Plain file names only.
    public static func removeAccountFiles(_ names: [String], account: GGAccountID) {
        if let process = GGSettingsStore.shared.processKind, !process.isApp {
            return
        }
        guard let directory = GGSettingsStore.shared.accountDirectory(account) else {
            return
        }
        let paths = names.filter { name in
            return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        }.map { name in
            return (directory as NSString).appendingPathComponent(name)
        }
        if paths.isEmpty {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            for path in paths where FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
