import Foundation

// What the device keeps about registration dates: the evidence an account found and the answers of a
// remote service. Plain Foundation (host-tested with the contract); GGCore conformances live in
// Settings/GGRegDateSettings.swift.

/// What gave an «existed at» (or «not before») bound; shown in the explanation.
enum GGRegDateTrace: Int, Codable, CaseIterable {
    /// The oldest photo of the profile (`photos.getUserPhotos` dates).
    case profilePhoto = 1
    /// The earliest message of the private chat stored on the device.
    case privateChat = 2
    /// The «… joined Telegram» service message of the private chat.
    case joinedTelegram = 3
    /// `peerSettings.name_change_date`.
    case nameChange = 4
    /// `peerSettings.photo_change_date`.
    case photoChange = 5
    /// Joined the basic group the profile was opened from.
    case groupJoin = 6
    /// Created the basic group the profile was opened from.
    case groupCreated = 7
    /// The message (in a group or channel) the profile was opened from.
    case chatMessage = 8
    /// Own account: the oldest active session.
    case session = 9
    /// Own account: the earliest message from Telegram (777000) on the device.
    case serviceMessages = 10
    /// Own account: the earliest message of Saved Messages on the device.
    case savedMessages = 11
    /// A remote answer past its `valid_until`: its bounds are kept as evidence.
    case expiredRemote = 12
}

/// One-time checks already done for a user, so a request is never repeated.
struct GGRegDateChecks: OptionSet {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Own account: the session list was read.
    static let sessions = GGRegDateChecks(rawValue: 1 << 0)
}

/// What one account found about one user. Stored by `regDate.evidence` (account scope).
struct GGRegDateStoredEntry: Codable, Equatable {
    /// `peerSettings.registration_month` exactly as Telegram sent it ("MM.YYYY"). Never expires.
    var month: String?
    /// The earliest moment the account certainly existed at (an upper bound of its creation).
    var existedAt: Int32?
    /// What gave `existedAt`.
    var trace: GGRegDateTrace?
    /// `GGRegDateChecks`.
    var checks: Int
    /// When anything above last changed (trimming order).
    var updated: Int32

    init(month: String? = nil, existedAt: Int32? = nil, trace: GGRegDateTrace? = nil, checks: Int = 0, updated: Int32 = 0) {
        self.month = month
        self.existedAt = existedAt
        self.trace = trace
        self.checks = checks
        self.updated = updated
    }

    private enum CodingKeys: String, CodingKey {
        case month = "m"
        case existedAt = "e"
        case trace = "t"
        case checks = "c"
        case updated = "u"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let month: String? = try? container.decodeIfPresent(String.self, forKey: .month)
        self.month = month
        let existedAt: Int32? = try? container.decodeIfPresent(Int32.self, forKey: .existedAt)
        self.existedAt = existedAt
        // An unknown trace (written by a newer build) reads as "unknown", not as a failed entry.
        let traceRaw: Int? = try? container.decodeIfPresent(Int.self, forKey: .trace)
        self.trace = traceRaw.flatMap(GGRegDateTrace.init(rawValue:))
        let checks: Int? = try? container.decodeIfPresent(Int.self, forKey: .checks)
        self.checks = checks ?? 0
        let updated: Int32? = try? container.decodeIfPresent(Int32.self, forKey: .updated)
        self.updated = updated ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.month, forKey: .month)
        try container.encodeIfPresent(self.existedAt, forKey: .existedAt)
        try container.encodeIfPresent(self.trace?.rawValue, forKey: .trace)
        if self.checks != 0 {
            try container.encode(self.checks, forKey: .checks)
        }
        try container.encode(self.updated, forKey: .updated)
    }

    var isEmpty: Bool {
        return self.month == nil && self.existedAt == nil && self.checks == 0
    }

    /// Telegram's month; true when it changed. Kept as sent: the resolver parses it.
    mutating func noteMonth(_ month: String, now: Int32) -> Bool {
        let trimmed = month.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == self.month {
            return false
        }
        self.month = trimmed
        self.updated = now
        return true
    }

    /// Keeps the earliest trace; true when it became earlier. Non-positive or future times are not
    /// evidence of anything and are ignored.
    mutating func noteExistedAt(_ timestamp: Int32, trace: GGRegDateTrace, now: Int32) -> Bool {
        if timestamp <= 0 || timestamp > now {
            return false
        }
        if let current = self.existedAt, current <= timestamp {
            return false
        }
        self.existedAt = timestamp
        self.trace = trace
        self.updated = now
        return true
    }

    mutating func noteChecked(_ check: GGRegDateChecks, now: Int32) -> Bool {
        if GGRegDateChecks(rawValue: self.checks).contains(check) {
            return false
        }
        self.checks |= check.rawValue
        self.updated = now
        return true
    }

    func hasChecked(_ check: GGRegDateChecks) -> Bool {
        return GGRegDateChecks(rawValue: self.checks).contains(check)
    }
}

