import Foundation
import XCTest

// Host tests of the feature's plain logic (W7-RD2): the stored evidence and its trimming, the old
// client's cache, Swiftgram's remote contract, how evidence reaches the resolver, and the display
// rules. Compiled with Sources/Model, Sources/Estimate, Sources/Store,
// Sources/Format/GGRegDateDisplay.swift and Sources/Remote/GGRegDateRemoteResponse.swift (Foundation
// only). Bazel: //Ghostgram/Features/RegDate:GGRegDateTests. Without Bazel (macOS host):
//   xcrun swiftc -emit-library -Xlinker -bundle -module-name GGRegDateTests \
//     -F "$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks" \
//     -Xlinker -rpath -Xlinker "$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks" \
//     Sources/Model/*.swift Sources/Estimate/*.swift Sources/Store/*.swift \
//     Sources/Format/GGRegDateDisplay.swift Sources/Remote/GGRegDateRemoteResponse.swift \
//     Tests/*.swift Tests/Feature/*.swift -o /tmp/GGRegDateTests.xctest
//   xcrun xctest /tmp/GGRegDateTests.xctest

final class GGRegDateFeatureTests: XCTestCase {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Int32 {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        let date = GGRegDateLayout.calendar().date(from: components) ?? Date(timeIntervalSince1970: 0)
        return Int32(date.timeIntervalSince1970)
    }

    private func result(_ from: Int32, _ to: Int32, point: Int32? = nil, precision: GGRegDatePrecision, source: GGRegDateSource = .estimate) -> GGRegDateResult {
        return GGRegDateResult(range: GGRegDateRange(from: from, to: to), point: point ?? (from / 2 + to / 2), precision: precision, source: source, isNarrowed: false, dataVersion: 0)
    }

    // MARK: Stored evidence

    func testStoredEntryKeepsEarliestTrace() {
        let now = self.utc(2026, 11, 1)
        var entry = GGRegDateStoredEntry()
        XCTAssertTrue(entry.isEmpty)
        XCTAssertTrue(entry.noteExistedAt(self.utc(2020, 5, 1), trace: .privateChat, now: now))
        XCTAssertFalse(entry.noteExistedAt(self.utc(2021, 1, 1), trace: .profilePhoto, now: now), "a later trace is no news")
        XCTAssertTrue(entry.noteExistedAt(self.utc(2019, 1, 1), trace: .profilePhoto, now: now))
        XCTAssertEqual(entry.existedAt, self.utc(2019, 1, 1))
        XCTAssertEqual(entry.trace, .profilePhoto)
        XCTAssertFalse(entry.noteExistedAt(0, trace: .nameChange, now: now), "no date is no evidence")
        XCTAssertFalse(entry.noteExistedAt(now + 60, trace: .nameChange, now: now), "the future is no evidence")
        XCTAssertEqual(entry.updated, now)
        XCTAssertFalse(entry.isEmpty)
    }

    func testStoredEntryMonthAndChecks() {
        let now = self.utc(2026, 11, 1)
        var entry = GGRegDateStoredEntry()
        XCTAssertTrue(entry.noteMonth(" 03.2016 ", now: now))
        XCTAssertEqual(entry.month, "03.2016")
        XCTAssertFalse(entry.noteMonth("03.2016", now: now))
        XCTAssertFalse(entry.noteMonth("  ", now: now))
        XCTAssertFalse(entry.hasChecked(.sessions))
        XCTAssertTrue(entry.noteChecked(.sessions, now: now))
        XCTAssertFalse(entry.noteChecked(.sessions, now: now))
        XCTAssertTrue(entry.hasChecked(.sessions))
    }

