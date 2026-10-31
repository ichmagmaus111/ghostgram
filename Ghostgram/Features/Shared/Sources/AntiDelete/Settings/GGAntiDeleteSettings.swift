import Foundation
import GGCore

/// Every setting of anti-delete, edit history, local edits and bookmarks, declared once.
/// What the notification service reads (capture) is `.appGroup` + `.extensions`, or an account
/// setting with `.extensions`; the rest is app-only.
public enum GGAntiDeleteSettings {
    // MARK: Capture (read by the notification service too)

    /// Keep messages other people (or the server) deleted.
    public static let enabled = GGSetting<Bool>("antiDelete.enabled", default: false, scope: .appGroup, flags: [.extensions])
    /// Keep one's own outgoing messages deleted «for everyone» (here or on another device).
    public static let keepOwn = GGSetting<Bool>("antiDelete.keepOwn", default: false, scope: .appGroup, flags: [.extensions])
    /// Keep incoming self-destructing messages (timers, view-once) when the timer fires.
    public static let keepSelfDestructing = GGSetting<Bool>("antiDelete.keepSelfDestructing", default: false, scope: .appGroup, flags: [.extensions])
    /// Apply all of the above to secret chats as well.
    public static let secretChats = GGSetting<Bool>("antiDelete.secretChats", default: false, scope: .appGroup, flags: [.extensions])
    /// Keep previous versions of edited messages.
    public static let editHistory = GGSetting<Bool>("antiDelete.editHistory", default: false, scope: .appGroup, flags: [.extensions])
    public static let excludeGroups = GGSetting<Bool>("antiDelete.excludeGroups", default: false, scope: .appGroup, flags: [.extensions])
    public static let excludeBots = GGSetting<Bool>("antiDelete.excludeBots", default: false, scope: .appGroup, flags: [.extensions])
    public static let excludeChannels = GGSetting<Bool>("antiDelete.excludeChannels", default: false, scope: .appGroup, flags: [.extensions])
    /// Excluded chats still keep previous versions of edited messages.
    public static let editsInExclusions = GGSetting<Bool>("antiDelete.editsInExclusions", default: false, scope: .appGroup, flags: [.extensions])

    /// Chats excluded by hand (the whole PeerId; a secret chat follows its user).
    public static let excludedPeers = GGAccountSetting<Set<GGPeerKey>>("antiDelete.excludedPeers", default: [], flags: [.extensions])
    /// Folders whose chats are excluded (folder ids of this account).
    public static let excludedFolders = GGAccountSetting<Set<Int32>>("antiDelete.excludedFolders", default: [])
    /// The chats of `excludedFolders`, kept up to date by the app while the account runs
    /// (folders change, chats move). Derived data: not exported, recomputed after a reset.
    public static let excludedFolderPeers = GGAccountSetting<Set<GGPeerKey>>("antiDelete.excludedFolderPeers", default: [], flags: [.extensions, .noExport])

    // MARK: App only

    /// Keep a copy of the media of deleted messages (not for secret chats).
    public static let keepMedia = GGSetting<Bool>("antiDelete.keepMedia", default: false)
    /// Transparency of deleted messages, percent 0…80.
    public static let transparency = GGSetting<Double>("antiDelete.transparency", default: 45.0)
    /// Previous versions are shown under the text (otherwise only in «История правок»).
    public static let editHistoryInline = GGSetting<Bool>("antiDelete.editHistoryInline", default: false)
    /// Transparency of the previous versions shown under the text, percent 0…80.
    public static let versionsTransparency = GGSetting<Double>("antiDelete.versionsTransparency", default: 45.0)
    /// «Изменить локально» in the message menu.
    public static let localEdit = GGSetting<Bool>("antiDelete.localEdit", default: false)
    /// `GGAntiDeleteRetention` raw value.
    public static let autoClear = GGSetting<String>("antiDelete.autoClear", default: GGAntiDeleteRetention.never.rawValue)

    /// The old client's archive was imported into this account.
    public static let legacyImportDone = GGAccountSetting<Bool>("antiDelete.legacyImportDone", default: false, flags: [.noExport])

    public static let transparencyRange: ClosedRange<Double> = 0.0 ... 80.0

    static func declare() {
        let _ = GGAntiDeleteSettings.enabled
        let _ = GGAntiDeleteSettings.keepOwn
        let _ = GGAntiDeleteSettings.keepSelfDestructing
        let _ = GGAntiDeleteSettings.secretChats
        let _ = GGAntiDeleteSettings.editHistory
        let _ = GGAntiDeleteSettings.excludeGroups
        let _ = GGAntiDeleteSettings.excludeBots
        let _ = GGAntiDeleteSettings.excludeChannels
        let _ = GGAntiDeleteSettings.editsInExclusions
        let _ = GGAntiDeleteSettings.excludedPeers
        let _ = GGAntiDeleteSettings.excludedFolders
        let _ = GGAntiDeleteSettings.excludedFolderPeers
        let _ = GGAntiDeleteSettings.keepMedia
        let _ = GGAntiDeleteSettings.transparency
        let _ = GGAntiDeleteSettings.editHistoryInline
        let _ = GGAntiDeleteSettings.versionsTransparency
        let _ = GGAntiDeleteSettings.localEdit
        let _ = GGAntiDeleteSettings.autoClear
        let _ = GGAntiDeleteSettings.legacyImportDone
        let _ = GGBookmarkSettings.enabled
    }

    /// Alpha of a deleted message from the transparency percent (clamped like the slider).
    public static func alpha(forTransparency value: Double) -> CGFloat {
        let clamped = min(GGAntiDeleteSettings.transparencyRange.upperBound, max(GGAntiDeleteSettings.transparencyRange.lowerBound, value))
        return CGFloat(1.0 - clamped / 100.0)
    }
}

public enum GGBookmarkSettings {
    /// «Закладка» in the message menu, the marker on the bubble and the row under the chat search.
    public static let enabled = GGSetting<Bool>("bookmarks.enabled", default: false)
}