/// One answer of a remote service with Swiftgram's contract. Stored by `regDate.remote` (global: it
/// depends on the ID only).
struct GGRegDateRemoteEntry: Codable, Equatable {
    var from: Int32
    var to: Int32
    /// Until when the answer is current; 0 = no expiry (Swiftgram's `valid_until`).
    var validUntil: Int32
    /// When it was received (0 = migrated from the old client).
    var fetched: Int32

    init(from: Int32, to: Int32, validUntil: Int32, fetched: Int32) {
        self.from = from
        self.to = to
        self.validUntil = validUntil
        self.fetched = fetched
    }

    private enum CodingKeys: String, CodingKey {
        case from = "f"
        case to = "t"
        case validUntil = "v"
        case fetched = "a"
    }

    var range: GGRegDateRange {
        return GGRegDateRange(from: self.from, to: self.to)
    }

    func isFresh(now: Int32) -> Bool {
        return self.validUntil == 0 || self.validUntil > now
    }
}

/// What the row shows: the resolved result and the bounds behind it.
struct GGRegDateSnapshot: Equatable {
    let result: GGRegDateResult
    /// The «existed at» bound given to the resolver, and what gave it.
    let existedAt: Int32?
    let existedAtTrace: GGRegDateTrace?
    /// The «not before» bound given to the resolver, and what gave it.
    let notBefore: Int32?
    let notBeforeTrace: GGRegDateTrace?
}

enum GGRegDateStore {
    /// Users one account keeps evidence for.
    static let evidenceLimit = 800
    /// Remote answers kept.
    static let remoteLimit = 500

    /// Puts the evidence together and asks the resolver. A remote answer counts as such while it is
    /// current (`valid_until`); an expired one is still a real server answer, so its bounds stay as
    /// evidence («не раньше» its `from`, «не позже» its `to`).
    static func snapshot(userId: Int64, stored: GGRegDateStoredEntry, remote: GGRegDateRemoteEntry?, now: Int32) -> GGRegDateSnapshot? {
        var evidence = GGRegDateEvidence(userId: userId, telegramMonth: stored.month, existedAt: stored.existedAt)
        var existedAtTrace = stored.existedAt != nil ? stored.trace : nil
        var notBeforeTrace: GGRegDateTrace?
        if let remote {
            if remote.isFresh(now: now) {
                evidence.remote = remote.range
            } else {
                evidence.notBefore = remote.from
                notBeforeTrace = .expiredRemote
                if evidence.existedAt.map({ remote.to < $0 }) ?? true {
                    evidence.existedAt = remote.to
                    existedAtTrace = .expiredRemote
                }
            }
        }
        guard let result = GGRegDateResolver.resolve(evidence, now: now) else {
            return nil
        }
        return GGRegDateSnapshot(result: result, existedAt: evidence.existedAt, existedAtTrace: existedAtTrace, notBefore: evidence.notBefore, notBeforeTrace: notBeforeTrace)
    }