    func testStoredEntryCoding() throws {
        let entry = GGRegDateStoredEntry(month: "11.2015", existedAt: 1_500_000_000, trace: .joinedTelegram, checks: 1, updated: 1_700_000_000)
        let data = try JSONEncoder().encode(entry)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"m\"") && text.contains("\"e\"") && text.contains("\"t\":3"), text)
        XCTAssertEqual(try JSONDecoder().decode(GGRegDateStoredEntry.self, from: data), entry)

        // A trace from a newer build and missing fields do not lose the entry.
        let future = Data("{\"m\":\"01.2014\",\"e\":1400000000,\"t\":999}".utf8)
        let decoded = try JSONDecoder().decode(GGRegDateStoredEntry.self, from: future)
        XCTAssertEqual(decoded.month, "01.2014")
        XCTAssertEqual(decoded.existedAt, 1_400_000_000)
        XCTAssertNil(decoded.trace)
        XCTAssertEqual(decoded.checks, 0)
        XCTAssertEqual(decoded.updated, 0)
    }

    func testTrimmedEvidenceKeepsMonthsThenNewest() {
        var entries: [String: GGRegDateStoredEntry] = [:]
        for index in 0 ..< 10 {
            entries["0:\(index)"] = GGRegDateStoredEntry(month: index == 0 ? "01.2014" : nil, existedAt: 1_500_000_000, trace: .privateChat, updated: Int32(1_700_000_000 + index))
        }
        let trimmed = GGRegDateStore.trimmedEvidence(entries, limit: 4)
        XCTAssertEqual(trimmed.count, 4)
        XCTAssertNotNil(trimmed["0:0"], "a Telegram month outlives newer guesses")
        XCTAssertNotNil(trimmed["0:9"])
        XCTAssertNotNil(trimmed["0:8"])
        XCTAssertNotNil(trimmed["0:7"])
        XCTAssertEqual(GGRegDateStore.trimmedEvidence(entries, limit: 20), entries)
    }

    func testTrimmedRemoteKeepsCurrentFirst() {
        let now: Int32 = 1_800_000_000
        let entries: [String: GGRegDateRemoteEntry] = [
            "0:1": GGRegDateRemoteEntry(from: 1, to: 2, validUntil: now - 10, fetched: 1_790_000_000),
            "0:2": GGRegDateRemoteEntry(from: 1, to: 2, validUntil: 0, fetched: 0),
            "0:3": GGRegDateRemoteEntry(from: 1, to: 2, validUntil: now + 10, fetched: 1_700_000_000)
        ]
        let trimmed = GGRegDateStore.trimmedRemote(entries, now: now, limit: 2)
        XCTAssertEqual(Set(trimmed.keys), ["0:2", "0:3"])
        XCTAssertTrue(entries["0:2"]!.isFresh(now: now))
        XCTAssertFalse(entries["0:1"]!.isFresh(now: now))
    }

    // MARK: The old client's cache

    func testLegacyRemoteAnswers() {
        // Swiftgram's RegDate encoded with the default JSONEncoder: camelCase, Int64.
        let first = Data("{\"from\":1450000000,\"to\":1460000000,\"validUntil\":1800000000}".utf8)
        let forever = Data("{\"from\":1400000000,\"to\":1400100000,\"validUntil\":0}".utf8)
        let reversed = Data("{\"from\":1460000000,\"to\":1450000000,\"validUntil\":0}".utf8)
        let object: [String: Any] = [
            "123": first,
            "456": forever,
            "789": reversed,
            "abc": first,
            "-5": first,
            "999": ["from": 1300000000, "to": 1300500000, "validUntil": 5] as [String: Any],
            "1000": Data("not json".utf8)
        ]
        let answers = GGRegDateStore.legacyRemoteAnswers(object)
        XCTAssertEqual(answers.map { $0.userId }, [123, 456, 999])
        XCTAssertEqual(answers[0].entry, GGRegDateRemoteEntry(from: 1_450_000_000, to: 1_460_000_000, validUntil: 1_800_000_000, fetched: 0))
        XCTAssertEqual(answers[1].entry.validUntil, 0)
        XCTAssertEqual(answers[2].entry.from, 1_300_000_000)
        XCTAssertTrue(GGRegDateStore.legacyRemoteAnswers(nil).isEmpty)
        XCTAssertTrue(GGRegDateStore.legacyRemoteAnswers("text").isEmpty)
    }

    // MARK: Remote contract

    func testRemoteURL() {
        let base = URL(string: "https://example.org/api")!
        XCTAssertEqual(GGRegDateRemoteResponse.url(base: base, userId: 42).absoluteString, "https://example.org/api/v0/regdate/42")
        let slash = URL(string: "https://example.org/api/")!
        XCTAssertEqual(GGRegDateRemoteResponse.url(base: slash, userId: 42).absoluteString, "https://example.org/api/v0/regdate/42")
    }

    func testRemoteParse() {
        let now: Int32 = 1_800_000_000
        let answer = GGRegDateRemoteResponse.parse(Data("{\"from\":1450000000,\"to\":1460000000,\"valid_until\":1810000000}".utf8), now: now, fetched: now)
        XCTAssertEqual(answer, GGRegDateRemoteEntry(from: 1_450_000_000, to: 1_460_000_000, validUntil: 1_810_000_000, fetched: now))
        XCTAssertEqual(GGRegDateRemoteResponse.parse(Data("{\"from\":1790000000,\"to\":1900000000}".utf8), now: now, fetched: now)?.to, now, "no later than now")
        XCTAssertEqual(GGRegDateRemoteResponse.parse(Data("{\"from\":1790000000,\"to\":1790000001}".utf8), now: now, fetched: now)?.validUntil, 0)
        XCTAssertNil(GGRegDateRemoteResponse.parse(Data("{\"from\":1460000000,\"to\":1450000000}".utf8), now: now, fetched: now))
        XCTAssertNil(GGRegDateRemoteResponse.parse(Data("{\"to\":1450000000}".utf8), now: now, fetched: now))
        XCTAssertNil(GGRegDateRemoteResponse.parse(Data("[1, 2]".utf8), now: now, fetched: now))
        XCTAssertNil(GGRegDateRemoteResponse.parse(Data("<html>".utf8), now: now, fetched: now))
    }

    func testCredentialsAreEmptyWithoutTokens() {
        XCTAssertTrue(GGRegDateAPICredentials.none.headers.isEmpty)
        let credentials = GGRegDateAPICredentials(authorization: "abc", deviceToken: "dev")
        XCTAssertEqual(credentials.headers, ["Authorization": "Token abc", "Device-Token": "dev"])
    }

    // MARK: Evidence → resolver

    func testSnapshotUsesStoredEvidence() {
        let now = Int32(GGRegDateAnchors.dataEnd)
        guard let plain = GGRegDateStore.snapshot(userId: 150_000_000, stored: GGRegDateStoredEntry(), remote: nil, now: now) else {
            return XCTFail("the estimate answers for an ordinary ID")
        }
        XCTAssertEqual(plain.result.source, .estimate)
        XCTAssertNil(plain.existedAt)

        let month = GGRegDateStore.snapshot(userId: 150_000_000, stored: GGRegDateStoredEntry(month: "03.2016"), remote: nil, now: now)
        XCTAssertEqual(month?.result.source, .telegram)
        XCTAssertEqual(month.map { GGRegDateLayout.display($0.result) }, .month(year: 2016, month: 3, approximate: false))

        let traceTime = plain.result.range.from / 2 + plain.result.range.to / 2
        let traced = GGRegDateStore.snapshot(userId: 150_000_000, stored: GGRegDateStoredEntry(existedAt: traceTime, trace: .profilePhoto), remote: nil, now: now)
        XCTAssertEqual(traced?.existedAt, traceTime)
        XCTAssertEqual(traced?.existedAtTrace, .profilePhoto)
        XCTAssertLessThanOrEqual(traced?.result.range.to ?? Int32.max, traceTime)
    }

    func testSnapshotRemoteFreshAndExpired() {
        let now = Int32(GGRegDateAnchors.dataEnd)
        let from = self.utc(2016, 3, 1, 0)
        let to = self.utc(2016, 3, 20, 0)
        let fresh = GGRegDateRemoteEntry(from: from, to: to, validUntil: now + 3600, fetched: now)
        let current = GGRegDateStore.snapshot(userId: 150_000_000, stored: GGRegDateStoredEntry(), remote: fresh, now: now)
        XCTAssertEqual(current?.result.source, .remote)
        XCTAssertNil(current?.notBefore)

        var expired = fresh
        expired.validUntil = now - 3600
        let stale = GGRegDateStore.snapshot(userId: 150_000_000, stored: GGRegDateStoredEntry(), remote: expired, now: now)
        XCTAssertNotEqual(stale?.result.source, .remote, "an expired answer is not shown as the server's")
        XCTAssertEqual(stale?.notBefore, from)
        XCTAssertEqual(stale?.notBeforeTrace, .expiredRemote)
        XCTAssertEqual(stale?.existedAt, to)
        XCTAssertEqual(stale?.existedAtTrace, .expiredRemote)

        // An earlier trace of the device stays the «existed at» bound.
        let earlier = GGRegDateStore.snapshot(userId: 150_000_000, stored: GGRegDateStoredEntry(existedAt: from + 60, trace: .privateChat), remote: expired, now: now)
        XCTAssertEqual(earlier?.existedAt, from + 60)
        XCTAssertEqual(earlier?.existedAtTrace, .privateChat)
    }

    // MARK: Display

    func testDisplayTelegramMonthIsPlain() {
        let display = GGRegDateLayout.display(self.result(self.utc(2016, 3, 1, 0), self.utc(2016, 3, 31, 23), precision: .month, source: .telegram))
        XCTAssertEqual(display, .month(year: 2016, month: 3, approximate: false))
    }

    func testDisplayByPrecision() {
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2016, 3, 2), self.utc(2016, 3, 28), precision: .month)), .month(year: 2016, month: 3, approximate: true))
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2016, 3, 2), self.utc(2016, 6, 28), precision: .month)), .monthRange(fromYear: 2016, fromMonth: 3, toYear: 2016, toMonth: 6))
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2015, 11, 2), self.utc(2016, 2, 28), precision: .month)), .monthRange(fromYear: 2015, fromMonth: 11, toYear: 2016, toMonth: 2))
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2015, 1, 2), self.utc(2016, 2, 28), precision: .month)), .yearRange(from: 2015, to: 2016), "a year and more reads in years")
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2016, 1, 2), self.utc(2016, 11, 28), precision: .year)), .year(2016, approximate: true))
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2015, 6, 2), self.utc(2017, 2, 28), precision: .year)), .yearRange(from: 2015, to: 2017))
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2016, 3, 5, 1), self.utc(2016, 3, 5, 20), precision: .day)), .day(timestamp: self.utc(2016, 3, 5, 1), approximate: true))
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2016, 3, 5, 20), self.utc(2016, 3, 6, 10), precision: .day)), .month(year: 2016, month: 3, approximate: true), "a day only when the range is one day")
        // A reversed range (never from the resolver) still reads in order.
        XCTAssertEqual(GGRegDateLayout.display(self.result(self.utc(2016, 6, 28), self.utc(2016, 3, 2), precision: .month)), .monthRange(fromYear: 2016, fromMonth: 3, toYear: 2016, toMonth: 6))
    }

    func testAge() {
        let now = self.utc(2026, 11, 1)
        let monthResult = self.result(self.utc(2018, 3, 1), self.utc(2018, 3, 31), point: self.utc(2018, 3, 15), precision: .month, source: .telegram)
        XCTAssertEqual(GGRegDateLayout.age(monthResult, now: now), GGRegDateAge(years: 8, months: 7, yearsOnly: false, approximate: false))

        let yearResult = self.result(self.utc(2017, 1, 1), self.utc(2018, 12, 1), point: self.utc(2018, 3, 15), precision: .year)
        XCTAssertEqual(GGRegDateLayout.age(yearResult, now: now), GGRegDateAge(years: 8, months: 0, yearsOnly: true, approximate: true))

        let fresh = self.result(self.utc(2026, 10, 20), self.utc(2026, 10, 30), point: self.utc(2026, 10, 25), precision: .month)
        XCTAssertEqual(GGRegDateLayout.age(fresh, now: now), GGRegDateAge(years: 0, months: 0, yearsOnly: false, approximate: true))

        let recentYear = self.result(self.utc(2026, 1, 1), self.utc(2026, 10, 1), point: self.utc(2026, 4, 15), precision: .year)
        XCTAssertEqual(GGRegDateLayout.age(recentYear, now: now), GGRegDateAge(years: 0, months: 6, yearsOnly: false, approximate: true), "under a year the months are all there is")

        let future = self.result(self.utc(2026, 10, 20), self.utc(2026, 12, 1), point: self.utc(2026, 12, 1), precision: .month)
        XCTAssertEqual(GGRegDateLayout.age(future, now: now).years, 0)
    }

    func testEveryTraceHasARawValueOfItsOwn() {
        let raws = GGRegDateTrace.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(raws).count, raws.count)
    }
}
