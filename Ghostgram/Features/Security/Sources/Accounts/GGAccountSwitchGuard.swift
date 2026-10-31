import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGFeaturesShared

/// «Face ID при смене аккаунта» — one setting (`security.accountSwitchAuth`, global) for every way of
/// switching:
/// - `GGAccountsHooks.switchGate` covers `switchToAccount`: Settings' account list (asked before the
///   list is detached, so a cancel does not freeze it), the Settings tab's account menu and double tap,
///   the «Чаты» header button and its menu, a notification of another account, re-login with a number
///   that is already signed in;
/// - the long-press preview of another account's chat list in Settings is not shown while the setting
///   is on (`GGAccountsHooks.hidesAccountPreview`);
/// - a switch that bypasses `switchToAccount` (the account manager moving to another signed-in account
///   after a logout, the debug account list) is caught when the primary account changes: the app is
///   covered until the check passes. A newly signed-in account is not asked (the user has just proved
///   it is theirs), neither is the first account on launch (the app lock owns the launch).
final class GGAccountSwitchGuard {
    static let shared = GGAccountSwitchGuard()

    private weak var context: AccountContext?
    private var grantedSwitch: AccountRecordId?
    private var lastPrimary: AccountRecordId?
    private var knownAccounts = Set<AccountRecordId>()
    private var disposable: Disposable?
    private weak var cover: GGLockCoverController?

    func register() {
        GGAccountsHooks.switchGate.register({ [weak self] id, proceed in
            guard let self, GGSecuritySettings.accountSwitchAuth.value, let context = self.context else {
                return false
            }
            GGLocalAuthGate.shared.authenticate(context: context, reason: GGStrings.Security.Auth.reasonAccount, completion: { [weak self] granted in
                guard granted else {
                    return
                }
                self?.grantedSwitch = id
                proceed()
            })
            return true
        })
        GGAccountsHooks.hidesAccountPreview.register({ _ in
            return GGSecuritySettings.accountSwitchAuth.value
        })
    }

    /// From every account's root controllers (main thread).
    func start(context: AccountContext) {
        self.context = context
        if self.disposable != nil {
            return
        }
        self.disposable = (context.sharedContext.activeAccountContexts
        |> deliverOnMainQueue).start(next: { [weak self] primary, accounts, currentAuth in
            guard let self else {
                return
            }
            // While an account is being added the record of the new one is current and the primary
            // falls back to some other account: not a switch.
            if currentAuth != nil {
                return
            }
            let primaryId = primary?.account.id
            let previous = self.lastPrimary
            let knownBefore = self.knownAccounts
            self.lastPrimary = primaryId
            for (id, _, _) in accounts {
                self.knownAccounts.insert(id)
            }
            if let primaryId {
                self.knownAccounts.insert(primaryId)
            }
            guard let primaryId, let previous, primaryId != previous, let primary else {
                return
            }
            if self.grantedSwitch == primaryId {
                self.grantedSwitch = nil
                return
            }
            if !knownBefore.contains(primaryId) || !GGSecuritySettings.accountSwitchAuth.value {
                return
            }
            self.presentCover(context: primary)
        })
    }

    private func presentCover(context: AccountContext) {
        if self.cover != nil {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = GGLockCoverController(theme: presentationData.theme, title: GGStrings.Security.Accounts.coverTitle)
        controller.unlock = { [weak self, weak controller, weak context] in
            guard let context else {
                return
            }
            GGLocalAuthGate.shared.authenticate(context: context, reason: GGStrings.Security.Auth.reasonAccount, completion: { granted in
                if granted {
                    controller?.dismiss()
                    self?.cover = nil
                }
            })
        }
        self.cover = controller
        context.sharedContext.presentGlobalController(controller, nil)
        Queue.mainQueue().after(0.4, { [weak controller] in
            controller?.unlock?()
        })
    }
}
