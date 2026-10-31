import Foundation
import Display
import SwiftSignalKit
import AccountContext
import GGCore
import GGHooks
import GGSettingsUI
import GGFeaturesShared

/// Entry point of the GGVless feature module («Ещё › VPN по подписке»). Owner: W3-5.
public enum GGVlessModule {
    static let serversTab = GGMenuTabID("vless.servers")
    static let mainSection = GGMenuSectionID("vless.main")
    static let optionsSection = GGMenuSectionID("vless.options")

    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        GGVlessSettings.declare()
        let _ = GGVlessLegacy.loopbackPort

        GGVlessModule.registerMenu()

        // «О приложении › Сторонние компоненты» (requests/W3-5.md R5): the core is Xray-core
        // (MPL-2.0) with its Go dependencies (BSD / MIT / Apache-2.0); listed only in builds that
        // carry the core.
        GGMenuRegistry.register(license: GGMenuLicense(
            id: "vless.xrayCore",
            name: "Xray-core",
            license: "MPL-2.0",
            url: "https://github.com/XTLS/Xray-core",
            note: { GGStrings.Vless.License.note },
            order: 100,
            isVisible: {
                return GGXrayCore.isBundled
            }
        ))

        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGVlessController.shared.attach(context: context)
        }, order: 0)

        // Telegram's proxy screen links here: with the VPN on, Telegram's proxy is the core's loopback
        // entry, which that screen does not list.
        GGVpnEntryPoint.makeScreen = { context in
            guard let context = context as? AccountContext else {
                return nil
            }
            return ggVlessMakeServersController(context: context)
        }
        GGVpnEntryPoint.stateText = {
            if !GGXrayCore.isBundled {
                return GGStrings.Vless.ProxyEntry.notBundled
            }
            return GGVlessSettings.enabled.value ? GGStrings.Vless.ProxyEntry.on : GGStrings.Vless.ProxyEntry.off
        }

        GGVlessLegacy.registerMigration()

        // Starts the core in the background if the VPN was on (nothing is loaded otherwise).
        GGVlessController.shared.setup()
    }

    private static func registerMenu() {
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: GGVlessModule.mainSection,
            screen: .tab(.moreVpn),
            order: 300,
            footer: { _ in
                return GGXrayCore.isBundled ? nil : GGStrings.Vless.Status.notBundled
            }
        ))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: GGVlessModule.optionsSection,
            screen: .tab(.moreVpn),
            order: 400,
            footer: { _ in GGStrings.Vless.Menu.footer }
        ))

        GGMenuRegistry.register(GGMenuRow(
            id: "vless.enabled",
            section: GGVlessModule.mainSection,
            order: 100,
            title: { GGStrings.Vless.Menu.enable },
            subtitle: { GGStrings.Vless.Menu.enableInfo },
            kind: .toggle(.global(GGVlessSettings.enabled)),
            searchKeywords: { [GGStrings.Vless.Menu.keywords] },
            isEnabled: { _ in
                // Switching on needs the core in this build and a chosen server; switching off is
                // always possible.
                if GGVlessSettings.enabled.value {
                    return true
                }
                return GGXrayCore.isBundled && !GGVlessSettings.selectedServer.value.isEmpty
            }
        ))

        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: GGVlessModule.serversTab,
                parent: .tab(.moreVpn),
                title: { GGStrings.Vless.Menu.servers },
                makeScreen: { context in
                    return ggVlessMakeServersController(context: context.context)
                },
                searchKeywords: { [GGStrings.Vless.Menu.keywords] }
            ),
            linkIn: GGVlessModule.mainSection,
            order: 200,
            subtitle: { GGStrings.Vless.Menu.serversInfo },
            icon: .bundle("Chat/Context Menu/Globe"),
            label: { _ in
                let id = GGVlessSettings.selectedServer.value
                if id.isEmpty {
                    return GGStrings.Vless.Menu.noServer
                }
                return GGVlessStore.shared.server(id: id)?.1.name
            }
        )

        GGMenuRegistry.register(GGMenuRow(
            id: "vless.proxyBypassOnVpn",
            section: GGVlessModule.optionsSection,
            order: 100,
            title: { GGStrings.Vless.Menu.bypass },
            subtitle: { GGStrings.Vless.Menu.bypassInfo },
            kind: .toggle(.global(GGNetworkSpoofSharedSettings.proxyBypassOnVpn))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "vless.sendHwid",
            section: GGVlessModule.optionsSection,
            order: 200,
            title: { GGStrings.Vless.Menu.hwid },
            subtitle: { GGStrings.Vless.Menu.hwidInfo },
            kind: .toggle(.global(GGVlessSettings.sendHwid))
        ))
    }
}
