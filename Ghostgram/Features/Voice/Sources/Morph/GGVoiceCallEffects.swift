import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramVoip
import TelegramCallsUI
import GGCore
import GGCallAudio
import GGVoiceDSP

/// The voice changer in calls, through the capture-effect slot of the call's own audio device
/// (`GGCallAudioEffects.setCaptureEffect`, W3-3 R6). No process-wide state and no tgcalls patch:
/// - parameters are per call and per account (the anonymous mode of the call's account wins);
/// - a call starts with a freshly built chain (empty delay lines, nothing of the previous call);
/// - the effect is taken off when the call ends and whenever the voice changer is switched off;
/// - changing a setting during a call installs a new chain at once;
/// - the realtime side is the C chain: no allocation, no lock, the block length never changes.
///
/// The 1:1 call and the group call can own the SAME device: a 1:1 call that grows into a conference
/// is published as the group call (`.conferenceSource`) before it stops being the current 1:1 call,
/// and a group call may reuse the finished call's context (`reuseCurrent`, which `reset()`s the
/// effects). So the two sides are never handled one by one: the devices that must carry the effect
/// are worked out from both, a device loses the effect only when neither wants it, and a new owner
/// call on the same device always gets a fresh chain.
final class GGVoiceCallEffectController {
    static let shared = GGVoiceCallEffectController()

    private struct Source {
        let effects: GGCallAudioEffects
        let account: GGAccountID
        /// The call that owns the device now.
        let call: ObjectIdentifier
    }

    private struct Target {
        let source: Source
        var appliedFingerprint: Data?
    }

    private var isStarted = false
    private let callDisposable = MetaDisposable()
    private let groupCallDisposable = MetaDisposable()
    private var settingsDisposable: Disposable?
    private var oneToOneSource: Source?
    private var groupSource: Source?
    /// Devices that carry an effect installed here (at most one per call kind).
    private var targets: [Target] = []

    private init() {
    }

    /// Main thread; idempotent.
    func start(sharedContext: SharedAccountContext) {
        if self.isStarted {
            return
        }
        guard let callManager = sharedContext.callManager else {
            return
        }
        self.isStarted = true
        self.callDisposable.set((callManager.currentCallSignal
        |> deliverOnMainQueue).start(next: { [weak self] call in
            self?.updateOneToOne(call)
        }))
        self.groupCallDisposable.set((callManager.currentGroupCallSignal
        |> deliverOnMainQueue).start(next: { [weak self] call in
            self?.updateGroup(call)
        }))
        self.settingsDisposable = (GGSettingsStore.shared.revision
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reapply()
        })
    }

    private func updateOneToOne(_ call: PresentationCall?) {
        var source: Source?
        if let callImpl = call as? PresentationCallImpl, let effects = callImpl.sharedAudioContext?.audioDevice?.ggAudioEffects {
            source = Source(effects: effects, account: callImpl.context.account.id.gg, call: ObjectIdentifier(callImpl))
        }
        self.oneToOneSource = source
        self.reconcile()
    }

    private func updateGroup(_ call: VideoChatCall?) {
        var source: Source?
        if let call {
            switch call {
            case let .group(groupCall):
                if let groupCallImpl = groupCall as? PresentationGroupCallImpl, let effects = groupCallImpl.ggAudioDevice?.ggAudioEffects {
                    source = Source(effects: effects, account: groupCall.accountContext.account.id.gg, call: ObjectIdentifier(groupCallImpl))
                }
            case let .conferenceSource(conferenceSource):
                if let callImpl = conferenceSource as? PresentationCallImpl, let effects = callImpl.sharedAudioContext?.audioDevice?.ggAudioEffects {
                    source = Source(effects: effects, account: conferenceSource.context.account.id.gg, call: ObjectIdentifier(callImpl))
                }
            }
        }
        self.groupSource = source
        self.reconcile()
    }

    /// Installs the effect on every device a current call owns and takes it off the devices no call
    /// owns any more. A device shared by both calls is listed once, the group side being its owner.
    private func reconcile() {
        var desired: [Source] = []
        if let groupSource = self.groupSource {
            desired.append(groupSource)
        }
        if let oneToOneSource = self.oneToOneSource, !desired.contains(where: { $0.effects === oneToOneSource.effects }) {
            desired.append(oneToOneSource)
        }
        for target in self.targets where !desired.contains(where: { $0.effects === target.source.effects }) {
            target.source.effects.setCaptureEffect(nil)
        }
        var updated: [Target] = []
        for source in desired {
            if var target = self.targets.first(where: { $0.source.effects === source.effects }), target.source.account == source.account, target.source.call == source.call {
                // Same device, same owner: only a changed setting rebuilds the chain.
                GGVoiceCallEffectController.apply(&target, force: false)
                updated.append(target)
            } else {
                // A new device, or a new owner of the device (it may have been reset for that call).
                var target = Target(source: source, appliedFingerprint: nil)
                GGVoiceCallEffectController.apply(&target, force: true)
                updated.append(target)
            }
        }
        self.targets = updated
    }

    private func reapply() {
        self.reconcile()
    }

    private static func apply(_ target: inout Target, force: Bool) {
        let effects = target.source.effects
        let params = GGVoicePresets.effectiveParams(scope: .calls, account: target.source.account)
        let fingerprint = GGVoicePresets.fingerprint(params)
        if !force && fingerprint == target.appliedFingerprint {
            return
        }
        target.appliedFingerprint = fingerprint
        guard let params else {
            effects.setCaptureEffect(nil)
            return
        }
        var chainParams = params
        guard let chain = GGVoiceChainCreate(&chainParams, 48000) else {
            // Out of memory for the chain: forget the fingerprint so the next pass tries again.
            target.appliedFingerprint = nil
            effects.setCaptureEffect(nil)
            return
        }
        // Configured here, off the audio thread; the core owns the chain from now on and releases it
        // (GGVoiceChainCallRelease) off the audio thread once it is replaced or removed.
        GGVoiceChainPrepare(chain, 48000)
        var effect = GGCallCaptureEffect(context: UnsafeMutableRawPointer(chain), process: GGVoiceChainCallProcess, release: GGVoiceChainCallRelease)
        effects.setCaptureEffect(&effect)
    }
}
