import Foundation
import UIKit
import SwiftSignalKit
import AsyncDisplayKit
import Display
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import AvatarNode
import AccountPeerContextItem
import ChatListHeaderComponent
import ChatListUI
import GGCore
import GGHooks
import GGFeaturesShared

/// The account button in the «Чаты» header (`security.accounts.headerButton`): the avatar of the next
/// signed-in account; a tap switches to it, a long press opens the accounts menu. Everything goes
/// through `switchToAccount`, so «Face ID при смене аккаунта» asks first. The avatar is drawn by
/// `AvatarNode` from the other account's own media box, asynchronously — no image is read from disk on
/// the main thread. The button exists only while there is another account (cached count) and keeps
/// its own subscription to the account list for the avatar.
///
/// The header's glass under the button follows the avatar: with square avatars («Скругление углов»)
/// it is a rounded square concentric with the avatar's corners, not Telegram's circle.
enum GGAccountHeaderButton {
    static let buttonId: AnyHashable = "gg.security.accounts"
    static let avatarSide: CGFloat = 28.0

    static func register() {
        GGChatListHooks.headerRightButtons.register({ buttons, header in
            guard GGSecuritySettings.accountsHeaderButton.value, GGAccountsList.shared.otherAccountCount > 0, case .chatList(.root) = header.location else {
                return buttons
            }
            var result = buttons
            result.append(AnyComponentWithIdentity(id: GGAccountHeaderButton.buttonId, component: AnyComponent(GGAccountHeaderButtonComponent(context: header.context))))
            return result
        })
        GGChatListChromeHooks.rightButtonsCornerRadius.register({ buttonIds, height in
            guard buttonIds.contains(GGAccountHeaderButton.buttonId), GGAvatarHooks.currentShape().squareAvatars else {
                return nil
            }
            let side = GGAccountHeaderButton.avatarSide
            let avatarRadius = ggAvatarRoundedRectRadius(side, upstream: floor(side * 0.5))
            return avatarRadius + max(0.0, (height - side) * 0.5)
        })
    }

    /// The other accounts in Telegram's order, without the current one.
    static func otherAccounts(context: AccountContext) -> Signal<[AccountWithInfo], NoError> {
        let currentId = context.account.id
        return context.sharedContext.activeAccountsWithInfo
        |> map { _, accounts -> [AccountWithInfo] in
            return accounts.filter { $0.account.id != currentId }
        }
    }

    static func presentMenu(context: AccountContext, sourceView: UIView, gesture: ContextGesture?) {
        let _ = (GGAccountHeaderButton.otherAccounts(context: context)
        |> take(1)
        |> deliverOnMainQueue).start(next: { accounts in
            if accounts.isEmpty {
                gesture?.cancel()
                return
            }
            var items: [ContextMenuItem] = []
            for info in accounts {
                let id = info.account.id
                items.append(.custom(AccountPeerContextItem(context: context, account: info.account, peer: info.peer, action: { _, f in
                    f(.dismissWithoutContent)
                    context.sharedContext.switchToAccount(id: id, fromSettingsController: nil, withChatListController: nil)
                }), true))
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let controller = makeContextController(presentationData: presentationData, source: .reference(GGAccountHeaderReferenceSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
            context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
        })
    }
}

private final class GGAccountHeaderReferenceSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}

final class GGAccountHeaderButtonComponent: Component {
    typealias EnvironmentType = NavigationButtonComponentEnvironment

    let context: AccountContext

    init(context: AccountContext) {
        self.context = context
    }

    static func ==(lhs: GGAccountHeaderButtonComponent, rhs: GGAccountHeaderButtonComponent) -> Bool {
        return lhs.context === rhs.context
    }

    final class View: UIView {
        private let sourceView = ContextControllerSourceView()
        private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 12.0))
        private var component: GGAccountHeaderButtonComponent?
        private var theme: PresentationTheme?
        private var disposable: Disposable?
        private var nextAccount: AccountWithInfo?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.sourceView.animateScale = true
            self.addSubview(self.sourceView)
            self.sourceView.addSubview(self.avatarNode.view)
            self.sourceView.activated = { [weak self] gesture, _ in
                guard let self, let component = self.component else {
                    gesture.cancel()
                    return
                }
                GGAccountHeaderButton.presentMenu(context: component.context, sourceView: self.sourceView, gesture: gesture)
            }
            let tap = UITapGestureRecognizer(target: self, action: #selector(self.tapped))
            self.sourceView.addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            self.disposable?.dispose()
        }

        @objc private func tapped() {
            guard let component = self.component, let next = self.nextAccount else {
                return
            }
            component.context.sharedContext.switchToAccount(id: next.account.id, fromSettingsController: nil, withChatListController: nil)
        }

        private func applyAvatar() {
            guard let theme = self.theme, let next = self.nextAccount else {
                return
            }
            let account = next.account
            self.avatarNode.setPeer(accountPeerId: account.peerId, postbox: account.postbox, network: account.network, contentSettings: .default, theme: theme, peer: next.peer, displayDimensions: CGSize(width: GGAccountHeaderButton.avatarSide, height: GGAccountHeaderButton.avatarSide))
        }

        func update(component: GGAccountHeaderButtonComponent, availableSize: CGSize, environment: Environment<NavigationButtonComponentEnvironment>) -> CGSize {
            let theme = environment[NavigationButtonComponentEnvironment.self].value.theme
            let contextChanged = self.component?.context !== component.context
            let themeChanged = self.theme !== theme
            self.component = component
            self.theme = theme
            if contextChanged {
                self.disposable?.dispose()
                self.disposable = (GGAccountHeaderButton.otherAccounts(context: component.context)
                |> deliverOnMainQueue).start(next: { [weak self] accounts in
                    guard let self else {
                        return
                    }
                    let next = accounts.first
                    self.nextAccount = next
                    self.avatarNode.isHidden = next == nil
                    self.sourceView.isGestureEnabled = next != nil
                    self.applyAvatar()
                })
            } else if themeChanged {
                self.applyAvatar()
            }
            let size = CGSize(width: 44.0, height: availableSize.height)
            let avatarSize = CGSize(width: GGAccountHeaderButton.avatarSide, height: GGAccountHeaderButton.avatarSide)
            self.sourceView.frame = CGRect(origin: CGPoint(), size: size)
            self.avatarNode.frame = CGRect(origin: CGPoint(x: floor((size.width - avatarSize.width) / 2.0), y: floor((size.height - avatarSize.height) / 2.0)), size: avatarSize)
            return size
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationButtonComponentEnvironment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, environment: environment)
    }
}
