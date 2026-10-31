import Foundation

// Parsers of what users paste and what panels serve: `vless://` links, plain or base64 lists of
// them, Xray JSON configs and sing-box JSON configs. Only VLESS is understood; every other protocol
// in a mixed subscription is counted as skipped, never an error for the whole list. A malformed
// entry never fails its neighbours.

public enum GGVlessLinkParser {
    /// One `vless://uuid@host:port?params#name` link.
    public static func parse(_ string: String) -> GGVlessServer? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vless://") else {
            return nil
        }
        // Panels put raw names (spaces, emoji flags) after `#`; iOS 15/16 refuse such a URL whole.
        // The name is split off by hand, and a body with stray characters is escaped once.
        var body = trimmed
        var fragment = ""
        if let hashIndex = body.firstIndex(of: "#") {
            let raw = String(body[body.index(after: hashIndex)...])
            fragment = raw.removingPercentEncoding ?? raw
            body = String(body[..<hashIndex])
        }
        var parsedComponents = URLComponents(string: body)
        if parsedComponents == nil, let escaped = body.addingPercentEncoding(withAllowedCharacters: ggVlessLinkAllowedCharacters) {
            parsedComponents = URLComponents(string: escaped)
        }
        guard let components = parsedComponents else {
            return nil
        }
        guard let user = components.percentEncodedUser?.removingPercentEncoding, !user.isEmpty else {
            return nil
        }
        guard var host = components.host, !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard let port = components.port, (1 ... 65535).contains(port) else {
            return nil
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                query[item.name.lowercased()] = value
            }
        }
        if let encryption = query["encryption"], !encryption.isEmpty, encryption != "none" {
            // VLESS encryption other than "none" is not supported by the bundled config.
            return nil
        }
        let name = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        var server = GGVlessServer(name: name.isEmpty ? host : name, address: host, port: port, uuid: user)
        server.flow = query["flow"] ?? ""
        switch (query["type"] ?? "tcp").lowercased() {
        case "ws", "websocket":
            server.transport = .ws
        case "grpc", "gun":
            server.transport = .grpc
        case "httpupgrade":
            server.transport = .httpUpgrade
        case "xhttp", "splithttp":
            server.transport = .xhttp
        case "tcp", "raw", "":
            server.transport = .tcp
        default:
            return nil
        }
        server.path = query["path"] ?? ""
        server.host = query["host"] ?? ""
        if let serviceName = query["servicename"] {
            server.serviceName = serviceName
        } else if server.transport == .grpc {
            // Some panels put the gRPC service name into `path`.
            server.serviceName = server.path
        }
        server.headerType = query["headertype"] ?? "none"
        server.mode = query["mode"] ?? ""
        switch (query["security"] ?? "none").lowercased() {
        case "tls":
            server.security = .tls
        case "reality":
            server.security = .reality
        case "none", "":
            server.security = .none
        default:
            return nil
        }
        server.serverName = query["sni"] ?? query["peer"] ?? ""
        server.fingerprint = query["fp"] ?? ""
        server.alpn = (query["alpn"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        server.allowInsecure = query["allowinsecure"] == "1" || query["allowinsecure"] == "true" || query["insecure"] == "1"
        server.publicKey = query["pbk"] ?? ""
        server.shortId = query["sid"] ?? ""
        server.spiderX = query["spx"] ?? ""
        if server.security == .reality && server.publicKey.isEmpty {
            return nil
        }
        server.assignIdentity()
        return server
    }
}

/// What may stay unescaped in a link body: the query set plus IPv6 brackets and existing escapes.
private let ggVlessLinkAllowedCharacters: CharacterSet = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "[]%"))

public struct GGVlessParseResult {
    public var servers: [GGVlessServer]
    /// Entries that are not VLESS or could not be read.
    public var skipped: Int

    public init(servers: [GGVlessServer], skipped: Int) {
        self.servers = servers
        self.skipped = skipped
    }
}

