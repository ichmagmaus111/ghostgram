import Foundation
import GGCore
import GGFeaturesShared

/// The old client's anti-delete settings (same bundle id). Only keys that exist are moved; the
/// toggles of the old client defaulted to «on», so an old user keeps what they had.
enum GGAntiDeleteMigrations {
    static func register() {
        GGMigrations.registerGlobal(id: "antiDelete.v1") { legacy in
            let anyOldKey = legacy.object("antiDelete.enabled") != nil
            if let value = legacy.bool("antiDelete.enabled") {
                GGAntiDeleteSettings.enabled.set(value)
            }
            if let value = legacy.bool("antiDelete.keepLocallyWhenDeletingForEveryone") {
                GGAntiDeleteSettings.keepOwn.set(value)
            }
            if let value = legacy.bool("antiDelete.preserveTTL") {
                GGAntiDeleteSettings.keepSelfDestructing.set(value)
            } else if anyOldKey {
                // The old getter answered «true» when the key was absent.
                GGAntiDeleteSettings.keepSelfDestructing.set(true)
            }
            // «Архивировать медиа» was a dead switch in the old client: it is not carried over, the
            // real «Сохранять медиа удалённых» starts off.
            if let value = legacy.double("antiDelete.deletedMessageTransparency") {
                GGAntiDeleteSettings.transparency.set(min(80.0, max(0.0, value * 100.0)))
            }
            if let value = legacy.double("antiDelete.localEditedMessageTransparency") {
                // Despite its name the old slider drove the previous versions under the text.
                GGAntiDeleteSettings.versionsTransparency.set(min(80.0, max(0.0, value * 100.0)))
            }
            if anyOldKey {
                // Old clients always captured edits; their display had two styles.
                let displayEdited = legacy.bool("antiDelete.displayEditedMessages") ?? true
                let classicStyle = legacy.bool("antiDelete.classicEditedStyle") ?? false
                GGAntiDeleteSettings.editHistory.set(displayEdited || classicStyle)
                GGAntiDeleteSettings.editHistoryInline.set(displayEdited && !classicStyle)
                GGAntiDeleteSettings.editsInExclusions.set(legacy.bool("antiDelete.exclusions.preserveEditedMessages") ?? true)
            }
            if legacy.bool("antiDelete.showDeletedInBots") == false {
                GGAntiDeleteSettings.excludeBots.set(true)
            }
            if legacy.bool("antiDelete.showDeletedInChannels") == false {
                GGAntiDeleteSettings.excludeChannels.set(true)
            }
            if let value = legacy.bool("antiDelete.exclusions.excludeAllGroups") {
                GGAntiDeleteSettings.excludeGroups.set(value)
            }
            // «Убранные / заменённые реакции» are gone (owner, 2026-10-27): their keys are only removed.
            // «Тегать автора» is gone: a reply to a deleted message is always AyuGram's pseudo-reply.
            if let hours = legacy.int("antiDelete.autoClearInterval") {
                GGAntiDeleteSettings.autoClear.set(GGAntiDeleteRetention.fromLegacyHours(hours).rawValue)
            }
            if let value = legacy.bool("GG.contextShowLocalEdit") {
                GGAntiDeleteSettings.localEdit.set(value)
            }
            if let value = legacy.bool("contextShowBookmark") {
                GGBookmarkSettings.enabled.set(value)
            }

            for key in [
                "antiDelete.enabled", "antiDelete.keepLocallyWhenDeletingForEveryone", "antiDelete.preserveTTL",
                "antiDelete.archiveMedia", "antiDelete.deletedMessageTransparency", "antiDelete.localEditedMessageTransparency",
                "antiDelete.displayEditedMessages", "antiDelete.classicEditedStyle", "antiDelete.showDeletedInBots",
                "antiDelete.showEditedInBots", "antiDelete.showDeletedInChannels", "antiDelete.showEditedInChannels",
                "antiDelete.exclusions.excludeAllGroups", "antiDelete.exclusions.preserveEditedMessages",
                "antiDelete.deletedReactions", "antiDelete.editedReactions", "antiDelete.mentionUsernameInDeletedReply",
                "antiDelete.autoClearInterval", "antiDelete.accessEverGranted", "antiDelete.captureActive.appgroup",
                "GG.contextShowLocalEdit", "contextShowBookmark"
            ] {
                legacy.removeLegacyKey(key)
            }

            // The UserDefaults blobs (edit history, the archive mirror) go to a stash file off the
            // main thread and are imported per account; the keys are removed only after the stash
            // is written, so a failure never loses them.
            let editHistory = legacy.data("ghostgram_edit_history")
            let archiveMirror = legacy.data("antiDelete.archive")
            GGAntiDeleteLegacyImport.stash(editHistory: editHistory, archiveMirror: archiveMirror, didStash: {
                legacy.removeLegacyKey("ghostgram_edit_history")
                legacy.removeLegacyKey("antiDelete.archive")
                legacy.removeLegacyKey("antiDelete.deletedIds")
            })
        }

        // Exclusions are account-scoped keys of the old profiles: with the profiles off every account
        // takes the shared chats (ids of chats another account does not have simply never match);
        // with them on the shared keys are the active account's and any other account takes its own
        // profile only (`legacyAccountValue`). Folders are not like chats: folder ids are an account's
        // own (2, 3, 4… in each), so the shared folder list (profiles off) is taken only when the
        // device has one account — with several it would exclude a random folder of the others.
        GGMigrations.registerAccount(id: "antiDelete.exclusions.v1") { legacy, account in
            let rawPeers = legacy.legacyAccountValue("antiDelete.exclusions.excludedPeerIds", for: account) as? [NSNumber]
            if let rawPeers, !rawPeers.isEmpty {
                let keys = Set(rawPeers.map { GGLegacyKeys.peerKey(fromLegacyInt64: $0.int64Value) })
                GGAntiDeleteSettings.excludedPeers.set(keys, for: account)
            }
            if legacy.legacyAccountProfilesEnabled || GGLegacyAccounts.isSingleAccount {
                let rawFolders = legacy.legacyAccountValue("antiDelete.exclusions.excludedFolderIds", for: account) as? [NSNumber]
                if let rawFolders, !rawFolders.isEmpty {
                    GGAntiDeleteSettings.excludedFolders.set(Set(rawFolders.map { $0.int32Value }), for: account)
                }
            }
        }
    }
}
