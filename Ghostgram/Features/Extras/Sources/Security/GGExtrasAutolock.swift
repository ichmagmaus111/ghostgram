import Foundation
import GGCore
import GGHooks
import GGFeaturesShared

/// «Через 5 секунд» in Telegram's auto-lock menu (GGPasscodeUIHooks, the points W3-4's extra values
/// use). The app lock renews its «last active» mark every 2.5 s while 5 s is the chosen timeout
/// (`GGExtrasPolicy.appLockActivityRenewInterval(autolockTimeout:)`), so a short leave is measured fairly.
enum GGExtrasAutolock {
    static let fiveSeconds: Int32 = 5

    static func register() {
        GGPasscodeUIHooks.autolockValues.register({ values in
            if !GGExtrasSettings.autolockFiveSeconds.value {
                return values
            }
            var result = values.filter { $0 != 0 }
            result.append(GGExtrasAutolock.fiveSeconds)
            return [0] + Set(result).sorted()
        }, order: -100)
        // Before W3-4's titles: they count whole minutes and would call 5 s «1 minute».
        GGPasscodeUIHooks.autolockTitle.register({ timeout in
            if timeout > 0 && timeout < 60 {
                return GGStrings.Extras.Autolock.seconds(count: Int(timeout))
            }
            return nil
        }, order: -100)
    }
}
