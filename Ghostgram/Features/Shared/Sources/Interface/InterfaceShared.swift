import Foundation
import TelegramCore
import GGCore

/// The part of GGInterface that the extensions (notification service, share) also link: settings with
/// `.extensions`, NSE handlers, attribute declarations. Owner: W2-5.
///
/// The Interface zone has nothing the extensions read. What lives here is the one cross-zone API of
/// the zone — quick actions for the chat's quick buttons — because GGFeaturesShared is the module
/// every feature module may depend on (GG<Feature> modules may not depend on each other).
public enum GGInterfaceShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
    }
}

/// Where a quick action is performed.
public struct GGQuickActionContext {
    public let account: Account
    /// The chat the button was tapped in.
    public let peerId: EnginePeer.Id
    /// The chat screen (`ChatController`), for actions that act on it (scroll, input).
    public weak var chatController: AnyObject?
    /// The chat's `AccountContext` (this module can not name the type: cast with `as? AccountContext`),
    /// for actions that open a screen.
    public let accountContext: AnyObject?

    public init(account: Account, peerId: EnginePeer.Id, chatController: AnyObject?, accountContext: AnyObject? = nil) {
        self.account = account
        self.peerId = peerId
        self.chatController = chatController
        self.accountContext = accountContext
    }

    public var accountID: GGAccountID {
        return self.account.id.gg
    }
}

/// One button of «Кнопки быстрого доступа» in a chat. Registered by the feature that owns the
/// action (ghost mode — W2-1, deleted / edited messages — W2-2, translation — W2-3, screenshot
/// protection — W3-4, scroll to top — W2-5). The buttons themselves are drawn by GGInterface.
public struct GGQuickAction {
    public let id: String
    /// Sparse, step 100; the order of the buttons.
    public let order: Int
    /// GGStrings accessor, evaluated when shown.
    public let title: () -> String
    /// A template glyph of the app's asset catalog («Chat/Context Menu/…»).
    public let iconName: String
    /// For switch-like actions: whether it is on for the account (the button is highlighted).
    /// Called on every layout of the buttons: answer from a setting read.
    public let isOn: ((GGQuickActionContext) -> Bool)?
    /// Hidden in chats where it makes no sense (nil = always available).
    public let isAvailable: ((GGQuickActionContext) -> Bool)?
    /// Main thread.
    public let perform: (GGQuickActionContext) -> Void

    public init(id: String, order: Int, title: @escaping () -> String, iconName: String, isOn: ((GGQuickActionContext) -> Bool)? = nil, isAvailable: ((GGQuickActionContext) -> Bool)? = nil, perform: @escaping (GGQuickActionContext) -> Void) {
        self.id = id
        self.order = order
        self.title = title
        self.iconName = iconName
        self.isOn = isOn
        self.isAvailable = isAvailable
        self.perform = perform
    }
}

public enum GGQuickActions {
    /// Register from `register()` of the owning module (main thread, before freeze).
    public static let actions = GGHookPoint<GGQuickAction>("quickActions.actions")

    /// The registered actions in their order.
    public static var all: [GGQuickAction] {
        return GGQuickActions.actions.handlers.sorted(by: { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.id < rhs.id
        })
    }
}

/// Ids of the actions the old client had (the migration of its per-button switches uses them).
public enum GGQuickActionIds {
    public static let ghostMode = "ghostMode"
    public static let deletedMessages = "antiDelete.deleted"
    public static let editedMessages = "antiDelete.edited"
    public static let sendDelay = "sendDelay"
    public static let scrollToTop = "interface.scrollToTop"
    public static let translateBeforeSend = "translation.beforeSend"
    public static let screenshotPrivacy = "security.screenshotPrivacy"
}
