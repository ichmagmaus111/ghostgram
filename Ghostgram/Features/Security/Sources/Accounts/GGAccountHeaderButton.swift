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
import NavigationBarComponent
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
            let context = header.context
            var result = buttons
            result.append(NavigationBarComponent.Button(
                id: GGAccountHeaderButton.buttonId,
                content: .custom(AnyComponent(GGAccountHeaderButtonComponent(context: context, theme: context.sharedContext.currentPresentationData.with { $0 }.theme))),
                action: { _ in
                    GGAccountHeaderButton.switchToNextAccount(context: context)
                },
                contextAction: { sourceView, gesture in
                    GGAccountHeaderButton.presentMenu(context: context, sourceView: sourceView, gesture: gesture)
                }
            ))
            return result
        })
    }

    /// The glass under the button with square avatars («Скругление углов»): a rounded square
    /// concentric with the avatar's corners, not Telegram's circle. nil = Telegram's capsule.
    static func glassCornerRadius(height: CGFloat) -> CGFloat? {
        guard GGAvatarHooks.currentShape().squareAvatars else {
            return nil
        }
        let side = GGAccountHeaderButton.avatarSide
        let avatarRadius = ggAvatarRoundedRectRadius(side, upstream: floor(side * 0.5))
        return avatarRadius + max(0.0, (height - side) * 0.5)
    }

    /// A tap: the next signed-in account (the one whose avatar the button shows).
    static func switchToNextAccount(context: AccountContext) {
        let _ = (GGAccountHeaderButton.otherAccounts(context: context)
        |> take(1)
        |> deliverOnMainQueue).start(next: { accounts in
            guard let next = accounts.first else {
                return
            }
            context.sharedContext.switchToAccount(id: next.account.id, fromSettingsController: nil, withChatListController: nil)
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

/// The button's content: the next account's avatar. Taps and the long press are the bar's
/// (`NavigationBarComponent.Button.action` / `contextAction`).
final class GGAccountHeaderButtonComponent: Component {
    typealias EnvironmentType = NavigationButtonEnvironment

    let context: AccountContext
    let theme: PresentationTheme

    init(context: AccountContext, theme: PresentationTheme) {
        self.context = context
        self.theme = theme
    }

    static func ==(lhs: GGAccountHeaderButtonComponent, rhs: GGAccountHeaderButtonComponent) -> Bool {
        return lhs.context === rhs.context && lhs.theme === rhs.theme
    }

    final class View: UIView, GGNavigationButtonGlassShape {
        private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 12.0))
        private var component: GGAccountHeaderButtonComponent?
        private var theme: PresentationTheme?
        private var disposable: Disposable?
        private var nextAccount: AccountWithInfo?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.avatarNode.isUserInteractionEnabled = false
            self.addSubview(self.avatarNode.view)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            self.disposable?.dispose()
        }

        func ggGlassCornerRadius(height: CGFloat) -> CGFloat? {
            return GGAccountHeaderButton.glassCornerRadius(height: height)
        }

        private func applyAvatar() {
            guard let theme = self.theme, let next = self.nextAccount else {
                return
            }
            let account = next.account
            self.avatarNode.setPeer(accountPeerId: account.peerId, postbox: account.postbox, network: account.network, contentSettings: .default, theme: theme, peer: next.peer, displayDimensions: CGSize(width: GGAccountHeaderButton.avatarSide, height: GGAccountHeaderButton.avatarSide))
        }

        func update(component: GGAccountHeaderButtonComponent, availableSize: CGSize) -> CGSize {
            let theme = component.theme
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
                    self.applyAvatar()
                })
            } else if themeChanged {
                self.applyAvatar()
            }
            let size = CGSize(width: 44.0, height: availableSize.height)
            let avatarSize = CGSize(width: GGAccountHeaderButton.avatarSide, height: GGAccountHeaderButton.avatarSide)
            self.avatarNode.frame = CGRect(origin: CGPoint(x: floor((size.width - avatarSize.width) / 2.0), y: floor((size.height - avatarSize.height) / 2.0)), size: avatarSize)
            return size
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationButtonEnvironment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize)
    }
}
