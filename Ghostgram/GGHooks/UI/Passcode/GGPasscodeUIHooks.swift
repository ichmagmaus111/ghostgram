// Telegram's own passcode screen (SettingsUI `PasscodeOptionsScreen`): extra auto-lock values in its
// menu. The menu writes the chosen value once, on selection (no slider, no write per tick).

import Foundation
import GGCore

public enum GGPasscodeUIHooks {
    /// Transformer of the auto-lock menu's values in seconds (0 = «Disabled»), in display order.
    /// Values must stay unique; 0 must stay first. Main thread.
    public static let autolockValues = GGHookPoint<([Int32]) -> [Int32]>("passcode.autolockValues")

    /// Provider: the title of a value Telegram has no string for (first non-nil wins). Main thread.
    public static let autolockTitle = GGHookPoint<(Int32) -> String?>("passcode.autolockTitle")

    /// The menu's values; `values` unchanged while the point is empty (upstream).
    public static func transformAutolockValues(_ values: [Int32]) -> [Int32] {
        if GGPasscodeUIHooks.autolockValues.isEmpty {
            return values
        }
        var result = values
        for handler in GGPasscodeUIHooks.autolockValues.handlers {
            result = handler(result)
        }
        var seen = Set<Int32>()
        result = result.filter { seen.insert($0).inserted }
        if !result.contains(0) {
            result.insert(0, at: 0)
        }
        return result
    }

    /// A title for a value upstream does not name; nil while the point is empty.
    public static func title(forAutolockTimeout timeout: Int32) -> String? {
        for handler in GGPasscodeUIHooks.autolockTitle.handlers {
            if let value = handler(timeout) {
                return value
            }
        }
        return nil
    }
}
