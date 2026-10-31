import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import GGCore
import GGFeaturesShared

/// What the camera features of calls need to know about the calls in progress, without a call
/// screen: the account of the call (its anonymous mode decides the mask, also for a call answered
/// from the lock screen) and whether a call is sending its own video (the virtual camera stops
/// decoding once the user turned the camera off). Watches the calls only while masks in calls, the
/// virtual camera or an anonymous mode is on. Main thread.
final class GGCameraCallsMonitor {
    static let shared = GGCameraCallsMonitor()

    private var isStarted = false
    private let callsDisposable = MetaDisposable()
    private var neededDisposable: Disposable?

    private init() {
    }

    /// Idempotent; from `GGLifecycleHooks.rootControllersDidLoad`.
    func start(sharedContext: SharedAccountContext) {
        assert(Thread.isMainThread)
        if self.isStarted {
            return
        }
        guard let callManager = sharedContext.callManager else {
            return
        }
        self.isStarted = true
        let needed: Signal<Bool, NoError> = GGSettingsStore.shared.revision
        |> map { _ -> Bool in
            return GGCameraCallsMonitor.isNeeded
        }
        |> distinctUntilChanged
        self.neededDisposable = (needed |> deliverOnMainQueue).start(next: { [weak self] isNeeded in
            guard let self else {
                return
            }
            if isNeeded {
                self.watch(callManager: callManager)
            } else {
                self.callsDisposable.set(nil)
                // No call is watched: unknown, so nothing idles by mistake.
                GGVirtualCameraFeeder.setLocalVideoSending(nil)
            }
        })
    }

    private static var isNeeded: Bool {
        if GGVirtualCameraSettings.enabled.value || GGMaskSettings.inCalls.value {
            return true
        }
        return GGSettingsStore.shared.registeredAccounts.contains(where: { GGAnonymousMode.isActive.value(for: $0) })
    }

    private func watch(callManager: PresentationCallManager) {
        let oneToOne: Signal<(GGAccountID?, Bool), NoError> = callManager.currentCallSignal
        |> mapToSignal { call -> Signal<(GGAccountID?, Bool), NoError> in
            guard let call else {
                return .single((nil, false))
            }
            let account = call.context.account.id.gg
            return call.state
            |> map { state -> (GGAccountID?, Bool) in
                return (account, GGCameraCallsMonitor.isSendingVideo(state))
            }
        }
        let group: Signal<(GGAccountID?, Bool), NoError> = callManager.currentGroupCallSignal
        |> mapToSignal { call -> Signal<(GGAccountID?, Bool), NoError> in
            guard let call else {
                return .single((nil, false))
            }
            switch call {
            case let .group(groupCall):
                let account = groupCall.accountContext.account.id.gg
                return groupCall.state
                |> map { state -> (GGAccountID?, Bool) in
                    return (account, state.isMyVideoActive)
                }
            case let .conferenceSource(source):
                let account = source.context.account.id.gg
                return source.state
                |> map { state -> (GGAccountID?, Bool) in
                    return (account, GGCameraCallsMonitor.isSendingVideo(state))
                }
            }
        }
        self.callsDisposable.set((combineLatest(oneToOne, group)
        |> deliverOnMainQueue).start(next: { oneToOne, group in
            if let account = group.0 ?? oneToOne.0 {
                GGCallMasks.shared.currentAccount = account
            }
            GGVirtualCameraFeeder.setLocalVideoSending(oneToOne.1 || group.1)
        }))
    }

    private static func isSendingVideo(_ state: PresentationCallState) -> Bool {
        switch state.state {
        case .terminating, .terminated:
            return false
        default:
            break
        }
        switch state.videoState {
        case .active, .paused:
            return true
        case .inactive, .notAvailable:
            return false
        }
    }
}
