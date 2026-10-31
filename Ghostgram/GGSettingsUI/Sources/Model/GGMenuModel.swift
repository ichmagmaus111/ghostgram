import Foundation
import UIKit
import Display
import TelegramPresentationData
import GGCore

// Declarative menu model: category → tab → section → row.
// Features register rows into existing sections (and may add deeper tabs); the screens are
// generated from the registry. Order is always the declared sparse `order`, never array position.

public enum GGMenuCategory: String, CaseIterable {
    case privacy
    case messages
    case media
    case appearance
    case security
    case more
}

public struct GGMenuTabID: Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct GGMenuSectionID: Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A screen of the menu: the root, a category or a tab.
public enum GGMenuScreenID: Hashable {
    case root
    case category(GGMenuCategory)
    case tab(GGMenuTabID)
}

/// Menu row icon. Always rendered as a 24 pt template glyph tinted with `ggMenuIconColor(theme:)`.
public enum GGMenuIcon: Equatable {
    /// A glyph from the app asset catalog (Telegram's own glyphs, e.g. "Chat/Context Menu/Eye").
    case bundle(String)
    /// An SF Symbol available on iOS 15.
    case system(String)
    /// The Ghostgram ghost from this module's assets.
    case ghost
}

public struct GGMenuChoiceOption {
    public let value: String
    public let title: () -> String

    public init(value: String, title: @escaping () -> String) {
        self.value = value
        self.title = title
    }
}

public struct GGMenuCardOption {
    public let value: String
    public let title: () -> String
    /// Drawn inside the card; called with the current theme, keep it cheap or cache it.
    public let image: (PresentationTheme) -> UIImage?

    public init(value: String, title: @escaping () -> String, image: @escaping (PresentationTheme) -> UIImage?) {
        self.value = value
        self.title = title
        self.image = image
    }
}

/// Binds a row to a GGSetting or to a GGAccountSetting of the account the menu is open for.
public struct GGMenuBinding<Value: GGSettingValue> {
    public let key: String
    public let requiresRestart: Bool
    let read: (GGAccountID) -> Value
    let write: (Value, GGAccountID) -> Void
    let isDefaultValue: (GGAccountID) -> Bool
    let resetValue: (GGAccountID) -> Void

    public static func global(_ setting: GGSetting<Value>) -> GGMenuBinding<Value> {
        return GGMenuBinding<Value>(
            key: setting.key,
            requiresRestart: setting.flags.contains(.requiresRestart),
            read: { _ in
                return setting.value
            },
            write: { value, _ in
                setting.set(value)
            },
            isDefaultValue: { _ in
                return setting.isDefault
            },
            resetValue: { _ in
                setting.reset()
            }
        )
    }

    public static func account(_ setting: GGAccountSetting<Value>) -> GGMenuBinding<Value> {
        return GGMenuBinding<Value>(
            key: setting.key,
            requiresRestart: setting.flags.contains(.requiresRestart),
            read: { account in
                return setting.value(for: account)
            },
            write: { value, account in
                setting.set(value, for: account)
            },
            isDefaultValue: { account in
                return setting.isDefault(for: account)
            },
            resetValue: { account in
                setting.reset(for: account)
            }
        )
    }

    public func value(in context: GGMenuContext) -> Value {
        return self.read(context.accountID)
    }

    /// Writes through the registry; the menu rebuilds from `GGSettingsStore.shared.revision`.
    public func set(_ value: Value, in context: GGMenuContext) {
        if self.requiresRestart {
            let current = self.read(context.accountID)
            GGMenuRestartTracker.shared.noteBeforeChange(key: self.key, launchValue: current)
        }
        self.write(value, context.accountID)
    }

    public func isDefault(in context: GGMenuContext) -> Bool {
        return self.isDefaultValue(context.accountID)
    }

    public func reset(in context: GGMenuContext) {
        if self.requiresRestart {
            let current = self.read(context.accountID)
            GGMenuRestartTracker.shared.noteBeforeChange(key: self.key, launchValue: current)
        }
        self.resetValue(context.accountID)
    }

