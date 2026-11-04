import Foundation
import GGCore
import GGSettingsUI

/// The switch in «Оформление › Профиль и Настройки › Профиль», next to the ID and the dates.
enum GGRegDateMenu {
    /// The section GGAppearance declares («Профиль»); rows of other features join it by id.
    static let profileSection = GGMenuSectionID("appearance.profileSettings.profile")

    static func register() {
        // After «Показывать даты» (order 300).
        GGMenuRegistry.register(GGMenuRow(id: "regDate.show", section: GGRegDateMenu.profileSection, order: 350, title: { GGStrings.RegDate.Menu.title }, subtitle: { GGStrings.RegDate.Menu.subtitle }, kind: .toggle(.global(GGRegDateSettings.show)), searchKeywords: { [GGStrings.RegDate.Menu.keywords] }))
    }
}
