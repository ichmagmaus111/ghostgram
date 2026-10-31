import Foundation

// The data model of «VPN по подписке»: one VLESS server, a subscription that groups servers, and the
// usage metadata a panel reports. Everything is plain Codable; storage is GGVlessStore (a file).

public enum GGVlessTransport: String, Codable, Equatable {
    case tcp
    case ws
    case grpc
    case httpUpgrade = "httpupgrade"
    case xhttp
}

public enum GGVlessSecurity: String, Codable, Equatable {
    case none
    case tls
    case reality
}

public struct GGVlessServer: Codable, Equatable {
    /// Stable identity derived from the connection parameters (not from the panel's own id or the
    /// name): panels re-issue the same server under a new id, and names change freely.
    public var id: String
    public var name: String
    public var address: String
    public var port: Int
    public var uuid: String
    public var flow: String
    public var transport: GGVlessTransport
    /// ws / httpupgrade / xhttp path, tcp http-header path.
    public var path: String
    /// Host header (ws, httpupgrade, xhttp, tcp http header).
    public var host: String
    /// gRPC service name.
    public var serviceName: String
    /// tcp: "http" for the HTTP header obfuscation, otherwise "none".
    public var headerType: String
    /// xhttp mode ("auto", "packet-up", "stream-up", "stream-one").
    public var mode: String
    public var security: GGVlessSecurity
    public var serverName: String
    public var fingerprint: String
    public var alpn: [String]
    public var allowInsecure: Bool
    public var publicKey: String
    public var shortId: String
    public var spiderX: String

    public init(name: String, address: String, port: Int, uuid: String) {
        self.id = ""
        self.name = name
        self.address = address
        self.port = port
        self.uuid = uuid
        self.flow = ""
        self.transport = .tcp
        self.path = ""
        self.host = ""
        self.serviceName = ""
        self.headerType = "none"
        self.mode = ""
        self.security = .none
        self.serverName = ""
        self.fingerprint = ""
        self.alpn = []
        self.allowInsecure = false
        self.publicKey = ""
        self.shortId = ""
        self.spiderX = ""
    }

    /// Fills `id` from the parameters that define where and how the server is reached.
    public mutating func assignIdentity() {
        let parts: [String] = [
            self.address.lowercased(), String(self.port), self.uuid.lowercased(), self.flow,
            self.transport.rawValue, self.path, self.host, self.serviceName, self.headerType, self.mode,
            self.security.rawValue, self.serverName, self.publicKey, self.shortId
        ]
        self.id = ggVlessStableHash(parts.joined(separator: "\u{1f}"))
    }

    /// `host:port` for display (IPv6 in brackets).
    public var endpoint: String {
        if self.address.contains(":") {
            return "[\(self.address)]:\(self.port)"
        }
        return "\(self.address):\(self.port)"
    }
}

public struct GGVlessUsage: Codable, Equatable {
    public var upload: Int64
    public var download: Int64
    /// 0 = unlimited.
    public var total: Int64
    /// Unix time, 0 = never expires.
    public var expire: Int64

    public init(upload: Int64, download: Int64, total: Int64, expire: Int64) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }
}

public enum GGVlessUpdateInterval: String, Codable, Equatable, CaseIterable {
    /// What the panel asks for (`profile-update-interval`), 24 h when it says nothing.
    case provider
    case hours6
    case hours12
    case hours24
    case manual

    func seconds(providerHours: Int?) -> Double? {
        switch self {
        case .provider:
            let hours = max(1, min(providerHours ?? 24, 24 * 7))
            return Double(hours) * 3600.0
        case .hours6:
            return 6.0 * 3600.0
        case .hours12:
            return 12.0 * 3600.0
        case .hours24:
            return 24.0 * 3600.0
        case .manual:
            return nil
        }
    }
}

public struct GGVlessSubscription: Codable, Equatable {
    public var id: String
    public var name: String
    /// nil for a group of servers added by hand from `vless://` links.
    public var url: String?
    public var servers: [GGVlessServer]
    public var usage: GGVlessUsage?
    public var providerUpdateHours: Int?
    public var updateInterval: GGVlessUpdateInterval
    /// Unix time of the last successful refresh.
    public var updatedAt: Double
    /// Code of the last failed refresh ("network", "http:404", "empty", …; nil after a success),
    /// localized when shown.
    public var lastError: String?

    public init(id: String, name: String, url: String?, servers: [GGVlessServer]) {
        self.id = id
        self.name = name
        self.url = url
        self.servers = servers
        self.usage = nil
        self.providerUpdateHours = nil
        self.updateInterval = .provider
        self.updatedAt = 0.0
        self.lastError = nil
    }
}

/// FNV-1a 64 — a stable, dependency-free identity (not a security primitive).
func ggVlessStableHash(_ string: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(hash, radix: 16)
}
