import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import GGCore

/// What the menu is about to open (`GGMenuAccessGates.gate`).
public struct GGMenuAccessRequest {
    public enum Target: Equatable {
        /// A category or a tab: a tap in the menu, a result of the Ghostgram search or of Telegram's
        /// settings search (which may jump straight into a tab deep inside a category).
        case screen(GGMenuScreenID)
        /// An `.action` row (export, import, a feature's own action).
        case action(rowId: String)
    }

    public let target: Target
    /// The screens from the category down to the target screen (for `.action` — down to the row's
    /// screen), without the root. A gate that locks a whole category checks whether it is on the path.
    public let path: [GGMenuScreenID]
    /// The screens of `path` access was already granted to and that are still open: a tab inside an
    /// unlocked category does not have to ask again.
    public let unlocked: Set<GGMenuScreenID>
    public let context: AccountContext
}

/// «Ask for the code before entering» — the point the security feature (Face ID / Touch ID / the
/// passcode through LocalAuthentication) registers its check in. The menu itself checks nothing:
/// with no gate everything opens at once, as before.
public enum GGMenuAccessGates {
    /// Policy; the first gate that returns `true` takes the request over: it asks for the code and
    /// calls `proceed` (any thread, at most once) after access was granted — never when it was
    /// refused or cancelled. Return `false` to let the request through untouched. Called on the main
    /// thread for every open of a category / tab and every `.action` row; answer from memory.
    public static let gate = GGHookPoint<(GGMenuAccessRequest, @escaping () -> Void) -> Bool>("menu.accessGate")
}

/// The screens from the first category down to `screen` (the root is not part of a path).
func ggMenuScreenPathIds(_ screen: GGMenuScreenID, depth: Int = 0) -> [GGMenuScreenID] {
    if depth > 8 {
        return []
    }
    switch screen {
    case .root:
        return []
    case .category:
        return [screen]
    case let .tab(tabId):
        guard let tab = GGMenuStorage.shared.tabs[tabId] else {
            return [screen]
        }
        return ggMenuScreenPathIds(tab.parent, depth: depth + 1) + [screen]
    }
}

/// Screens access was granted to, each anchored to the controller opened after the grant: the grant
/// lasts while that controller is alive (i.e. while the user stays inside). Main thread only.
private final class GGMenuAccessState {
    private final class Grant {
        let screen: GGMenuScreenID
        weak var anchor: ViewController?

        init(screen: GGMenuScreenID, anchor: ViewController) {
            self.screen = screen
            self.anchor = anchor
        }
    }

    static let shared = GGMenuAccessState()

    private var grants: [Grant] = []

    func unlocked(in path: [GGMenuScreenID]) -> Set<GGMenuScreenID> {
        self.grants.removeAll(where: { $0.anchor == nil })
        var result = Set<GGMenuScreenID>()
        for grant in self.grants where path.contains(grant.screen) {
            result.insert(grant.screen)
        }
        return result
    }

    func noteGranted(path: [GGMenuScreenID], anchor: ViewController) {
        for screen in path {
            self.grants.append(Grant(screen: screen, anchor: anchor))
        }
    }
}

/// Runs `perform` at once, or after the gate that took the request over granted access. `perform`
/// returns the controller it opened (the anchor of the grant) or nil for an action.
func ggMenuWithAccess(_ target: GGMenuAccessRequest.Target, path: [GGMenuScreenID], context: AccountContext, perform: @escaping () -> ViewController?) {
    assert(Thread.isMainThread)
    if GGMenuAccessGates.gate.isEmpty || path.isEmpty {
        let _ = perform()
        return
    }
    let request = GGMenuAccessRequest(target: target, path: path, unlocked: GGMenuAccessState.shared.unlocked(in: path), context: context)
    let didProceed = Atomic<Bool>(value: false)
    let proceed: () -> Void = {
        if didProceed.swap(true) {
            return
        }
        Queue.mainQueue().async {
            if let controller = perform() {
                GGMenuAccessState.shared.noteGranted(path: path, anchor: controller)
            }
        }
    }
    for handler in GGMenuAccessGates.gate.handlers {
        if handler(request, proceed) {
            return
        }
    }
    let _ = perform()
}