public enum GGVlessSubscriptionParser {
    public static func parse(_ data: Data) -> GGVlessParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return GGVlessParseResult(servers: [], skipped: 0)
        }
        return GGVlessSubscriptionParser.parse(text: text, allowBase64: true)
    }

    public static func parse(text: String, allowBase64: Bool = true) -> GGVlessParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return GGVlessParseResult(servers: [], skipped: 0)
        }
        var result: GGVlessParseResult
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            result = GGVlessSubscriptionParser.parseJSON(trimmed)
        } else if trimmed.contains("://") {
            result = GGVlessSubscriptionParser.parseLines(trimmed)
        } else if allowBase64, let decoded = ggVlessDecodeBase64(trimmed) {
            result = GGVlessSubscriptionParser.parse(text: decoded, allowBase64: false)
        } else {
            result = GGVlessParseResult(servers: [], skipped: 0)
        }
        result.servers = GGVlessSubscriptionParser.deduplicated(result.servers)
        return result
    }

    private static func parseLines(_ text: String) -> GGVlessParseResult {
        var result = GGVlessParseResult(servers: [], skipped: 0)
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty || entry.hasPrefix("#") || entry.hasPrefix("//") {
                continue
            }
            if let server = GGVlessLinkParser.parse(entry) {
                result.servers.append(server)
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    private static func parseJSON(_ text: String) -> GGVlessParseResult {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            return GGVlessParseResult(servers: [], skipped: 0)
        }
        var configs: [[String: Any]] = []
        if let array = object as? [[String: Any]] {
            configs = array
        } else if let dictionary = object as? [String: Any] {
            configs = [dictionary]
        }
        var result = GGVlessParseResult(servers: [], skipped: 0)
        for config in configs {
            let remarks = (config["remarks"] as? String) ?? ""
            guard let outbounds = config["outbounds"] as? [[String: Any]] else {
                continue
            }
            for outbound in outbounds {
                if let proto = outbound["protocol"] as? String {
                    if proto == "vless" {
                        if let server = GGVlessSubscriptionParser.xrayServer(outbound, remarks: remarks) {
                            result.servers.append(server)
                        } else {
                            result.skipped += 1
                        }
                    } else if !["freedom", "blackhole", "dns", "loopback"].contains(proto) {
                        result.skipped += 1
                    }
                } else if let type = outbound["type"] as? String {
                    if type == "vless" {
                        if let server = GGVlessSubscriptionParser.singBoxServer(outbound) {
                            result.servers.append(server)
                        } else {
                            result.skipped += 1
                        }
                    } else if !["direct", "block", "dns", "selector", "urltest"].contains(type) {
                        result.skipped += 1
                    }
                }
            }
        }
        return result
    }

    private static func xrayServer(_ outbound: [String: Any], remarks: String) -> GGVlessServer? {
        guard let settings = outbound["settings"] as? [String: Any] else {
            return nil
        }
        var address = settings["address"] as? String
        var port = ggVlessInt(settings["port"])
        var user: [String: Any]? = settings["id"] != nil ? settings : nil
        if let vnext = (settings["vnext"] as? [[String: Any]])?.first {
            address = vnext["address"] as? String
            port = ggVlessInt(vnext["port"])
            user = (vnext["users"] as? [[String: Any]])?.first
        }
        guard let address, !address.isEmpty, let port, (1 ... 65535).contains(port), let user, let uuid = user["id"] as? String, !uuid.isEmpty else {
            return nil
        }
        if let encryption = user["encryption"] as? String, !encryption.isEmpty, encryption != "none" {
            return nil
        }
        let tag = (outbound["tag"] as? String) ?? ""
        var server = GGVlessServer(name: !remarks.isEmpty ? remarks : (!tag.isEmpty && tag != "proxy" ? tag : address), address: address, port: port, uuid: uuid)
        server.flow = (user["flow"] as? String) ?? ""
        let stream = (outbound["streamSettings"] as? [String: Any]) ?? [:]
        switch ((stream["network"] as? String) ?? "tcp").lowercased() {
        case "ws", "websocket":
            server.transport = .ws
            let ws = (stream["wsSettings"] as? [String: Any]) ?? [:]
            server.path = (ws["path"] as? String) ?? ""
            server.host = (ws["host"] as? String) ?? ((ws["headers"] as? [String: Any])?["Host"] as? String) ?? ""
        case "grpc", "gun":
            server.transport = .grpc
            server.serviceName = ((stream["grpcSettings"] as? [String: Any])?["serviceName"] as? String) ?? ""
        case "httpupgrade":
            server.transport = .httpUpgrade
            let settings = (stream["httpupgradeSettings"] as? [String: Any]) ?? [:]
            server.path = (settings["path"] as? String) ?? ""
            server.host = (settings["host"] as? String) ?? ""
        case "xhttp", "splithttp":
            server.transport = .xhttp
            let settings = (stream["xhttpSettings"] as? [String: Any]) ?? (stream["splithttpSettings"] as? [String: Any]) ?? [:]
            server.path = (settings["path"] as? String) ?? ""
            server.host = (settings["host"] as? String) ?? ""
            server.mode = (settings["mode"] as? String) ?? ""
        case "tcp", "raw":
            server.transport = .tcp
            let tcp = (stream["tcpSettings"] as? [String: Any]) ?? (stream["rawSettings"] as? [String: Any]) ?? [:]
            if let header = tcp["header"] as? [String: Any], (header["type"] as? String) == "http" {
                server.headerType = "http"
                let request = (header["request"] as? [String: Any]) ?? [:]
                server.path = ((request["path"] as? [String])?.first) ?? ""
                server.host = (((request["headers"] as? [String: Any])?["Host"] as? [String])?.first) ?? ""
            }
        default:
            return nil
        }
        switch ((stream["security"] as? String) ?? "none").lowercased() {
        case "tls":
            server.security = .tls
            let tls = (stream["tlsSettings"] as? [String: Any]) ?? [:]
            server.serverName = (tls["serverName"] as? String) ?? ""
            server.fingerprint = (tls["fingerprint"] as? String) ?? ""
            server.alpn = (tls["alpn"] as? [String]) ?? []
            server.allowInsecure = (tls["allowInsecure"] as? Bool) ?? false
        case "reality":
            server.security = .reality
            let reality = (stream["realitySettings"] as? [String: Any]) ?? [:]
            server.serverName = (reality["serverName"] as? String) ?? ""
            server.fingerprint = (reality["fingerprint"] as? String) ?? ""
            server.publicKey = (reality["publicKey"] as? String) ?? (reality["password"] as? String) ?? ""
            server.shortId = (reality["shortId"] as? String) ?? ""
            server.spiderX = (reality["spiderX"] as? String) ?? ""
            if server.publicKey.isEmpty {
                return nil
            }
        case "none", "":
            server.security = .none
        default:
            return nil
        }
        server.assignIdentity()
        return server
    }

    private static func singBoxServer(_ outbound: [String: Any]) -> GGVlessServer? {
        guard let address = outbound["server"] as? String, !address.isEmpty, let port = ggVlessInt(outbound["server_port"]), (1 ... 65535).contains(port), let uuid = outbound["uuid"] as? String, !uuid.isEmpty else {
            return nil
        }
        let tag = (outbound["tag"] as? String) ?? ""
        var server = GGVlessServer(name: tag.isEmpty ? address : tag, address: address, port: port, uuid: uuid)
        server.flow = (outbound["flow"] as? String) ?? ""
        if let transport = outbound["transport"] as? [String: Any] {
            switch ((transport["type"] as? String) ?? "").lowercased() {
            case "ws":
                server.transport = .ws
                server.path = (transport["path"] as? String) ?? ""
                server.host = ((transport["headers"] as? [String: Any])?["Host"] as? String) ?? ""
            case "grpc":
                server.transport = .grpc
                server.serviceName = (transport["service_name"] as? String) ?? ""
            case "httpupgrade":
                server.transport = .httpUpgrade
                server.path = (transport["path"] as? String) ?? ""
                server.host = (transport["host"] as? String) ?? ""
            case "http":
                server.transport = .tcp
                server.headerType = "http"
                server.path = (transport["path"] as? String) ?? ""
                server.host = ((transport["host"] as? [String])?.first) ?? ""
            default:
                return nil
            }
        }
        if let tls = outbound["tls"] as? [String: Any], (tls["enabled"] as? Bool) == true {
            server.serverName = (tls["server_name"] as? String) ?? ""
            server.allowInsecure = (tls["insecure"] as? Bool) ?? false
            server.alpn = (tls["alpn"] as? [String]) ?? []
            if let utls = tls["utls"] as? [String: Any], (utls["enabled"] as? Bool) == true {
                server.fingerprint = (utls["fingerprint"] as? String) ?? ""
            }
            if let reality = tls["reality"] as? [String: Any], (reality["enabled"] as? Bool) == true {
                server.security = .reality
                server.publicKey = (reality["public_key"] as? String) ?? ""
                server.shortId = (reality["short_id"] as? String) ?? ""
                if server.publicKey.isEmpty {
                    return nil
                }
            } else {
                server.security = .tls
            }
        }
        server.assignIdentity()
        return server
    }

    /// Keeps the first of servers with the same identity; names of later copies are dropped.
    private static func deduplicated(_ servers: [GGVlessServer]) -> [GGVlessServer] {
        var seen = Set<String>()
        var result: [GGVlessServer] = []
        for server in servers where !seen.contains(server.id) {
            seen.insert(server.id)
            result.append(server)
        }
        return result
    }
}

