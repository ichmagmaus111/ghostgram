import Foundation
import UIKit
import TelegramPresentationData
import AccountContext
import GGCore
import GGHooks

/// A row of Telegram's own Settings tab that can be hidden or moved («Скрыть пункты»).
/// `section` / `itemId` are PeerInfoScreen's (`SettingsSection` case name and the item's id).
enum GGSettingsTabItem: String, CaseIterable {
    // The account's own actions above everything («Сменить эмодзи-статус», «Изменить цвет
    // профиля», «Выбрать фотографию»): the old «Скрыть … своего профиля» switches (W2-4 → here).
    case editEmojiStatus
    case editProfileColor
    case editPhoto
    case myProfile
    case money
    case proxy
    case apps
    case savedMessages
    case recentCalls
    case devices
    case chatFolders
    case notifications
    case privacy
    case data
    case appearance
    case powerSaving
    case language
    case premium
    case stars
    case ton
    case business
    case gifts
    case passport
    case watch
    case support
    case faq
    case tips

    var section: String {
        switch self {
        case .editEmojiStatus, .editProfileColor, .editPhoto:
            return "edit"
        case .myProfile:
            return "myProfile"
        case .money:
            return "wallet"
        case .proxy:
            return "proxy"
        case .apps:
            return "apps"
        case .savedMessages, .recentCalls, .devices, .chatFolders:
            return "shortcuts"
        case .notifications, .privacy, .data, .appearance, .powerSaving, .language:
            return "advanced"
        case .premium, .stars, .ton, .business, .gifts:
            return "payment"
        case .passport, .watch:
            return "extra"
        case .support, .faq, .tips:
            return "support"
        }
    }

    /// The item id inside its section; nil = every item of the section (mini apps).
    var itemId: Int? {
        switch self {
        case .editEmojiStatus:
            return 0
        case .editProfileColor:
            return 1
        case .editPhoto:
            return 2
        case .myProfile, .money, .proxy:
            return 0
        case .apps:
            return nil
        case .savedMessages:
            return 1
        case .recentCalls:
            return 2
        case .devices:
            return 3
        case .chatFolders:
            return 4
        case .notifications:
            return 0
        case .privacy:
            return 1
        case .data:
            return 2
        case .appearance:
            return 3
        case .powerSaving:
            return 6
        case .language:
            return 4
        case .premium:
            return 100
        case .stars:
            return 102
        case .ton:
            return 103
        case .business:
            return 104
        case .gifts:
            return 105
        case .passport, .support:
            return 0
        case .watch, .faq:
            return 1
        case .tips:
            return 2
        }
    }

    func matches(_ key: GGSettingsTabItemKey) -> Bool {
        if key.section != self.section {
            return false
        }
        guard let itemId = self.itemId else {
            return true
        }
        return key.itemId == AnyHashable(itemId)
    }

    /// Telegram's own title of the row.
    func title(strings: PresentationStrings) -> String {
        switch self {
        case .editEmojiStatus:
            return strings.PeerInfo_SetEmojiStatus
        case .editProfileColor:
            return strings.PeerInfo_ChangeProfileColor
        case .editPhoto:
            return strings.Settings_SetProfilePhotoOrVideo
        case .myProfile:
            return strings.Settings_MyProfile
        case .money:
            return strings.Settings_Money
        case .proxy:
            return strings.Settings_Proxy
        case .apps:
            return GGStrings.Interface.SettingsTab.miniApps
        case .savedMessages:
            return strings.Settings_SavedMessages
        case .recentCalls:
            return strings.CallSettings_RecentCalls
        case .devices:
            return strings.Settings_Devices
        case .chatFolders:
            return strings.Settings_ChatFolders
        case .notifications:
            return strings.Settings_NotificationsAndSounds
        case .privacy:
            return strings.Settings_PrivacySettings
        case .data:
            return strings.Settings_ChatSettings
        case .appearance:
            return strings.Settings_Appearance
        case .powerSaving:
            return strings.Settings_PowerSaving
        case .language:
            return strings.Settings_AppLanguage
        case .premium:
            return strings.Settings_Premium
        case .stars:
            return strings.Settings_Stars
        case .ton:
            return strings.Settings_MyTon
        case .business:
            return strings.Settings_Business
        case .gifts:
            return strings.Settings_SendGift
        case .passport:
            return strings.Settings_Passport
        case .watch:
            return strings.Settings_AppleWatch
        case .support:
            return strings.Settings_Support
        case .faq:
            return strings.Settings_FAQ
        case .tips:
            return strings.Settings_Tips
        }
    }

    /// Keys of the old `FontCustomization.hiddenSettings.<name>` switches that hid this row
    /// (the old «Кошелёк» switch hid the whole payment block).
    var legacyNames: [String] {
        switch self {
        case .editEmojiStatus, .editProfileColor, .editPhoto:
            // Their old switches had their own keys (`InterfaceMigrations`, profile actions).
            return []
        case .myProfile:
            return ["myProfile"]
        case .money, .ton:
            return ["wallet"]
        case .proxy, .apps:
            return []
        case .savedMessages:
            return ["savedMessages"]
        case .recentCalls:
            return ["recentCalls"]
        case .devices:
            return ["devices"]
        case .chatFolders:
            return ["chatFolders"]
        case .notifications:
            return ["notificationsAndSounds"]
        case .privacy:
            return ["privacyAndSecurity"]
        case .data:
            return ["dataAndStorage"]
        case .appearance:
            return ["appearance"]
        case .powerSaving:
            return ["powerSaving"]
        case .language:
            return ["language"]
        case .premium:
            return ["premium", "wallet"]
        case .stars:
            return ["stars", "wallet"]
        case .business:
            return ["business", "wallet"]
        case .gifts:
            return ["gifts", "wallet"]
        case .passport:
            return ["passport"]
        case .watch:
            return ["watch"]
        case .support:
            return ["support"]
        case .faq:
            return ["faq"]
        case .tips:
            return ["tips"]
        }
    }

    /// The old order list used these names (one per row).
    init?(legacyName: String) {
        switch legacyName {
        case "wallet":
            self = .money
        case "notificationsAndSounds":
            self = .notifications
        case "privacyAndSecurity":
            self = .privacy
        case "dataAndStorage":
            self = .data
        default:
            guard let value = GGSettingsTabItem(rawValue: legacyName) else {
                return nil
            }
            self = value
        }
    }

    /// All the old legacy keys, for the migration (each read once, removed afterwards).
    static var allLegacyNames: Set<String> {
        var result = Set<String>()
        for item in GGSettingsTabItem.allCases {
            result.formUnion(item.legacyNames)
        }
        return result
    }
}

enum GGSettingsTabLayout {
    /// Known rows once each; the order only matters within a section.
    static func normalizedOrder(_ order: [String]) -> [String] {
        var result: [String] = []
        for id in order where GGSettingsTabItem(rawValue: id) != nil && !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// The rows of one section in the user's order (items of the section not in the order keep
    /// Telegram's relative position after the ordered ones).
    static func orderedItems(section: String, order: [String]) -> [GGSettingsTabItem] {
        let inSection = order.compactMap { GGSettingsTabItem(rawValue: $0) }.filter { $0.section == section && $0.itemId != nil }
        return inSection
    }

    static func register() {
        GGSettingsTabHooks.hiddenItem.register({ key, _ in
            let hidden = InterfaceSnapshots.shared.current.hiddenSettingsItems
            if hidden.isEmpty {
                return false
            }
            for id in hidden {
                if let item = GGSettingsTabItem(rawValue: id), item.matches(key) {
                    return true
                }
            }
            return false
        })
    }
}