    func isPendingRestart(in context: GGMenuContext) -> Bool {
        guard self.requiresRestart else {
            return false
        }
        return GGMenuRestartTracker.shared.differsFromLaunch(key: self.key, current: self.read(context.accountID))
    }
}

/// Type-erased view of a binding, used for the navbar reset button, «Нужен перезапуск» and duplicate checks.
struct GGMenuAnyBinding {
    let key: String
    let isDefault: (GGMenuContext) -> Bool
    let reset: (GGMenuContext) -> Void
    let isPendingRestart: (GGMenuContext) -> Bool

    init<Value>(_ binding: GGMenuBinding<Value>) {
        self.key = binding.key
        self.isDefault = { context in
            return binding.isDefault(in: context)
        }
        self.reset = { context in
            binding.reset(in: context)
        }
        self.isPendingRestart = { context in
            return binding.isPendingRestart(in: context)
        }
    }
}

public enum GGMenuRowKind {
    case toggle(GGMenuBinding<Bool>)
    /// ≤ 6 options → action sheet, more → a list screen. The current value is shown in accent color.
    case choice(GGMenuBinding<String>, options: [GGMenuChoiceOption])
    /// Ticks update only the previews of the screen; the setting is written on release.
    case slider(GGMenuBinding<Double>, range: ClosedRange<Double>, step: Double, format: (Double) -> String)
    /// «Кнопка с подписью»: icon + title + grey subtitle, no chevron.
    case tab(GGMenuTabID)
    case action((GGMenuContext) -> Void)
    /// Master switch with an «N/M» counter; children must be `.toggle` rows.
    case expandableGroup(master: GGMenuBinding<Bool>, children: [GGMenuRow])
    /// The same block without a master switch (2026-10-27): the title, a summary on the right made by
    /// `summary` from the visible children (not called, and nothing shown, while none is on), a
    /// chevron; a tap opens the children in place. Children must be `.toggle` rows.
    case expandableList(children: [GGMenuRow], summary: (GGMenuGroupCount) -> String)
    case preview(GGMenuPreview)
    /// Escape hatch: build any list item. Use `context.sectionId` and `context.itemListPresentationData`.
    case custom((GGMenuContext) -> ListViewItem)
    /// Discrete slider with a label above every tick (2…6 options).
    case discreteChoice(GGMenuBinding<String>, options: [GGMenuChoiceOption])
    /// N cards with a picture, one selected.
    case cards(GGMenuBinding<String>, options: [GGMenuCardOption])
}

public struct GGMenuRow {
    /// Globally unique, "<feature>.<row>". Also the search target and the highlight tag.
    public let id: String
    public let section: GGMenuSectionID
    /// Sparse, step 100. The position on screen is `order`, never array arithmetic.
    public let order: Int
    /// GGStrings accessor, evaluated at display time.
    public let title: () -> String
    /// Grey subtitle; text examples «привет → ПРИВЕТ» go here.
    public let subtitle: (() -> String)?
    public let icon: GGMenuIcon?
    public let kind: GGMenuRowKind
    public let isVisible: ((GGMenuContext) -> Bool)?
    public let searchKeywords: () -> [String]
    /// Accent label on the right of `.tab` / `.action` rows. Must reflect the feature's own state.
    public let label: ((GGMenuContext) -> String?)?
    public let isEnabled: ((GGMenuContext) -> Bool)?
    /// Red action row (resets, deletions). Only meaningful for `.action`.
    public let isDestructive: Bool

    public init(
        id: String,
        section: GGMenuSectionID,
        order: Int,
        title: @escaping () -> String,
        subtitle: (() -> String)? = nil,
        icon: GGMenuIcon? = nil,
        kind: GGMenuRowKind,
        isVisible: ((GGMenuContext) -> Bool)? = nil,
        searchKeywords: @escaping () -> [String] = { [] },
        label: ((GGMenuContext) -> String?)? = nil,
        isEnabled: ((GGMenuContext) -> Bool)? = nil,
        isDestructive: Bool = false
    ) {
        self.id = id
        self.section = section
        self.order = order
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.kind = kind
        self.isVisible = isVisible
        self.searchKeywords = searchKeywords
        self.label = label
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
    }

