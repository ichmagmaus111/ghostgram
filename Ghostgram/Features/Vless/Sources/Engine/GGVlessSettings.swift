import Foundation
import TelegramCore
import GGCore
import GGFeaturesShared

// Settings of «VPN по подписке». Global: Telegram's proxy is shared by every account of the app.
// The loopback port is in GGFeaturesShared (the extensions must recognise the loopback entry).

public struct GGVlessSavedProxy: Codable, Equatable, GGSettingValue {
    public var enabled: Bool
    public var activeServer: ProxyServerSettings?

    public init(enabled: Bool, activeServer: ProxyServerSettings?) {
        self.enabled = enabled
        self.activeServer = activeServer
    }
}

public enum GGVlessSettings {
    public static let enabled = GGSetting<Bool>("vless.enabled", default: false)
    /// Identity of the chosen server (`GGVlessServer.id`), "" = none.
    public static let selectedServer = GGSetting<String>("vless.selectedServer", default: "")
    /// Send a random installation id (`x-hwid`) with subscription requests. Off: panels that limit
    /// devices by it will refuse; the user decides.
    public static let sendHwid = GGSetting<Bool>("vless.sendHwid", default: false)
    /// The random id itself, created on first use. Never derived from the device.
    public static let hwid = GGSetting<String>("vless.hwid", default: "", flags: [.noExport])
    /// Telegram's proxy state before the VPN took it over, restored when the VPN is switched off.
    public static let previousProxy = GGSetting<GGVlessSavedProxy?>("vless.previousProxy", default: nil, flags: [.noExport])
    /// Credentials of the loopback SOCKS5 listener (the same pair is in Telegram's proxy entry).
    public static let inboundUser = GGSetting<String>("vless.inboundUser", default: "", flags: [.noExport])
    public static let inboundPassword = GGSetting<String>("vless.inboundPassword", default: "", flags: [.noExport])

    static func declare() {
        let _ = GGVlessSettings.enabled
        let _ = GGVlessSettings.selectedServer
        let _ = GGVlessSettings.sendHwid
        let _ = GGVlessSettings.hwid
        let _ = GGVlessSettings.previousProxy
        let _ = GGVlessSettings.inboundUser
        let _ = GGVlessSettings.inboundPassword
    }

    /// The installation id for `x-hwid`, created when first needed.
    static func installationId() -> String {
        let current = GGVlessSettings.hwid.value
        if !current.isEmpty {
            return current
        }
        let value = UUID().uuidString
        GGVlessSettings.hwid.set(value)
        return value
    }
}
