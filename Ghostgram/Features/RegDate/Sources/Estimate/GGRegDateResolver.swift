import Foundation

// What to show as the creation date of an account. Pure Foundation, no state: the anchors are
// immutable generated arrays (GGRegDateAnchors.swift), every call is a binary search plus a few
// multiplications, nothing is allocated. Times are unix seconds, UTC.
//
// Order of trust: Telegram's own registration month > a remote answer > the estimate by ID. The
// remote answer and the estimate are narrowed by what the device has seen (`existedAt` from above,
// `notBefore` from below); when that evidence contradicts the table, the evidence wins.

public enum GGRegDateResolver {
    /// Version of the built-in anchors and the model; bumped whenever either changes.
    public static let dataVersion: Int = GGRegDateAnchors.dataVersion

    /// The estimate by ID alone (anchors only), as of the device clock.
    public static func estimate(userId: Int64) -> GGRegDateResult? {
        return estimate(userId: userId, now: currentTime())
    }

    /// Everything known about the account combined: Telegram's month first, then the remote answer
    /// and the estimate, narrowed by the evidence. `now` bounds the range from above.
    public static func resolve(_ evidence: GGRegDateEvidence, now: Int32) -> GGRegDateResult? {
        let now = effectiveNow(now)
        if let month = evidence.telegramMonth, let range = telegramMonthRange(month, now: now) {
            return GGRegDateResult(
                range: GGRegDateRange(from: Int32(clamping: range.from), to: Int32(clamping: range.to)),
                point: Int32(clamping: range.from + (range.to - range.from) / 2),
                precision: .month,
                source: .telegram,
                isNarrowed: false,
                dataVersion: dataVersion
            )
        }
        if let remote = evidence.remote, let range = remoteRange(remote, now: now) {
            return narrowed(
                from: range.from, to: range.to, point: range.from + (range.to - range.from) / 2,
                source: .remote, evidence: evidence, now: now
            )
        }
        if let raw = rawEstimate(userId: evidence.userId, now: now) {
            return narrowed(
                from: raw.from, to: raw.to, point: raw.point,
                source: .estimate, evidence: evidence, now: now
            )
        }
        return nil
    }

    // MARK: - Internal (host tests reach these directly)

    /// Widest range whose point is still shown as a month ("≈ март 2016", the range on tap). The
    /// range is a 90 % band, so half a year wide means the point is good to about three months
    /// at worst and three weeks typically (Data/validation.txt); wider ranges show a year.
    static let monthPrecisionMaxWidth: Int64 = 183 * 86400
    /// A range this narrow (only possible with evidence) is a day.
    static let dayPrecisionMaxWidth: Int64 = 2 * 86400

    static func estimate(userId: Int64, now: Int32) -> GGRegDateResult? {
        let now = effectiveNow(now)
        guard let raw = rawEstimate(userId: userId, now: now) else {
            return nil
        }
        return GGRegDateResult(
            range: GGRegDateRange(from: Int32(clamping: raw.from), to: Int32(clamping: raw.to)),
            point: Int32(clamping: raw.point),
            precision: precision(width: raw.to - raw.from),
            source: .estimate,
            isNarrowed: false,
            dataVersion: dataVersion
        )
    }

    static func precision(width: Int64) -> GGRegDatePrecision {
        if width <= dayPrecisionMaxWidth {
            return .day
        } else if width <= monthPrecisionMaxWidth {
            return .month
        } else {
            return .year
        }
    }

    /// Service accounts with fixed IDs outside the counter (TelegramCore: `isServiceUser` 777000 /
    /// 333000, Verification Codes 489000, call logs 4244000): their ID says nothing about a date.
    static func isReserved(_ userId: Int64) -> Bool {
        switch userId {
        case 777000, 333000, 489000, 4244000:
            return true
        default:
            return false
        }
    }

