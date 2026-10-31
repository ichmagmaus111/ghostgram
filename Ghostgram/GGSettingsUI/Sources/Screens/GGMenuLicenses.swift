import Foundation
import UIKit
import Display
import AccountContext
import GGCore

/// A third-party component bundled with Ghostgram (a library), listed on «О приложении › Сторонние
/// компоненты» with its license. Registered by the feature that ships it. Fonts are not among them:
/// Ghostgram uses only the fonts of iOS (owner decision 2026-10-22).
public struct GGMenuLicense {
    /// Unique, "<feature>.<component>".
    public let id: String
    /// Proper names, shown as is in every language («Xray-core»).
    public let name: String
    /// SPDX identifier(s) («MPL-2.0»), shown on the right.
    public let license: String
    /// The license text or the component's source, opened on tap.
    public let url: String
    /// What it is in Ghostgram, localized at display time («Ядро «VPN по подписке»»).
    public let note: (() -> String)?
    /// Sparse, step 100.
    public let order: Int
    /// nil = always; e.g. only when the component is in this build.
    public let isVisible: (() -> Bool)?

    public init(id: String, name: String, license: String, url: String, note: (() -> String)? = nil, order: Int, isVisible: (() -> Bool)? = nil) {
        self.id = id
        self.name = name
        self.license = license
        self.url = url
        self.note = note
        self.order = order
        self.isVisible = isVisible
    }
}

extension GGMenuTabID {
    /// «О приложении › Сторонние компоненты» (shown once a feature registered a component).
    public static let moreAboutThirdParty = GGMenuTabID("more.about.thirdParty")
}

extension GGMenuSectionID {
    public static let aboutThirdPartyComponents = GGMenuSectionID("more.about.thirdParty.components")
}

/// The tab and its section; called from `GGSettingsUI.register()` before the features.
func ggRegisterLicensesTab() {
    GGMenuRegistry.register(
        tab: GGMenuTabDescriptor(
            id: .moreAboutThirdParty,
            parent: .tab(.moreAbout),
            title: { GGStrings.Menu.About.thirdParty },
            searchKeywords: { [GGStrings.Menu.About.licenseHeader] }
        ),
        linkIn: .aboutLicense,
        order: 200,
        subtitle: { GGStrings.Menu.About.thirdPartyInfo },
        icon: .bundle("Chat/Context Menu/Info")
    )
    GGMenuRegistry.register(section: GGMenuSectionDescriptor(
        id: .aboutThirdPartyComponents,
        screen: .tab(.moreAboutThirdParty),
        order: 300,
        footer: { _ in GGStrings.Menu.About.thirdPartyFooter }
    ))
}

func ggRegisterLicense(_ license: GGMenuLicense) {
    let url = license.url
    let licenseName = license.license
    var isVisible: ((GGMenuContext) -> Bool)?
    if let visible = license.isVisible {
        isVisible = { _ in
            return visible()
        }
    }
    GGMenuRegistry.register(GGMenuRow(
        id: "menu.license.\(license.id)",
        section: .aboutThirdPartyComponents,
        order: license.order,
        title: { license.name },
        subtitle: license.note,
        kind: .action({ menuContext in
            menuContext.context.sharedContext.applicationBindings.openUrl(url)
        }),
        isVisible: isVisible,
        searchKeywords: { [licenseName] },
        label: { _ in licenseName }
    ))
}
