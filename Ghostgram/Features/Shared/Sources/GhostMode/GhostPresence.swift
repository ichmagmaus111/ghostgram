import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import GGCore

/// What decides the account's "online" signal besides the settings: the chat open on screen (an
/// exception that shows online while it is open) and the short window opened for an allowed activity
/// status (the server relays «печатает» only from an account it sees online). One signal per account,
/// recomputed on changes — no polling, no timer while nothing is pending (the only timer is the
/// one-shot end of the activity window).
public final class GGGhostPresence {
    public static let shared = GGGhostPresence()

    /// Length of the online window opened for an allowed activity status, extended while it repeats.
    public static let activityWindow: Double = 6.0

    private struct AccountState {
        var activeChat: PeerId?
        var windowUntil: Double = 0.0
        /// Chats an activity was actually sent to: only they get the "activity ended" update.
        var sentActivityPeers: Set<PeerId> = []
    }

    private let state = Atomic<[GGAccountID: AccountState]>(value: [:])
    private let revision = ValuePromise<Int>(0, ignoreRepeated: false)
    private let revisionCounter = Atomic<Int>(value: 0)

    // Main queue only.
    private var windowTimers: [GGAccountID: SwiftSignalKit.Timer] = [:]

    private init() {
    }

    private func bump() {
        let value = self.revisionCounter.modify { $0 &+ 1 }
        self.revision.set(value)
    }

    // MARK: Accounts

    func accountWillBeRemoved(_ account: GGAccountID) {
        let _ = self.state.modify { current in
            var current = current
            current.removeValue(forKey: account)
            return current
        }
        Queue.mainQueue().async {
            self.windowTimers.removeValue(forKey: account)?.invalidate()
        }
    }

    // MARK: The chat on screen

    /// The chat screen of `peerId` is on top (nil: no chat is). Main thread.
    public func setActiveChat(_ peerId: PeerId?, account: GGAccountID) {
        var changed = false
        let _ = self.state.modify { current in
            var current = current
            var accountState = current[account] ?? AccountState()
            if accountState.activeChat != peerId {
                accountState.activeChat = peerId
                changed = true
            }
            current[account] = accountState
            return current
        }
        if changed {
            self.bump()
        }
    }

    public func activeChat(account: GGAccountID) -> PeerId? {
        return self.state.with { $0[account]?.activeChat }
    }

    /// The exceptions changed while a chat is open: recompute "online" at once (adding the open chat
    /// to the exceptions shows the account online without leaving and re-entering it).
    public func exceptionsDidChange() {
        self.bump()
    }

    // MARK: Activity window

    public func isWindowOpen(account: GGAccountID) -> Bool {
        let until = self.state.with { $0[account]?.windowUntil ?? 0.0 }
        return until > Date().timeIntervalSince1970
    }

    /// Opens or extends the online window for an allowed activity status.
    public func openWindow(account: GGAccountID) {
        let until = Date().timeIntervalSince1970 + GGGhostPresence.activityWindow
        var wasOpen = false
        let _ = self.state.modify { current in
            var current = current
            var accountState = current[account] ?? AccountState()
            wasOpen = accountState.windowUntil > Date().timeIntervalSince1970
            accountState.windowUntil = until
            current[account] = accountState
            return current
        }
        Queue.mainQueue().async { [weak self] in
            guard let self else {
                return
            }
            self.windowTimers.removeValue(forKey: account)?.invalidate()
            let timer = SwiftSignalKit.Timer(timeout: GGGhostPresence.activityWindow + 0.1, repeat: false, completion: { [weak self] in
                guard let self = self else {
                    return
                }
                self.windowTimers.removeValue(forKey: account)
                self.bump()
            }, queue: Queue.mainQueue())
            self.windowTimers[account] = timer
            timer.start()
        }
        if !wasOpen {
            self.bump()
        }
    }

    func noteActivitySent(to peerId: PeerId, account: GGAccountID) {
        let _ = self.state.modify { current in
            var current = current
            var accountState = current[account] ?? AccountState()
            accountState.sentActivityPeers.insert(peerId)
            current[account] = accountState
            return current
        }
    }

    /// Whether an "activity ended" update for the chat may go out: only after a sent activity.
    func takeActivityEnd(for peerId: PeerId, account: GGAccountID) -> Bool {
        var result = false
        let _ = self.state.modify { current in
            var current = current
            guard var accountState = current[account] else {
                return current
            }
            result = accountState.sentActivityPeers.remove(peerId) != nil
            current[account] = accountState
            return current
        }
        return result
    }

    // MARK: The online signal

    /// The value the account's presence manager should follow.
    public func resolvedOnline(_ upstream: Bool, account: GGAccountID) -> Bool {
        if GGGhostPolicy.isFunctionOn(.online, account: account) {
            if let peerId = self.activeChat(account: account), !GGGhostPolicy.hides(.online, peerId: peerId, account: account) {
                return upstream
            }
            if self.isWindowOpen(account: account) {
                return upstream
            }
            return false
        }
        // Ghost mode outranks «Вечный онлайн» (the menu says so next to the switch).
        if GGGhostSettings.alwaysOnline.value(for: account) {
            return true
        }
        return upstream
    }

    func transformOnline(_ upstream: Signal<Bool, NoError>, account: GGAccountID) -> Signal<Bool, NoError> {
        return combineLatest(upstream, GGSettingsStore.shared.revision, self.revision.get())
        |> map { [weak self] value, _, _ -> Bool in
            guard let self = self else {
                return value
            }
            return self.resolvedOnline(value, account: account)
        }
        |> distinctUntilChanged
    }
}
