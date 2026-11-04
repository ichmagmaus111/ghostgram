import Foundation
import SwiftSignalKit
import GGCore

/// The remote source of registration dates, Swiftgram's `SGAPI.getSGAPIRegDate` in Ghostgram's
/// architecture: one `GET`, through `GGNetwork` (ephemeral session, the user's SOCKS5 proxy, nothing
/// sent while an MTProxy / WEB proxy is on), 10 s like Swiftgram.
///
/// **Off:** there is no address. Swiftgram's server and its `@SwiftgramBot` token are not used
/// (owner's decision 2026-11-01, inventory 1.3 C3), so with `baseURL == nil` no request is ever made.
/// A server the owner gives later is set here; the contract is `GGRegDateRemoteResponse`. Such a
/// server learns the ID of every profile opened, which the explanation then says.
enum GGRegDateAPI {
    /// The server's base address (`https://…`); nil = the source is off.
    static let baseURL: URL? = nil
    /// DeviceCheck / App Attest are not done now, so there are none.
    static let credentials = GGRegDateAPICredentials.none
    static let requestTimeout: Double = 10.0
    static let maxResponseBytes = 4096

    static var isEnabled: Bool {
        return GGRegDateAPI.baseURL != nil
    }

    /// The answer for `userId`, nil on any failure. Without an address: nil at once, no network.
    static func fetch(userId: Int64, now: Int32) -> Signal<GGRegDateRemoteEntry?, NoError> {
        guard let baseURL = GGRegDateAPI.baseURL, userId > 0 else {
            return .single(nil)
        }
        // `GGNetwork` sends no custom headers yet (requests/W7-RD2.md): a server that needs
        // credentials is not asked rather than asked without them.
        if !GGRegDateAPI.credentials.headers.isEmpty {
            return .single(nil)
        }
        let request = GGNetworkRequest(url: GGRegDateRemoteResponse.url(base: baseURL, userId: userId), maxBytes: GGRegDateAPI.maxResponseBytes)
        return GGNetwork.shared.fetch(request)
        |> map { response -> GGRegDateRemoteEntry? in
            guard let data = response.data else {
                return nil
            }
            return GGRegDateRemoteResponse.parse(data, now: now, fetched: now)
        }
        |> `catch` { _ -> Signal<GGRegDateRemoteEntry?, NoError> in
            return .single(nil)
        }
        |> timeout(GGRegDateAPI.requestTimeout, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
    }
}
