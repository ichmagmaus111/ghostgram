import Foundation

// Swiftgram's regdate contract, plain Foundation (host-tested):
//
//     GET <base>/v<version>/regdate/<user id>
//     200 {"from": <unix s>, "to": <unix s>, "valid_until": <unix s, 0 = no expiry>}
//
// `from` / `to` bound the moment the account was created; `valid_until` is until when the answer is
// current (Swiftgram caches it, `SGRegDate`). Swiftgram also sends `Authorization: Token <web app
// data>` and `Device-Token: <DeviceCheck>`; neither is made here (owner's decision 2026-11-01).

/// Credentials a remote service may ask for. DeviceCheck and App Attest are not done now: both stay
/// empty, and a server is not asked while it would need them (see `GGRegDateAPI`).
struct GGRegDateAPICredentials: Equatable {
    var authorization: String?
    var deviceToken: String?

    static let none = GGRegDateAPICredentials(authorization: nil, deviceToken: nil)

    /// The request headers, with Swiftgram's names; empty without credentials.
    var headers: [String: String] {
        var result: [String: String] = [:]
        if let authorization = self.authorization, !authorization.isEmpty {
            result["Authorization"] = "Token \(authorization)"
        }
        if let deviceToken = self.deviceToken, !deviceToken.isEmpty {
            result["Device-Token"] = deviceToken
        }
        return result
    }
}

enum GGRegDateRemoteResponse {
    static let apiVersion = "0"

    /// `<base>/v0/regdate/<userId>`; a trailing slash of `base` is not doubled.
    static func url(base: URL, userId: Int64) -> URL {
        return base.appendingPathComponent("v\(GGRegDateRemoteResponse.apiVersion)").appendingPathComponent("regdate").appendingPathComponent("\(userId)")
    }

    /// The answer, or nil for anything that is not a sane `{from, to, valid_until}` object.
    /// `to` in the future is cut to `now` (the account exists now at the latest).
    static func parse(_ data: Data, now: Int32, fetched: Int32) -> GGRegDateRemoteEntry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        guard let from = GGRegDateStore.timestamp(object["from"]), var to = GGRegDateStore.timestamp(object["to"]) else {
            return nil
        }
        if to > Int64(now) {
            to = Int64(now)
        }
        let validUntil = GGRegDateStore.timestamp(object["valid_until"]) ?? 0
        return GGRegDateStore.remoteEntry(from: from, to: to, validUntil: validUntil, fetched: fetched)
    }
}
