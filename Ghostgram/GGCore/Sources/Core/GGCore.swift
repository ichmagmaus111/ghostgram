import Foundation

/// The process GGCore runs in. Extensions only read settings and never run migrations.
public enum GGProcessKind: String {
    case app
    case notificationService
    case notificationContent
    case share
    case widget
    case intents
    case broadcastUpload
    case other

    public var isApp: Bool {
        return self == .app
    }
}

public struct GGCoreEnvironment {
    /// Path of the App Group container (`group.<base bundle id>`).
    public let appGroupPath: String
    public let process: GGProcessKind
    /// App Group of the previous Ghostgram installation, read by migrations. `nil` means
    /// `group.<main bundle id>`: the old app had the same bundle id.
    public let legacyAppGroupIdentifier: String?

    public init(appGroupPath: String, process: GGProcessKind, legacyAppGroupIdentifier: String? = nil) {
        self.appGroupPath = appGroupPath
        self.process = process
        self.legacyAppGroupIdentifier = legacyAppGroupIdentifier
    }

    var ghostgramPath: String {
        return (self.appGroupPath as NSString).appendingPathComponent("ghostgram")
    }

    var settingsDirectoryPath: String {
        return (self.ghostgramPath as NSString).appendingPathComponent("settings")
    }

    var inboxDirectoryPath: String {
        return (self.ghostgramPath as NSString).appendingPathComponent("inbox")
    }
}

/// Entry points called once per process from the launch path (see FOUNDATION_SPEC §2).
public enum GGCore {
    private static let lock = GGUnfairLock()
    private static var currentEnvironment: GGCoreEnvironment?

    /// The environment passed to `bootstrap`, or nil before it.
    public static var environment: GGCoreEnvironment? {
        return GGCore.lock.withLock {
            return GGCore.currentEnvironment
        }
    }

    /// Loads the settings files of this process. Call first, before any feature registers.
    public static func bootstrap(_ environment: GGCoreEnvironment) {
        let isFirst = GGCore.lock.withLock { () -> Bool in
            if GGCore.currentEnvironment != nil {
                return false
            }
            GGCore.currentEnvironment = environment
            return true
        }
        if !isFirst {
            assertionFailure("GGCore.bootstrap must be called once")
            return
        }
        GGLog.bootstrap(process: environment.process)
        GGSettingsStore.shared.bootstrap(environment)
        // Registers core.language and resolves the language before the first string is read.
        let _ = GGLocalization.shared
    }

    /// Extensions: reads the settings files again (iOS reuses an extension's process for the next
    /// request while the app goes on changing them). Call at the start of every request after the
    /// first; does nothing in the app.
    public static func reloadSettings() {
        GGSettingsStore.shared.reloadFromDisk()
    }

    /// Runs the registered one-time migrations from the old Ghostgram. App process only, after
    /// all modules have registered (`GGFeatures.registerAll()`).
    public static func runGlobalMigrations() {
        GGMigrations.runPending()
    }
}
