import Foundation

/// «Автоочистка»: entries older than this are removed (with the kept messages themselves).
/// The old client wiped everything every N hours from a timer that died on restart; this is an
/// age limit, checked per account when the app returns to the foreground.
public enum GGAntiDeleteRetention: String, CaseIterable {
    case never
    case day
    case week
    case month
    case quarter
    case year

    public init(settingValue: String) {
        self = GGAntiDeleteRetention(rawValue: settingValue) ?? .never
    }

    /// Maximum age in seconds; nil keeps everything.
    public var maximumAge: Int32? {
        switch self {
        case .never:
            return nil
        case .day:
            return 24 * 60 * 60
        case .week:
            return 7 * 24 * 60 * 60
        case .month:
            return 30 * 24 * 60 * 60
        case .quarter:
            return 91 * 24 * 60 * 60
        case .year:
            return 365 * 24 * 60 * 60
        }
    }

    /// Entries with a time before this are removed; nil = nothing to remove.
    public func cutoff(now: Int32) -> Int32? {
        guard let maximumAge = self.maximumAge else {
            return nil
        }
        return now - maximumAge
    }

    /// The old `antiDelete.autoClearInterval` (hours, 0 = never: 1, 6, 12, 24, 48, 168).
    public static func fromLegacyHours(_ hours: Int) -> GGAntiDeleteRetention {
        if hours <= 0 {
            return .never
        } else if hours <= 24 {
            return .day
        } else if hours <= 7 * 24 {
            return .week
        } else if hours <= 30 * 24 {
            return .month
        } else if hours <= 91 * 24 {
            return .quarter
        } else {
            return .year
        }
    }
}
