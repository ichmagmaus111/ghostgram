import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import GGCore

/// What a row, a preview or an action sees. A value type built on every rebuild of a screen;
/// it never outlives the screen (the handle inside is weak to the controller).
public struct GGMenuContext {
    public let context: AccountContext
    public let presentationData: PresentationData
    public let accountID: GGAccountID
    /// The account's own peer, once loaded (for «своя аватарка» in previews).
    public let accountPeer: EnginePeer?
    /// Section of the row being built (valid inside `.custom` builders).
    public internal(set) var sectionId: ItemListSectionId
    /// Scope of the preview being built (valid inside preview modifiers).
    public internal(set) var previewScope: String?
    let drafts: [String: Double]
    let handle: GGMenuScreenHandle

    init(context: AccountContext, presentationData: PresentationData, accountPeer: EnginePeer?, drafts: [String: Double], handle: GGMenuScreenHandle) {
        self.context = context
        self.presentationData = presentationData
        self.accountID = context.account.id.gg
        self.accountPeer = accountPeer
        self.sectionId = 0
        self.previewScope = nil
        self.drafts = drafts
        self.handle = handle
    }

    public var itemListPresentationData: ItemListPresentationData {
        return ItemListPresentationData(self.presentationData)
    }

    public var navigationController: NavigationController? {
        return self.handle.navigationController
    }

    /// The value a slider of this screen is being dragged to, or nil. Previews read it so they
    /// follow the finger while the setting itself is written only on release.
    public func draftValue(forKey key: String) -> Double? {
        return self.drafts[key]
    }

    /// Draft if a slider is being dragged, otherwise the stored value.
    public func displayValue(_ binding: GGMenuBinding<Double>) -> Double {
        if let draft = self.drafts[binding.key] {
            return draft
        }
        return binding.value(in: self)
    }

    public func push(_ controller: ViewController) {
        self.handle.push(controller)
    }

    public func present(_ controller: ViewController) {
        self.handle.present(controller, arguments: nil)
    }

    /// With presentation arguments, e.g. `.modalSheet` for a chat picker.
    public func present(_ controller: ViewController, arguments: ViewControllerPresentationArguments?) {
        self.handle.present(controller, arguments: arguments)
    }

    /// For plain UIKit controllers (document picker, activity sheet).
    public func presentNative(_ controller: UIViewController) {
        self.handle.presentNative(controller)
    }

    public func open(tab: GGMenuTabID) {
        self.handle.open(screen: .tab(tab), focusRowId: nil)
    }

    /// Opens a t.me link inside the app without resetting the navigation stack.
    public func openTelegramLink(_ url: String) {
        self.handle.openTelegramLink(url)
    }

    public func presentToast(_ text: String) {
        self.handle.presentToast(text)
    }
}

/// Owned by one screen; weakly references its controller. Also the single place that knows how to
/// open other menu screens (see `GGMenuScreen.swift`).
final class GGMenuScreenHandle {
    let context: AccountContext
    weak var controller: ViewController?

    init(context: AccountContext) {
        self.context = context
    }

    var navigationController: NavigationController? {
        return self.controller?.navigationController as? NavigationController
    }

    func push(_ controller: ViewController) {
        self.navigationController?.pushViewController(controller)
    }

    func present(_ controller: ViewController, arguments: ViewControllerPresentationArguments? = nil) {
        self.controller?.present(controller, in: .window(.root), with: arguments)
    }

    func presentNative(_ controller: UIViewController) {
        guard let rootController = self.controller?.view.window?.rootViewController else {
            return
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = rootController.view
            popover.sourceRect = CGRect(x: rootController.view.bounds.midX, y: rootController.view.bounds.midY, width: 0.0, height: 0.0)
            popover.permittedArrowDirections = []
        }
        var presenter = rootController
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(controller, animated: true)
    }

    /// Every move to another menu screen goes through the access gates (`GGMenuAccessGates`).
    func open(screen: GGMenuScreenID, focusRowId: String?) {
        let context = self.context
        ggMenuWithAccess(.screen(screen), path: ggMenuScreenPathIds(screen), context: context, perform: { [weak self] in
            guard let self, let controller = ggMakeMenuScreen(context: context, screen: screen, focusRowId: focusRowId) else {
                return nil
            }
            self.push(controller)
            return controller
        })
    }

    func openTelegramLink(_ url: String) {
        guard let navigationController = self.navigationController else {
            return
        }
        ggOpenTelegramLink(context: self.context, url: url, navigationController: navigationController, present: { [weak self] controller in
            self?.present(controller)
        })
    }

    func presentToast(_ text: String) {
        ggPresentToast(context: self.context, text: text, present: { [weak self] controller in
            self?.present(controller)
        })
    }
}
