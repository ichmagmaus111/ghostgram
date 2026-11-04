import Foundation
import TelegramCore
import GGCore

/// The old client's keys (SGSimpleSettings, `UserDefaults.standard`):
/// - `showRegDate` (Bool, default true) → `regDate.show`;
/// - `regDateCache` (user id text → JSON of Swiftgram's `RegDate {from, to, validUntil}`): real
///   answers of Swiftgram's server, moved to `regDate.remote` as remote answers (expired ones too —
///   their bounds stay evidence, see `GGRegDate.resolve`).
enum GGRegDateMigration {
    static func register() {
        GGMigrations.registerGlobal(id: "regDate.v1") { legacy in
            if let value = legacy.bool("showRegDate") {
                GGRegDateSettings.show.set(value)
                legacy.removeLegacyKey("showRegDate")
            }
            let answers = GGRegDateStore.legacyRemoteAnswers(legacy.object("regDateCache"))
            if !answers.isEmpty {
                let userNamespace = Namespaces.Peer.CloudUser._internalGetInt32Value()
                var remote = GGRegDateSettings.remote.value
                for (userId, entry) in answers {
                    guard let key = GGPeerKey(namespace: userNamespace, id: userId)?.stringValue else {
                        continue
                    }
                    // An answer this build already has is newer than the old client's.
                    if remote[key] == nil {
                        remote[key] = entry
                    }
                }
                GGRegDateSettings.remote.set(GGRegDateStore.trimmedRemote(remote, now: Int32(clamping: Int(Date().timeIntervalSince1970))))
            }
            if legacy.object("regDateCache") != nil {
                legacy.removeLegacyKey("regDateCache")
            }
        }
    }
}