    /// "MM.YYYY" (also "M.YYYY", surrounding spaces ignored) -> that calendar month in UTC, cut at
    /// `now`. Anything else, a month before 2013 or one that has not begun yet -> nil.
    static func telegramMonthRange(_ text: String, now: Int64) -> (from: Int64, to: Int64)? {
        var month: Int64 = 0
        var year: Int64 = 0
        var monthDigits = 0
        var yearDigits = 0
        var seenDot = false
        var seenContent = false
        var trailingSpace = false
        for byte in text.utf8 {
            if byte == 0x20 {
                if seenContent {
                    trailingSpace = true
                }
                continue
            }
            if trailingSpace {
                return nil
            }
            seenContent = true
            if byte == 0x2E {
                if seenDot || monthDigits == 0 {
                    return nil
                }
                seenDot = true
            } else if byte >= 0x30 && byte <= 0x39 {
                let digit = Int64(byte - 0x30)
                if seenDot {
                    yearDigits += 1
                    if yearDigits > 4 {
                        return nil
                    }
                    year = year * 10 + digit
                } else {
                    monthDigits += 1
                    if monthDigits > 2 {
                        return nil
                    }
                    month = month * 10 + digit
                }
            } else {
                return nil
            }
        }
        guard seenDot, yearDigits == 4, month >= 1, month <= 12, year >= 2013 else {
            return nil
        }
        let from = monthStart(year: year, month: month)
        guard from <= now else {
            return nil
        }
        let next = month == 12 ? monthStart(year: year + 1, month: 1) : monthStart(year: year, month: month + 1)
        return (from, min(next - 1, now))
    }

    /// Seconds of the first moment of a calendar month, UTC (proleptic Gregorian, H. Hinnant's
    /// days-from-civil).
    static func monthStart(year: Int64, month: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return (era * 146097 + doe - 719468) * 86400
    }

    /// The device clock, but never before the newest anchor: a clock behind the data is wrong, and
    /// trusting it would put every range in the past.
    static func effectiveNow(_ now: Int32) -> Int64 {
        return max(Int64(now), GGRegDateAnchors.dataEnd)
    }

    static func currentTime() -> Int32 {
        return Int32(clamping: Int64(Date().timeIntervalSince1970))
    }

