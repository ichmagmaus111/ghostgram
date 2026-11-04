import Foundation

// How a result reads in the profile, decided from `precision` and `source` only (plain Foundation,
// host-tested). Texts are made in GGRegDateText. Calendar fields are UTC, like the contract.

enum GGRegDateDisplay: Equatable {
    /// «март 2016»; `approximate` adds «≈».
    case month(year: Int, month: Int, approximate: Bool)
    /// «12 мар. 2016 г.» — only when the range is one day.
    case day(timestamp: Int32, approximate: Bool)
    /// «≈ 2016».
    case year(Int, approximate: Bool)
    /// «март 2016 — июнь 2016»: a range already reads as approximate.
    case monthRange(fromYear: Int, fromMonth: Int, toYear: Int, toMonth: Int)
    /// «2015 — 2017».
    case yearRange(from: Int, to: Int)
}

/// The account's age next to the date («8 лет 7 мес.»).
struct GGRegDateAge: Equatable {
    var years: Int
    /// 0…11.
    var months: Int
    /// The date is only known to the year: months would pretend to a precision there is none of.
    var yearsOnly: Bool
    var approximate: Bool
}

enum GGRegDateLayout {
    /// A range spanning this many months or more is shown in years even at month precision.
    static let monthRangeLimit = 12

    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }

    struct Fields: Equatable {
        var year: Int
        var month: Int
        var day: Int

        /// Months since year 0, for spans.
        var monthIndex: Int {
            return self.year * 12 + (self.month - 1)
        }
    }

    static func fields(_ timestamp: Int32, calendar: Calendar) -> Fields {
        let components = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(timestamp)))
        return Fields(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    static func display(_ result: GGRegDateResult) -> GGRegDateDisplay {
        let calendar = GGRegDateLayout.calendar()
        let lower = min(result.range.from, result.range.to)
        let upper = max(result.range.from, result.range.to)
        let from = GGRegDateLayout.fields(lower, calendar: calendar)
        let to = GGRegDateLayout.fields(upper, calendar: calendar)

        // Telegram's own month is not a guess: shown plainly.
        if result.source == .telegram {
            return .month(year: from.year, month: from.month, approximate: false)
        }
        let monthSpan = to.monthIndex - from.monthIndex
        switch result.precision {
        case .day:
            if from == to {
                return .day(timestamp: lower, approximate: true)
            }
            fallthrough
        case .month:
            if monthSpan == 0 {
                return .month(year: from.year, month: from.month, approximate: true)
            }
            if monthSpan < GGRegDateLayout.monthRangeLimit {
                return .monthRange(fromYear: from.year, fromMonth: from.month, toYear: to.year, toMonth: to.month)
            }
            return GGRegDateLayout.years(from: from.year, to: to.year)
        case .year:
            return GGRegDateLayout.years(from: from.year, to: to.year)
        }
    }

    private static func years(from: Int, to: Int) -> GGRegDateDisplay {
        if from == to {
            return .year(from, approximate: true)
        }
        return .yearRange(from: from, to: to)
    }

    /// Full years and months from the result's point to `now` (years 0, months 0 = less than a month).
    static func age(_ result: GGRegDateResult, now: Int32) -> GGRegDateAge {
        let calendar = GGRegDateLayout.calendar()
        let start = Date(timeIntervalSince1970: Double(min(result.point, now)))
        let end = Date(timeIntervalSince1970: Double(now))
        let components = calendar.dateComponents([.year, .month], from: start, to: end)
        let years = max(0, components.year ?? 0)
        let months = min(11, max(0, components.month ?? 0))
        let isTelegram = result.source == .telegram
        let yearsOnly = !isTelegram && result.precision == .year && years > 0
        return GGRegDateAge(years: years, months: yearsOnly ? 0 : months, yearsOnly: yearsOnly, approximate: !isTelegram)
    }
}
