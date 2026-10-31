import Foundation
import GGCore
import GGFeaturesShared

/// The zone's buttons of «Кнопки быстрого доступа» in a chat (W2-5's `GGQuickActions`): ghost mode
/// and delayed sending of the account, as switches. The buttons themselves are drawn by GGInterface.
enum GGGhostQuickActions {
    static func register() {
        GGQuickActions.actions.register(GGQuickAction(
            id: GGQuickActionIds.ghostMode,
            order: 100,
            title: { GGStrings.GhostMode.Menu.group },
            iconName: "Chat/Context Menu/EyeLocked",
            isOn: { context in
                return GGGhostSettings.isEnabled.value(for: context.accountID)
            },
            perform: { context in
                let account = context.accountID
                GGGhostSettings.isEnabled.set(!GGGhostSettings.isEnabled.value(for: account), for: account)
            }
        ))
        GGQuickActions.actions.register(GGQuickAction(
            id: GGQuickActionIds.sendDelay,
            order: 400,
            title: { GGStrings.Menu.Tab.Privacy.sendDelay },
            iconName: "Chat/Context Menu/Schedule",
            isOn: { context in
                return GGGhostSettings.sendDelayEnabled.value(for: context.accountID)
            },
            perform: { context in
                let account = context.accountID
                GGGhostSettings.sendDelayEnabled.set(!GGGhostSettings.sendDelayEnabled.value(for: account), for: account)
            }
        ))
    }
}
