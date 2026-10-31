import Foundation
import GGCore
import GGFeaturesShared

/// Keys of the old client (its Swiftgram layer) that map to GGExtras settings. Runs once.
enum GGExtrasMigrations {
    static func register() {
        GGMigrations.registerGlobal(id: "extras.v1") { legacy in
            // «В историю» in the share sheet: on by default there, our switch hides it.
            if let value = legacy.bool("showRepostToStoryV2") {
                if !value {
                    GGExtrasSettings.hideRepostToStory.set(true)
                }
                legacy.removeLegacyKey("showRepostToStoryV2")
            }
            legacy.removeLegacyKey("showRepostToStory")
            // A hidden key of the old client (no switch): the system share sheet everywhere.
            if let value = legacy.bool("forceSystemSharing") {
                if value {
                    GGExtrasSettings.systemShareSheet.set(true)
                }
                legacy.removeLegacyKey("forceSystemSharing")
            }
        }
        // «Скрыть поиск в таббаре» removed (owner, 2026-10-28): nothing in this Telegram puts the
        // search button next to the tab bar, the switch did nothing. Its stored value goes too.
        GGMigrations.registerGlobal(id: "extras.hideTabBarSearch.removed.v1") { _ in
            GGRetiredSettings.remove(keys: ["extras.hideTabBarSearch"])
        }
        // «Данные сообщения (JSON)» in the message menu removed (owner, 2026-10-29).
        GGMigrations.registerGlobal(id: "extras.messageJson.removed.v1") { legacy in
            GGRetiredSettings.remove(keys: ["extras.messageJson"])
            legacy.removeLegacyKey("contextShowJson")
        }
    }
}