    /// The entries to keep when there are too many: Telegram's months are dropped last (they can not
    /// be learned again once the user becomes a contact), then the most recently updated win.
    static func trimmedEvidence(_ entries: [String: GGRegDateStoredEntry], limit: Int = GGRegDateStore.evidenceLimit) -> [String: GGRegDateStoredEntry] {
        if entries.count <= limit {
            return entries
        }
        let ordered = entries.sorted { lhs, rhs in
            let lhsMonth = lhs.value.month != nil
            let rhsMonth = rhs.value.month != nil
            if lhsMonth != rhsMonth {
                return lhsMonth
            }
            if lhs.value.updated != rhs.value.updated {
                return lhs.value.updated > rhs.value.updated
            }
            return lhs.key < rhs.key
        }
        var result: [String: GGRegDateStoredEntry] = [:]
        for (key, value) in ordered.prefix(max(0, limit)) {
            result[key] = value
        }
        return result
    }

    /// Current answers are kept first, then the most recently received.
    static func trimmedRemote(_ entries: [String: GGRegDateRemoteEntry], now: Int32, limit: Int = GGRegDateStore.remoteLimit) -> [String: GGRegDateRemoteEntry] {
        if entries.count <= limit {
            return entries
        }
        let ordered = entries.sorted { lhs, rhs in
            let lhsFresh = lhs.value.isFresh(now: now)
            let rhsFresh = rhs.value.isFresh(now: now)
            if lhsFresh != rhsFresh {
                return lhsFresh
            }
            if lhs.value.fetched != rhs.value.fetched {
                return lhs.value.fetched > rhs.value.fetched
            }
            if lhs.value.validUntil != rhs.value.validUntil {
                return lhs.value.validUntil > rhs.value.validUntil
            }
            return lhs.key < rhs.key
        }
        var result: [String: GGRegDateRemoteEntry] = [:]
        for (key, value) in ordered.prefix(max(0, limit)) {
            result[key] = value
        }
        return result
    }

    /// The old client's `regDateCache` (SGSimpleSettings): user id text → JSON of Swiftgram's
    /// `RegDate {from, to, validUntil}` (Int64 unix seconds, default JSONEncoder keys) as `Data`.
    /// Anything that does not fit is skipped.
    static func legacyRemoteAnswers(_ object: Any?) -> [(userId: Int64, entry: GGRegDateRemoteEntry)] {
        guard let dictionary = object as? [String: Any] else {
            return []
        }
        var result: [(userId: Int64, entry: GGRegDateRemoteEntry)] = []
        for (key, value) in dictionary {
            guard let userId = Int64(key), userId > 0 else {
                continue
            }
            var fields: [String: Any]?
            if let data = value as? Data {
                fields = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            } else if let dictionary = value as? [String: Any] {
                fields = dictionary
            }
            guard let fields else {
                continue
            }
            guard let from = GGRegDateStore.timestamp(fields["from"]), let to = GGRegDateStore.timestamp(fields["to"]) else {
                continue
            }
            let validUntil = GGRegDateStore.timestamp(fields["validUntil"] ?? fields["valid_until"]) ?? 0
            guard let entry = GGRegDateStore.remoteEntry(from: from, to: to, validUntil: validUntil, fetched: 0) else {
                continue
            }
            result.append((userId, entry))
        }
        result.sort { $0.userId < $1.userId }
        return result
    }

    /// A sane remote answer or nil: positive, `from <= to`, within Int32.
    static func remoteEntry(from: Int64, to: Int64, validUntil: Int64, fetched: Int32) -> GGRegDateRemoteEntry? {
        guard from > 0, to >= from, to <= Int64(Int32.max) else {
            return nil
        }
        let clampedValidUntil = Int32(clamping: max(0, validUntil))
        return GGRegDateRemoteEntry(from: Int32(from), to: Int32(to), validUntil: clampedValidUntil, fetched: fetched)
    }

    /// A JSON number (or numeric string) as unix seconds.
    static func timestamp(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            // `Double(Int64.max)` rounds up past Int64.max, so the bound is a little lower.
            guard double.isFinite, abs(double) < 9.0e18 else {
                return nil
            }
            return Int64(double)
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }
}
