import Foundation
import SwiftSignalKit

/// Where a non-account setting is stored.
/// - `global`: `<appGroup>/ghostgram/settings/global.json`, read by the app only.
/// - `appGroup`: `<appGroup>/ghostgram/settings/shared.json`, small, read by the app and the
///   extensions (declare such settings in GGFeaturesShared with `.extensions`).
/// Account-scoped settings are `GGAccountSetting`.
public enum GGSettingScope: Equatable {
    case global
    case appGroup
}

public struct GGSettingFlags: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Secrets, hashes, tokens and internal state: never exported, imported or reset by
    /// "Reset all". The owning feature manages them.
    public static let noExport = GGSettingFlags(rawValue: 1 << 0)
    /// Read by the notification service / share extensions. Requires `.appGroup` scope or an
    /// account setting, and a declaration in GGFeaturesShared (linked into the extensions).
    public static let extensions = GGSettingFlags(rawValue: 1 << 1)
    /// The menu shows the localized "Restart required" footer after a change.
    public static let requiresRestart = GGSettingFlags(rawValue: 1 << 2)
}

/// What the store needs from any setting, without knowing its value type.
protocol GGAnySettingDescriptor: AnyObject {
    var key: String { get }
    var storageKind: GGSettingStorageKind { get }
    var flags: GGSettingFlags { get }

    /// Applies a stored JSON fragment (`nil`: absent, read the default). True when the value changed.
    func applyStored(_ fragment: Data?, account: GGAccountID?) -> Bool
    /// The value to write, or nil when it equals the default (the key is then dropped from the file).
    func storageFragment(account: GGAccountID?) -> Data?
    /// The current value, always encoded (export, diff display).
    func currentFragment(account: GGAccountID?) -> Data?
    /// Decodes an imported fragment; nil when it does not fit the type.
    func importCandidate(_ fragment: Data, account: GGAccountID?) -> GGSettingImportCandidate?
    /// Writes through the normal path (signals, persistence).
    func applyImported(_ fragment: Data, account: GGAccountID?)
    func resetValue(account: GGAccountID?)
    func dropAccount(_ account: GGAccountID)
    #if DEBUG
    var debugWasRead: Bool { get }
    #endif
}

enum GGSettingStorageKind: Equatable {
    case global
    case appGroup
    case account
}

struct GGSettingImportCandidate {
    let isChange: Bool
    let oldText: String
    let newText: String
    let canonicalFragment: Data
}

/// A global or App Group setting.
///
/// Declare it once, as a `static let` in the feature's enum, and touch every declaration from the
/// module's `register()` so the registry knows it before export, search and migrations:
///
///     enum GhostModeSettings {
///         static let hideReadReceipts = GGSetting<Bool>("ghostMode.hideReadReceipts", default: false)
///     }
///
/// `value` is the hot path: an uncontended lock and a copy of the value.
public final class GGSetting<Value: GGSettingValue> {
    public let key: String
    public let defaultValue: Value
    public let scope: GGSettingScope
    public let flags: GGSettingFlags

    let cell: GGValueCell<Value>

    public init(_ key: String, default defaultValue: Value, scope: GGSettingScope = .global, flags: GGSettingFlags = []) {
        self.key = key
        self.defaultValue = defaultValue
        self.scope = scope
        self.flags = flags
        self.cell = GGValueCell(defaultValue)

        assert(GGSettingsStore.isValidKey(key), "Setting key must be <feature>.<key> in camelCase: \(key)")
        assert(!flags.contains(.extensions) || scope == .appGroup, "\(key): .extensions needs scope .appGroup")
        GGSettingsStore.shared.register(self)
    }

    /// Current value. Safe on any thread; the hot path.
    public var value: Value {
        #if DEBUG
        if GGSettingsStore.debugIsExtensionProcess && !self.flags.contains(.extensions) {
            GGSettingsStore.shared.debugNoteExtensionRead(key: self.key)
        }
        return self.cell.currentMarkingRead
        #else
        return self.cell.current
        #endif
    }

    public func set(_ value: Value) {
        guard GGSettingsStore.shared.canWrite(key: self.key) else {
            return
        }
        if self.cell.update(value) {
            GGSettingsStore.shared.didChange(self, account: nil)
        }
    }

    public func reset() {
        self.set(self.defaultValue)
    }

    public var isDefault: Bool {
        return self.cell.current == self.defaultValue
    }

    /// The current value first, then every distinct change. Delivered on the writer's thread.
    public var signal: Signal<Value, NoError> {
        return self.cell.signal()
    }
}

extension GGSetting: GGAnySettingDescriptor {
    var storageKind: GGSettingStorageKind {
        switch self.scope {
        case .global:
            return .global
        case .appGroup:
            return .appGroup
        }
    }

    func applyStored(_ fragment: Data?, account: GGAccountID?) -> Bool {
        return self.cell.update(GGSettingDecoding.value(fragment, default: self.defaultValue, key: self.key))
    }

    func storageFragment(account: GGAccountID?) -> Data? {
        let current = self.cell.current
        if current == self.defaultValue {
            return nil
        }
        return GGSettingCodec.encode(current)
    }

    func currentFragment(account: GGAccountID?) -> Data? {
        return GGSettingCodec.encode(self.cell.current)
    }

    func importCandidate(_ fragment: Data, account: GGAccountID?) -> GGSettingImportCandidate? {
        return GGSettingDecoding.importCandidate(fragment, current: self.cell.current)
    }

