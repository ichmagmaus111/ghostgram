import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGSettingsUI

/// Entry point of the GGNetworkSpoof feature module («Приватность › Подмены»). Owner: W3-5.
public enum GGNetworkSpoofModule {
    static let phoneTab = GGMenuTabID("networkSpoof.phone")
    static let profilesTab = GGMenuTabID("networkSpoof.profiles")

    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        GGNetworkSpoofSettings.declare()

        // Own number, on this device only. Hiding the number (W2-1, order 0) wins over replacing it.
        GGPeerInfoHooks.displayedPhoneNumber.register({ request in
            guard request.isAccountPeer else {
                return nil
            }
            let account = request.context.account.id.gg
            guard GGNetworkSpoofSettings.fakePhoneEnabled.value(for: account) else {
                return nil
            }
            let number = GGNetworkSpoofSettings.fakePhone.value(for: account)
            if number.isEmpty {
                return nil
            }
            return .replaced(number)
        }, order: 100)

        // Profile substitution: the whole target peer (namespace included) is opened, so the
        // profile's chat location, shared media and actions all belong to the target.
        GGPeerInfoHooks.redirectPeer.register({ context, peerId in
            if peerId == context.account.peerId {
                return nil
            }
            let account = context.account.id.gg
            guard GGNetworkSpoofSettings.profileRedirectEnabled.value(for: account) else {
                return nil
            }
            guard let target = GGNetworkSpoofSettings.profileRedirects.value(for: account)[peerId.ggKey.stringValue] else {
                return nil
            }
            let targetId = PeerId(ggKey: target)
            return targetId == peerId ? nil : targetId
        }, order: 0)

        GGNetworkSpoofModule.registerMenu()
        GGNetworkSpoofMigrations.register()
    }

    private static func registerMenu() {
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: GGNetworkSpoofModule.phoneTab,
                parent: .tab(.privacySpoofing),
                title: { GGStrings.NetworkSpoof.Phone.title },
                makeScreen: { context in
                    return ggSpoofMakePhoneController(context: context.context)
                },
                searchKeywords: { [GGStrings.NetworkSpoof.Phone.keywords] }
            ),
            linkIn: .main(of: .privacySpoofing),
            order: 200,
            subtitle: { GGStrings.NetworkSpoof.Phone.info },
            icon: .bundle("Chat/Context Menu/Call"),
            label: { context in
                return GGNetworkSpoofSettings.fakePhoneEnabled.value(for: context.accountID) ? GGStrings.NetworkSpoof.Menu.on : GGStrings.NetworkSpoof.Menu.off
            }
        )
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: GGNetworkSpoofModule.profilesTab,
                parent: .tab(.privacySpoofing),
                title: { GGStrings.NetworkSpoof.Profiles.title },
                makeScreen: { context in
                    return ggSpoofMakeProfilesController(context: context.context)
                },
                searchKeywords: { [GGStrings.NetworkSpoof.Profiles.keywords] }
            ),
            linkIn: .main(of: .privacySpoofing),
            order: 300,
            subtitle: { GGStrings.NetworkSpoof.Profiles.info },
            icon: .bundle("Chat/Context Menu/User"),
            label: { context in
                return GGNetworkSpoofSettings.profileRedirectEnabled.value(for: context.accountID) ? GGStrings.NetworkSpoof.Menu.on : GGStrings.NetworkSpoof.Menu.off
            }
        )
    }
}