    /// The children of an expandable row (with or without a master switch); nil for any other row.
    var groupChildren: [GGMenuRow]? {
        switch self.kind {
        case let .expandableGroup(_, children):
            return children
        case let .expandableList(children, _):
            return children
        default:
            return nil
        }
    }

    var isToggle: Bool {
        if case .toggle = self.kind {
            return true
        } else {
            return false
        }
    }

    var anyBindings: [GGMenuAnyBinding] {
        switch self.kind {
        case let .toggle(binding):
            return [GGMenuAnyBinding(binding)]
        case let .choice(binding, _):
            return [GGMenuAnyBinding(binding)]
        case let .slider(binding, _, _, _):
            return [GGMenuAnyBinding(binding)]
        case let .discreteChoice(binding, _):
            return [GGMenuAnyBinding(binding)]
        case let .cards(binding, _):
            return [GGMenuAnyBinding(binding)]
        case let .expandableGroup(master, children):
            var result = [GGMenuAnyBinding(master)]
            for child in children {
                result.append(contentsOf: child.anyBindings)
            }
            return result
        case let .expandableList(children, _):
            var result: [GGMenuAnyBinding] = []
            for child in children {
                result.append(contentsOf: child.anyBindings)
            }
            return result
        case .tab, .action, .preview, .custom:
            return []
        }
    }
}

/// Segment of a tab screen with parallel views («Чаты / Папки / Типы чатов»), shown in the navbar.
public struct GGMenuSegment {
    public let id: String
    public let title: () -> String

    public init(id: String, title: @escaping () -> String) {
        self.id = id
        self.title = title
    }
}

/// Header of a sub-screen: an emoji or a bundled animated sticker over a short text.
public struct GGMenuTopView {
    public enum Content: Equatable {
        case emoji(String)
        /// Name of a bundled `.tgs` (as `AnimatedStickerNodeLocalFileSource(name:)` expects).
        case animation(String)
    }

    public let content: Content
    public let text: () -> String

    public init(content: Content, text: @escaping () -> String) {
        self.content = content
        self.text = text
    }
}

public struct GGMenuTabDescriptor {
    public let id: GGMenuTabID
    /// The screen this tab is opened from (a category, or a tab for deeper feature tabs).
    public let parent: GGMenuScreenID
    public let title: () -> String
    public let topView: GGMenuTopView?
    public let segments: [GGMenuSegment]
    /// Optional fully custom screen (history lists, editors). `nil` = generated from sections.
    public let makeScreen: ((GGMenuContext) -> ViewController)?
    public let searchKeywords: () -> [String]

    public init(
        id: GGMenuTabID,
        parent: GGMenuScreenID,
        title: @escaping () -> String,
        topView: GGMenuTopView? = nil,
        segments: [GGMenuSegment] = [],
        makeScreen: ((GGMenuContext) -> ViewController)? = nil,
        searchKeywords: @escaping () -> [String] = { [] }
    ) {
        self.id = id
        self.parent = parent
        self.title = title
        self.topView = topView
        self.segments = segments
        self.makeScreen = makeScreen
        self.searchKeywords = searchKeywords
    }
}

public struct GGMenuSectionDescriptor {
    public let id: GGMenuSectionID
    public let screen: GGMenuScreenID
    /// Sparse, step 100.
    public let order: Int
    /// `nil` = shown in every segment of the screen.
    public let segment: String?
    public let header: (() -> String)?
    public let footer: ((GGMenuContext) -> String?)?
    public let isVisible: ((GGMenuContext) -> Bool)?

    public init(
        id: GGMenuSectionID,
        screen: GGMenuScreenID,
        order: Int,
        segment: String? = nil,
        header: (() -> String)? = nil,
        footer: ((GGMenuContext) -> String?)? = nil,
        isVisible: ((GGMenuContext) -> Bool)? = nil
    ) {
        self.id = id
        self.screen = screen
        self.order = order
        self.segment = segment
        self.header = header
        self.footer = footer
        self.isVisible = isVisible
    }
}
