import Foundation
import Security

// Builds the Xray JSON config for one server: a SOCKS5 inbound on loopback (password protected —
// any app on the device can reach 127.0.0.1) and a single VLESS outbound. Logs are off. Traffic
// counters of the outbound are enabled for the status screen.

struct GGXrayInboundCredentials: Equatable {
    let username: String
    let password: String

    static func random() -> GGXrayInboundCredentials {
        return GGXrayInboundCredentials(username: ggVlessRandomToken(length: 12), password: ggVlessRandomToken(length: 24))
    }
}

enum GGXrayConfig {
    static let outboundTag = "proxy"

    static func make(server: GGVlessServer, port: Int, credentials: GGXrayInboundCredentials) -> String? {
        var user: [String: Any] = ["id": server.uuid, "encryption": "none"]
        if !server.flow.isEmpty {
            user["flow"] = server.flow
        }
        var stream: [String: Any] = [:]
        switch server.transport {
        case .tcp:
            stream["network"] = "tcp"
            if server.headerType == "http" {
                var request: [String: Any] = ["path": [server.path.isEmpty ? "/" : server.path]]
                if !server.host.isEmpty {
                    request["headers"] = ["Host": [server.host]]
                }
                stream["tcpSettings"] = ["header": ["type": "http", "request": request]]
            }
        case .ws:
            stream["network"] = "ws"
            var ws: [String: Any] = ["path": server.path.isEmpty ? "/" : server.path]
            if !server.host.isEmpty {
                ws["host"] = server.host
            }
            stream["wsSettings"] = ws
        case .grpc:
            stream["network"] = "grpc"
            stream["grpcSettings"] = ["serviceName": server.serviceName]
        case .httpUpgrade:
            stream["network"] = "httpupgrade"
            var settings: [String: Any] = ["path": server.path.isEmpty ? "/" : server.path]
            if !server.host.isEmpty {
                settings["host"] = server.host
            }
            stream["httpupgradeSettings"] = settings
        case .xhttp:
            stream["network"] = "xhttp"
            var settings: [String: Any] = ["path": server.path.isEmpty ? "/" : server.path]
            if !server.host.isEmpty {
                settings["host"] = server.host
            }
            if !server.mode.isEmpty {
                settings["mode"] = server.mode
            }
            stream["xhttpSettings"] = settings
        }
        switch server.security {
        case .none:
            stream["security"] = "none"
        case .tls:
            stream["security"] = "tls"
            var tls: [String: Any] = ["allowInsecure": server.allowInsecure]
            if !server.serverName.isEmpty {
                tls["serverName"] = server.serverName
            }
            if !server.fingerprint.isEmpty {
                tls["fingerprint"] = server.fingerprint
            }
            if !server.alpn.isEmpty {
                tls["alpn"] = server.alpn
            }
            stream["tlsSettings"] = tls
        case .reality:
            stream["security"] = "reality"
            var reality: [String: Any] = [
                "publicKey": server.publicKey,
                "fingerprint": server.fingerprint.isEmpty ? "chrome" : server.fingerprint
            ]
            if !server.serverName.isEmpty {
                reality["serverName"] = server.serverName
            }
            if !server.shortId.isEmpty {
                reality["shortId"] = server.shortId
            }
            if !server.spiderX.isEmpty {
                reality["spiderX"] = server.spiderX
            }
            stream["realitySettings"] = reality
        }

        let inboundSettings: [String: Any] = [
            "auth": "password",
            "accounts": [["user": credentials.username, "pass": credentials.password]],
            "udp": false
        ]
        let inbound: [String: Any] = [
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": port,
            "protocol": "socks",
            "settings": inboundSettings
        ]
        let endpoint: [String: Any] = ["address": server.address, "port": server.port, "users": [user]]
        let outbound: [String: Any] = [
            "tag": GGXrayConfig.outboundTag,
            "protocol": "vless",
            "settings": ["vnext": [endpoint]],
            "streamSettings": stream
        ]
        let direct: [String: Any] = ["tag": "direct", "protocol": "freedom"]
        let policy: [String: Any] = ["system": ["statsOutboundUplink": true, "statsOutboundDownlink": true]]
        var config: [String: Any] = [:]
        config["log"] = ["loglevel": "none"]
        config["inbounds"] = [inbound]
        config["outbounds"] = [outbound, direct]
        config["stats"] = [String: Any]()
        config["policy"] = policy
        guard JSONSerialization.isValidJSONObject(config), let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

func ggVlessRandomToken(length: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    var bytes = [UInt8](repeating: 0, count: length)
    if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
        for i in 0 ..< length {
            bytes[i] = UInt8.random(in: 0 ... 255)
        }
    }
    return String(bytes.map { alphabet[Int($0) % alphabet.count] })
}
