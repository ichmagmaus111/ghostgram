import Foundation
import GGCore
import GGFeaturesShared

// Moves the old client's VPN data (same bundle id, UserDefaults `VLESS.*`) to the new storage once.
// Servers are re-read from their original `vless://` links, so whatever the old model got wrong does
// not come along; a server without its link is dropped (its subscription brings it back on refresh).
// The old "send HWID" choice is not carried over: the new default is not to send it.

enum GGVlessLegacy {
    /// The old client's loopback port: its proxy entry (no password) is recognised as the VPN's own,
    /// so it is replaced or removed instead of being kept as "the user's proxy".
    static let loopbackPort = GGSetting<Int>("vless.legacyLoopbackPort", default: 0, flags: [.noExport])

    static func registerMigration() {
        GGMigrations.registerGlobal(id: "vless.v1", { legacy in
            var subscriptions: [GGVlessSubscription] = []
            var oldLinks: [String: String] = [:]

            if let data = legacy.data("VLESS.subscriptions"), let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                for entry in array {
                    guard let url = entry["url"] as? String, !url.isEmpty else {
                        continue
                    }
                    let meta = entry["meta"] as? [String: Any]
                    let name = (entry["customName"] as? String) ?? (meta?["title"] as? String) ?? (URL(string: url)?.host ?? url)
                    let servers = GGVlessLegacy.servers(entry["servers"], links: &oldLinks)
                    var subscription = GGVlessSubscription(id: (entry["id"] as? String) ?? UUID().uuidString, name: name, url: url, servers: servers)
                    if let hours = entry["autoUpdateHours"] as? Int {
                        subscription.updateInterval = hours <= 6 ? .hours6 : (hours <= 12 ? .hours12 : .hours24)
                    }
                    subscriptions.append(subscription)
                }
            }
            if let data = legacy.data("VLESS.manualServers"), let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                let servers = GGVlessLegacy.servers(array, links: &oldLinks)
                if !servers.isEmpty {
                    var manual = GGVlessSubscription(id: UUID().uuidString, name: "", url: nil, servers: servers)
                    manual.updateInterval = .manual
                    subscriptions.append(manual)
                }
            }
            if !subscriptions.isEmpty {
                GGVlessStore.shared.update { current in
                    if current.isEmpty {
                        current = subscriptions
                    }
                }
            }
            if let oldSelected = legacy.string("VLESS.selectedServerId"), let link = oldLinks[oldSelected], let server = GGVlessLinkParser.parse(link) {
                GGVlessSettings.selectedServer.set(server.id)
            }
            let port = legacy.int("VLESS.committedRoutePort") ?? legacy.int("VLESS.localSocksPort") ?? 0
            if (1 ... 65535).contains(port) {
                GGVlessLegacy.loopbackPort.set(port)
                if !GGVlessSettings.selectedServer.value.isEmpty && GGXrayCore.isBundled {
                    // The old client had its tunnel on: keep the user protected — only a build with
                    // the core can, otherwise the switch would say «on» while Telegram goes direct.
                    GGVlessSettings.enabled.set(true)
                }
            }
            for key in ["VLESS.subscriptions", "VLESS.manualServers", "VLESS.selectedServerId", "VLESS.localSocksPort", "VLESS.committedRoutePort", "VLESS.lastUpdateCheck"] {
                legacy.removeLegacyKey(key)
            }
            if let bypass = legacy.bool("MiscSettings.disableProxyWhenVPNActive") {
                GGNetworkSpoofSharedSettings.proxyBypassOnVpn.set(bypass)
                legacy.removeLegacyKey("MiscSettings.disableProxyWhenVPNActive")
            }
        })
    }

    private static func servers(_ value: Any?, links: inout [String: String]) -> [GGVlessServer] {
        guard let array = value as? [[String: Any]] else {
            return []
        }
        var result: [GGVlessServer] = []
        for entry in array {
            guard let link = entry["rawLink"] as? String, var server = GGVlessLinkParser.parse(link) else {
                continue
            }
            if let name = entry["displayName"] as? String, !name.isEmpty {
                server.name = name
            }
            if let oldId = entry["id"] as? String {
                links[oldId] = link
            }
            result.append(server)
        }
        return result
    }
}
