import Foundation
import TelegramPresentationData
import TelegramStringFormatting
import GGCore

/// The texts of the row and of its explanation. Month names and dates are Telegram's own formatting
/// (`stringForMonth(strings:month:ofYear:)` is what the new-chat info card shows the registration
/// month with), so they follow Telegram's language like the rest of the profile; the rest is
/// Ghostgram's strings. Built at display time only.
struct GGRegDateRowTexts: Equatable {
    /// «≈ март 2016».
    let value: String
    /// «8 лет 7 мес.» on the right of the label.
    let age: String
    /// What a long press copies: «≈ март 2016 · 8 лет 7 мес.».
    let copy: String
}

enum GGRegDateText {
    static func row(_ snapshot: GGRegDateSnapshot, now: Int32, strings: PresentationStrings) -> GGRegDateRowTexts {
        let value = GGRegDateText.value(GGRegDateLayout.display(snapshot.result), strings: strings)
        let age = GGRegDateText.age(GGRegDateLayout.age(snapshot.result, now: now))
        return GGRegDateRowTexts(value: value, age: age, copy: "\(value) · \(age)")
    }

    static func value(_ display: GGRegDateDisplay, strings: PresentationStrings) -> String {
        switch display {
        case let .month(year, month, approximate):
            let text = GGRegDateText.month(year: year, month: month, strings: strings)
            return approximate ? GGStrings.RegDate.Profile.approximate(date: text) : text
        case let .day(timestamp, approximate):
            let text = stringForDate(timestamp: timestamp, strings: strings)
            return approximate ? GGStrings.RegDate.Profile.approximate(date: text) : text
        case let .year(year, approximate):
            let text = "\(year)"
            return approximate ? GGStrings.RegDate.Profile.approximate(date: text) : text
        case let .monthRange(fromYear, fromMonth, toYear, toMonth):
            return GGStrings.RegDate.Profile.range(from: GGRegDateText.month(year: fromYear, month: fromMonth, strings: strings), to: GGRegDateText.month(year: toYear, month: toMonth, strings: strings))
        case let .yearRange(from, to):
            return GGStrings.RegDate.Profile.range(from: "\(from)", to: "\(to)")
        }
    }

    /// «март 2016» — the upstream formatter (month 0…11, year since 1900).
    static func month(year: Int, month: Int, strings: PresentationStrings) -> String {
        return stringForMonth(strings: strings, month: Int32(max(1, min(12, month)) - 1), ofYear: Int32(year - 1900))
    }

    static func age(_ age: GGRegDateAge) -> String {
        let text: String
        if age.years == 0 && age.months == 0 {
            text = GGStrings.RegDate.Age.lessThanMonth
        } else if age.years > 0 && age.months > 0 && !age.yearsOnly {
            text = GGStrings.RegDate.Age.yearsMonths(years: GGStrings.RegDate.Age.years(count: age.years), months: GGStrings.RegDate.Age.months(count: age.months))
        } else if age.years > 0 {
            text = GGStrings.RegDate.Age.years(count: age.years)
        } else {
            text = GGStrings.RegDate.Age.months(count: age.months)
        }
        return age.approximate ? GGStrings.RegDate.Age.approximate(age: text) : text
    }
}
