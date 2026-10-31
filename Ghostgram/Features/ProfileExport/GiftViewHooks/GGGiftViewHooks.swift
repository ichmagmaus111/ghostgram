// Compiled INTO GiftViewScreen (filegroup //Ghostgram/Features/ProfileExport:GiftViewScreenHookSources).
// Items a feature adds to the "…" menu of a gift's screen (fake gifts: "Add to my profile",
// "Edit", "Delete"). Upstream shows "…" only for collectible gifts; with a feature that has
// items it is shown for plain gifts too. Without handlers GiftViewScreen is unchanged.

import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import ContextUI
import GGCore

/// The gift a screen shows, as a menu provider sees it.
public struct GGGiftViewMenuContext {
    public let context: AccountContext
    public let gift: StarGift
    /// Where the gift is saved (a profile or a message), when it is someone's gift.
    public let reference: StarGiftReference?
    /// The profile the gift belongs to, when known.
    public let ownerPeerId: EnginePeer.Id?
    public let fromPeerId: EnginePeer.Id?
    public let date: Int32
    public let text: String?
    public let entities: [MessageTextEntity]?
    public let nameHidden: Bool
    public let savedToProfile: Bool
    public let pinnedToTop: Bool
    public let number: Int32?
    /// The gift screen; nil while the button's visibility is being decided.
    public weak var controller: ViewController?

    public init(context: AccountContext, gift: StarGift, reference: StarGiftReference?, ownerPeerId: EnginePeer.Id?, fromPeerId: EnginePeer.Id?, date: Int32, text: String?, entities: [MessageTextEntity]?, nameHidden: Bool, savedToProfile: Bool, pinnedToTop: Bool, number: Int32?, controller: ViewController?) {
        self.context = context
        self.gift = gift
        self.reference = reference
        self.ownerPeerId = ownerPeerId
        self.fromPeerId = fromPeerId
        self.date = date
        self.text = text
        self.entities = entities
        self.nameHidden = nameHidden
        self.savedToProfile = savedToProfile
        self.pinnedToTop = pinnedToTop
        self.number = number
        self.controller = controller
    }
}

public enum GGGiftViewHooks {
    /// Providers of items appended to the gift's «…» menu (main thread). Asked also while the
    /// screen decides whether to show «…» for a plain gift (`controller == nil`): answer cheaply.
    public static let menuItems = GGHookPoint<(GGGiftViewMenuContext) -> [ContextMenuItem]>("giftView.menuItems")

    /// Policy (any `true`): the gift exists only on this device (a fake gift). The screen then does
    /// not offer what needs the server (transfer, wear, sell) even though the gift shows you as owner.
    public static let isLocalGift = GGHookPoint<(GGGiftViewMenuContext) -> Bool>("giftView.isLocalGift")
}

private func ggGiftViewMenuContext(context: AccountContext, subject: GiftViewScreen.Subject, controller: ViewController?) -> GGGiftViewMenuContext? {
    guard let arguments = subject.arguments else {
        return nil
    }
    return GGGiftViewMenuContext(
        context: context,
        gift: arguments.gift,
        reference: arguments.reference,
        ownerPeerId: arguments.peerId,
        fromPeerId: arguments.fromPeerId,
        date: arguments.date,
        text: arguments.text,
        entities: arguments.entities,
        nameHidden: arguments.nameHidden,
        savedToProfile: arguments.savedToProfile,
        pinnedToTop: arguments.pinnedToTop ?? false,
        number: arguments.giftNumber,
        controller: controller
    )
}

/// Items of the features for this gift (empty without handlers).
func ggGiftViewMenuItems(context: AccountContext, subject: GiftViewScreen.Subject, controller: ViewController?) -> [ContextMenuItem] {
    if GGGiftViewHooks.menuItems.isEmpty {
        return []
    }
    guard let menuContext = ggGiftViewMenuContext(context: context, subject: subject, controller: controller) else {
        return []
    }
    var result: [ContextMenuItem] = []
    for handler in GGGiftViewHooks.menuItems.handlers {
        result.append(contentsOf: handler(menuContext))
    }
    return result
}

/// Whether a plain (not collectible) gift gets the «…» button.
func ggGiftViewHasMenu(context: AccountContext, subject: GiftViewScreen.Subject) -> Bool {
    if GGGiftViewHooks.menuItems.isEmpty {
        return false
    }
    return !ggGiftViewMenuItems(context: context, subject: subject, controller: nil).isEmpty
}

/// Whether the shown gift is a local-only one (false without handlers).
func ggGiftViewIsLocalGift(context: AccountContext, subject: GiftViewScreen.Subject) -> Bool {
    if GGGiftViewHooks.isLocalGift.isEmpty {
        return false
    }
    guard let menuContext = ggGiftViewMenuContext(context: context, subject: subject, controller: nil) else {
        return false
    }
    for handler in GGGiftViewHooks.isLocalGift.handlers {
        if handler(menuContext) {
            return true
        }
    }
    return false
}