/// Panel metadata from the response headers.
public struct GGVlessSubscriptionHeaders {
    public var title: String?
    public var usage: GGVlessUsage?
    public var updateHours: Int?

    public init(headers: [AnyHashable: Any]) {
        var lowered: [String: String] = [:]
        for (key, value) in headers {
            if let key = key as? String, let value = value as? String {
                lowered[key.lowercased()] = value
            }
        }
        if let title = lowered["profile-title"] {
            if title.hasPrefix("base64:"), let decoded = ggVlessDecodeBase64(String(title.dropFirst("base64:".count))) {
                self.title = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let info = lowered["subscription-userinfo"] {
            var values: [String: Int64] = [:]
            for part in info.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, let value = ggVlessParseInt64(pair[1]) {
                    values[pair[0].lowercased()] = value
                }
            }
            if !values.isEmpty {
                self.usage = GGVlessUsage(upload: max(0, values["upload"] ?? 0), download: max(0, values["download"] ?? 0), total: max(0, values["total"] ?? 0), expire: max(0, values["expire"] ?? 0))
            }
        }
        if let hours = lowered["profile-update-interval"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), hours > 0 {
            self.updateHours = hours
        }
    }
}

func ggVlessDecodeBase64(_ string: String) -> String? {
    var normalized = string.filter { !$0.isWhitespace }
    normalized = normalized.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder == 1 {
        return nil
    }
    if remainder > 0 {
        normalized += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: normalized), let text = String(data: data, encoding: .utf8) else {
        return nil
    }
    return text
}

/// Panels write byte counts as integers, sometimes as floats ("1.5e9").
func ggVlessParseInt64(_ string: String) -> Int64? {
    if let value = Int64(string) {
        return value
    }
    guard let double = Double(string), double.isFinite, abs(double) < 9.0e18 else {
        return nil
    }
    return Int64(double.rounded())
}

func ggVlessInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    if let value = value as? NSNumber {
        return value.intValue
    }
    if let value = value as? String {
        return Int(value)
    }
    return nil
}
