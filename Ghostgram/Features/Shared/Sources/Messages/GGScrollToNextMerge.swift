import Foundation

/// «Без перехода к следующему каналу и теме» is one switch since 2026-10-27; builds ≤ 185 and the old
/// client had one for channels and one for forum topics. Foundation only: host-tested.
public enum GGScrollToNextMerge {
    /// On when either old switch was on; nil when neither was ever stored (keep the default).
    public static func merged(channel: Bool?, topic: Bool?) -> Bool? {
        if channel == nil && topic == nil {
            return nil
        }
        return channel == true || topic == true
    }
}