    /// The table alone: (point, from, to). nil for IDs that are not accounts on the counter.
    static func rawEstimate(userId: Int64, now: Int64) -> (point: Int64, from: Int64, to: Int64)? {
        guard userId > 0, !isReserved(userId) else {
            return nil
        }
        let ids = GGRegDateAnchors.ids
        let points = GGRegDateAnchors.points
        let lows = GGRegDateAnchors.lows
        let highs = GGRegDateAnchors.highs
        let count = ids.count
        guard count >= 2, points.count == count, lows.count == count, highs.count == count else {
            return nil
        }
        let last = count - 1
        if userId >= ids[last] {
            // Newer than every anchor: after the last one, no later than now. The point follows the
            // last year's ID growth; the low edge leaves the last node's low edge only as fast as
            // IDs could at most have grown, never passes the point and never makes the range
            // narrower than the last node's band, so the range only widens as time goes on.
            let lastPoint = Int64(points[last])
            let lastLow = Int64(lows[last])
            let band = Int64(highs[last]) - lastLow
            let offset = Double(userId - ids[last])
            let upper = max(lastPoint, now)
            let point = clamp(Double(lastPoint) + offset / GGRegDateAnchors.idsPerSecond, lower: lastPoint, upper: upper)
            let lowCap = min(point, max(upper - band, lastLow))
            let from = clamp(Double(lastLow) + offset / (GGRegDateAnchors.idsPerSecond * GGRegDateAnchors.maxRateFactor), lower: lastLow, upper: max(lastLow, lowCap))
            return (point, max(GGRegDateAnchors.launch, from), upper)
        }
        // First index with ids[i] > userId. The generator starts the table at ID 0, so i >= 1; the
        // guard only keeps a hand-broken table from indexing below zero.
        var low = 0
        var high = last
        while low < high {
            let mid = (low + high) / 2
            if ids[mid] <= userId {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let i = low
        if i == 0 {
            let to = min(Int64(highs[0]), now)
            let point = min(Int64(points[0]), to)
            return (point, max(GGRegDateAnchors.launch, min(Int64(lows[0]), point)), to)
        }
        let fraction = Double(userId - ids[i - 1]) / Double(ids[i] - ids[i - 1])
        var to = interpolate(highs[i - 1], highs[i], fraction)
        var point = interpolate(points[i - 1], points[i], fraction)
        var from = interpolate(lows[i - 1], lows[i], fraction)
        // Near the top of the table accounts made after the data still get IDs: once the data is
        // old, the high edge there moves on with the clock, fully at the newest ID and not at all
        // `frontSpan` below it.
        let distance = Double(ids[last] - userId)
        if distance < GGRegDateAnchors.frontSpan && now > GGRegDateAnchors.dataEnd {
            let shift = Double(now - GGRegDateAnchors.dataEnd) * (1.0 - distance / GGRegDateAnchors.frontSpan)
            to += Int64(shift.rounded())
        }
        to = min(to, now)
        point = min(point, to)
        from = max(GGRegDateAnchors.launch, min(from, point))
        return (point, from, to)
    }

    static func interpolate(_ a: Int32, _ b: Int32, _ fraction: Double) -> Int64 {
        let value = Double(a) + (Double(b) - Double(a)) * fraction
        return Int64(value.rounded())
    }

    static func clamp(_ value: Double, lower: Int64, upper: Int64) -> Int64 {
        if !(value > Double(lower)) {
            return lower
        }
        if value >= Double(upper) {
            return upper
        }
        return Int64(value.rounded())
    }

    /// A remote answer as Swiftgram's contract gives it, made sane: before Telegram it is cut at
    /// the launch, after `now` it is cut at `now`; reversed or entirely outside -> nil.
    static func remoteRange(_ remote: GGRegDateRange, now: Int64) -> (from: Int64, to: Int64)? {
        let from = max(Int64(remote.from), GGRegDateAnchors.launch)
        let to = min(Int64(remote.to), now)
        guard remote.from <= remote.to, from <= to else {
            return nil
        }
        return (from, to)
    }

    /// Applies `existedAt` (upper bound) and `notBefore` (lower bound). Evidence that contradicts
    /// the range moves the range to the evidence; evidence that contradicts itself keeps the
    /// observed existence and drops the lower bound; evidence in the future or before Telegram is
    /// ignored.
    static func narrowed(from: Int64, to: Int64, point: Int64, source: GGRegDateSource, evidence: GGRegDateEvidence, now: Int64) -> GGRegDateResult {
        let launch = GGRegDateAnchors.launch
        var upper: Int64?
        if let existedAt = evidence.existedAt, Int64(existedAt) >= launch, Int64(existedAt) <= now {
            upper = Int64(existedAt)
        }
        var lower: Int64?
        if let notBefore = evidence.notBefore, Int64(notBefore) > launch, Int64(notBefore) <= now {
            lower = Int64(notBefore)
        }
        if let upperValue = upper, let lowerValue = lower, lowerValue > upperValue {
            lower = nil
        }

        let width = to - from
        var newFrom = from
        var newTo = to
        var newPoint = point
        if let upperValue = upper, upperValue < newTo {
            if upperValue >= newFrom {
                newTo = upperValue
            } else {
                // The account existed before the table says it could: believe the evidence.
                newTo = upperValue
                newFrom = max(launch, upperValue - width)
                newPoint = upperValue
            }
        }
        if let lowerValue = lower, lowerValue > newFrom {
            if lowerValue <= newTo {
                newFrom = lowerValue
            } else {
                // The account cannot be as old as the table says: believe the evidence.
                newFrom = lowerValue
                newTo = min(now, upper ?? now, lowerValue + width)
                newPoint = lowerValue
            }
        }
        if newPoint < newFrom {
            newPoint = newFrom
        } else if newPoint > newTo {
            newPoint = newTo
        }
        let isNarrowed = newFrom != from || newTo != to
        return GGRegDateResult(
            range: GGRegDateRange(from: Int32(clamping: newFrom), to: Int32(clamping: newTo)),
            point: Int32(clamping: newPoint),
            precision: precision(width: newTo - newFrom),
            source: source,
            isNarrowed: isNarrowed,
            dataVersion: dataVersion
        )
    }
}
