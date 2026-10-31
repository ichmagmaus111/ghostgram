import Foundation
import UIKit
import LocalAuthentication
import Display
import TelegramCore
import AccountContext
import PresentationDataUtils
import PasscodeCore
import PasscodeUI
import GGCore

/// One check for everything in «Безопасность» (protected chats, the secret folder, switching
/// accounts, the «Безопасность» menu itself, export / import / reset of the settings):
///
/// 1. a Telegram passcode is set → Face ID / Touch ID if Telegram itself unlocks with them and the
///    enrollment did not change since Telegram last saw it, then — on any refusal, cancel or a new
///    finger / face — Telegram's own passcode keypad (never a dead end);
/// 2. no Telegram passcode → the device's owner check (Face ID / Touch ID with the device passcode);
/// 3. neither → nothing can be checked: the request goes through, but never silently — the user is
///    told once per check that the protection needs a passcode.
///
/// `LAContext` probes run on a background queue; only the prompts themselves are started from main.
final class GGLocalAuthGate {
    static let shared = GGLocalAuthGate()

    private var isRunning = false

    /// Main thread. `completion(true)` once access is granted, `false` when it was refused or
    /// cancelled; always on the main thread, exactly once. A second request while one is on screen
    /// is refused.
    func authenticate(context: AccountContext, reason: String, completion: @escaping (Bool) -> Void) {
        assert(Thread.isMainThread)
        if self.isRunning {
            completion(false)
            return
        }
        self.isRunning = true
        let finish: (Bool) -> Void = { [weak self] granted in
            self?.isRunning = false
            completion(granted)
        }
        let environment = GGAuthEnvironment.shared.state
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = GGAuthEnvironment.probeDevice()
            DispatchQueue.main.async {
                if environment.hasTelegramPasscode {
                    var useBiometrics = probe.canUseBiometrics && environment.telegramBiometrics
                    if let saved = environment.telegramDomainState, let current = probe.domainState, saved != current {
                        // A new finger or face since Telegram last saw the enrollment: the code only.
                        useBiometrics = false
                    }
                    if useBiometrics {
                        GGLocalAuthGate.evaluate(policy: .deviceOwnerAuthenticationWithBiometrics, reason: reason, completion: { granted in
                            if granted {
                                finish(true)
                            } else {
                                GGLocalAuthGate.askTelegramPasscode(context: context, completion: finish)
                            }
                        })
                    } else {
                        GGLocalAuthGate.askTelegramPasscode(context: context, completion: finish)
                    }
                } else if probe.hasDevicePasscode {
                    GGLocalAuthGate.evaluate(policy: .deviceOwnerAuthentication, reason: reason, completion: finish)
                } else {
                    GGLocalAuthGate.presentNoPasscodeNotice(context: context, completion: {
                        finish(true)
                    })
                }
            }
        }
    }

    /// The biometric / device-owner prompt; the reply comes back on main.
    private static func evaluate(policy: LAPolicy, reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = GGStrings.Security.Auth.enterPasscode
        context.evaluatePolicy(policy, localizedReason: reason, reply: { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        })
    }

    /// Telegram's passcode keypad; the session it issues authorizes nothing here and is dropped at once.
    private static func askTelegramPasscode(context: AccountContext, completion: @escaping (Bool) -> Void) {
        var completed = false
        let controller = passcodeAuthenticationController(context: context, scope: .resource(namespace: "ghostgram.security"), completion: { result in
            if completed {
                if case let .success(session) = result {
                    session.invalidate()
                }
                return
            }
            completed = true
            switch result {
            case let .success(session):
                session.invalidate()
                completion(true)
            case .failure:
                completion(false)
            }
        })
        if let controller {
            context.sharedContext.presentGlobalController(controller, nil)
        }
    }

    private static func presentNoPasscodeNotice(context: AccountContext, completion: @escaping () -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let alert = textAlertController(context: context, title: GGStrings.Security.Auth.noPasscodeTitle, text: GGStrings.Security.Auth.noPasscodeText, actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {
                completion()
            })
        ], dismissOnOutsideTap: false)
        context.sharedContext.presentGlobalController(alert, nil)
    }
}
