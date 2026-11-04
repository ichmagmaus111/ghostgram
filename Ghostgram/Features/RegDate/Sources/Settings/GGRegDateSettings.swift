import Foundation
import GGCore

extension GGRegDateStoredEntry: GGSettingValue {}
extension GGRegDateRemoteEntry: GGSettingValue {}

/// Settings and caches of «Дата регистрации».
enum GGRegDateSettings {
    /// The row in profiles. On by default, like Swiftgram's `showRegDate` (owner's decision 2026-11-01).
    static let show = GGSetting<Bool>("regDate.show", default: true)

    /// What this account found on the device, by user (`GGPeerKey.stringValue`): Telegram's month and
    /// the earliest trace. Account scope: it was learned through this account's data and leaves with
    /// it. A cache — not exported; bounded by `GGRegDateStore.evidenceLimit`.
    static let evidence = GGAccountSetting<[String: GGRegDateStoredEntry]>("regDate.evidence", default: [:], flags: [.noExport])

    /// Answers of a remote service by user (`GGPeerKey.stringValue`), and the old client's
    /// `regDateCache`. Global: an answer depends on the ID only. Not exported; bounded by
    /// `GGRegDateStore.remoteLimit`.
    static let remote = GGSetting<[String: GGRegDateRemoteEntry]>("regDate.remote", default: [:], flags: [.noExport])

    static func declare() {
        let _ = GGRegDateSettings.show
        let _ = GGRegDateSettings.evidence
        let _ = GGRegDateSettings.remote
    }
}