    func applyImported(_ fragment: Data, account: GGAccountID?) {
        guard let value = GGSettingCodec.decode(Value.self, from: fragment) else {
            return
        }
        self.set(value)
    }

    func resetValue(account: GGAccountID?) {
        self.reset()
    }

    func dropAccount(_ account: GGAccountID) {
    }

    #if DEBUG
    var debugWasRead: Bool {
        return self.cell.debugWasRead
    }
    #endif
}

/// A setting with one value per Telegram account, stored in the account's own directory
/// (`<account.basePath>/ghostgram/settings.json`), so it leaves together with the account.
/// Exceptions, archives, bookmarks and per-account substitutions belong here.
public final class GGAccountSetting<Value: GGSettingValue> {
    public let key: String
    public let defaultValue: Value
    public let flags: GGSettingFlags

    let cell: GGAccountValueCell<Value>

    public init(_ key: String, default defaultValue: Value, flags: GGSettingFlags = []) {
        self.key = key
        self.defaultValue = defaultValue
        self.flags = flags
        self.cell = GGAccountValueCell(defaultValue: defaultValue)

        assert(GGSettingsStore.isValidKey(key), "Setting key must be <feature>.<key> in camelCase: \(key)")
        GGSettingsStore.shared.register(self)
    }

    /// Value for an account; the default for accounts that are not registered. The hot path.
    public func value(for account: GGAccountID) -> Value {
        #if DEBUG
        if GGSettingsStore.debugIsExtensionProcess && !self.flags.contains(.extensions) {
            GGSettingsStore.shared.debugNoteExtensionRead(key: self.key)
        }
        return self.cell.currentMarkingRead(for: account)
        #else
        return self.cell.current(for: account)
        #endif
    }

    public func set(_ value: Value, for account: GGAccountID) {
        guard GGSettingsStore.shared.canWrite(key: self.key) else {
            return
        }
        guard GGSettingsStore.shared.isAccountRegistered(account) else {
            GGLog.warning("settings", "\(self.key): write for an account that is not registered")
            return
        }
        if self.cell.update(value, for: account) {
            GGSettingsStore.shared.didChange(self, account: account)
        }
    }

    public func reset(for account: GGAccountID) {
        self.set(self.defaultValue, for: account)
    }

    public func isDefault(for account: GGAccountID) -> Bool {
        return self.cell.current(for: account) == self.defaultValue
    }

    /// The account's current value first, then every distinct change.
    public func signal(for account: GGAccountID) -> Signal<Value, NoError> {
        return self.cell.signal(for: account)
    }
}

extension GGAccountSetting: GGAnySettingDescriptor {
    var storageKind: GGSettingStorageKind {
        return .account
    }

    func applyStored(_ fragment: Data?, account: GGAccountID?) -> Bool {
        guard let account = account else {
            return false
        }
        let value = GGSettingDecoding.value(fragment, default: self.defaultValue, key: self.key)
        return self.cell.update(value, for: account)
    }

    func storageFragment(account: GGAccountID?) -> Data? {
        guard let account = account else {
            return nil
        }
        let current = self.cell.current(for: account)
        if current == self.defaultValue {
            return nil
        }
        return GGSettingCodec.encode(current)
    }

    func currentFragment(account: GGAccountID?) -> Data? {
        guard let account = account else {
            return nil
        }
        return GGSettingCodec.encode(self.cell.current(for: account))
    }

    func importCandidate(_ fragment: Data, account: GGAccountID?) -> GGSettingImportCandidate? {
        guard let account = account else {
            return nil
        }
        return GGSettingDecoding.importCandidate(fragment, current: self.cell.current(for: account))
    }

    func applyImported(_ fragment: Data, account: GGAccountID?) {
        guard let account = account, let value = GGSettingCodec.decode(Value.self, from: fragment) else {
            return
        }
        self.set(value, for: account)
    }

    func resetValue(account: GGAccountID?) {
        guard let account = account else {
            return
        }
        self.reset(for: account)
    }

    func dropAccount(_ account: GGAccountID) {
        self.cell.update(nil, for: account)
    }

    #if DEBUG
    var debugWasRead: Bool {
        return self.cell.debugWasRead
    }
    #endif
}

enum GGSettingDecoding {
    static func value<Value: GGSettingValue>(_ fragment: Data?, default defaultValue: Value, key: String) -> Value {
        guard let fragment = fragment else {
            return defaultValue
        }
        if let value = GGSettingCodec.decode(Value.self, from: fragment) {
            return value
        }
        // A stored value of another type (the declaration changed): read the default. The stored
        // fragment stays in the file until the setting is written again.
        GGLog.warning("settings", "\(key): stored value does not match the declared type")
        return defaultValue
    }

    static func importCandidate<Value: GGSettingValue>(_ fragment: Data, current: Value) -> GGSettingImportCandidate? {
        guard let newValue = GGSettingCodec.decode(Value.self, from: fragment) else {
            return nil
        }
        guard let canonical = GGSettingCodec.encode(newValue) else {
            return nil
        }
        return GGSettingImportCandidate(
            isChange: newValue != current,
            oldText: GGSettingCodec.text(GGSettingCodec.encode(current)),
            newText: GGSettingCodec.text(canonical),
            canonicalFragment: canonical
        )
    }
}
