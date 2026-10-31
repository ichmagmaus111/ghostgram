import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import GGCore
import GGFeaturesShared
import GGCameraPipeline
import GGVoiceDSP

/// Owns one C voice chain. Not shared between threads: one owner processes with it.
final class GGVoiceChainBox {
    let chain: OpaquePointer

    init?(params: GGVoiceParams, maxSampleRate: UInt32) {
        var params = params
        guard let chain = GGVoiceChainCreate(&params, maxSampleRate) else {
            return nil
        }
        self.chain = chain
    }

    deinit {
        GGVoiceChainDestroy(self.chain)
    }
}

/// The voice changer inside the voice message recorder (`GGVoiceRecordingHooks.effect`): every 20 ms
/// block is changed before the waveform, the level meter and the Opus encoder see it, so the real voice
/// is never written and every way of sending gets the changed file — send at once, record → listen →
/// send, pause and continue, drafts, trimming, replies to stories, scheduled sending. Duration and
/// waveform are those of the changed sound because the recorder measures what it encodes.
final class GGVoiceRecorderEffect: GGVoiceRecordingEffect {
    /// nil: the chain could not be created (out of memory). The recorder then writes silence, never
    /// the real voice the user asked to change.
    private let box: GGVoiceChainBox?

    init(params: GGVoiceParams) {
        let box = GGVoiceChainBox(params: params, maxSampleRate: 48000)
        if let box {
            GGVoiceChainPrepare(box.chain, 48000)
        }
        self.box = box
    }

    func process(_ samples: UnsafeMutablePointer<Int16>, count: Int, sampleRate: Int) {
        guard let box = self.box else {
            samples.update(repeating: 0, count: count)
            return
        }
        GGVoiceChainProcessInt16(box.chain, samples, count, 1, UInt32(max(8000, sampleRate)))
    }
}

/// The voice changer as a round video audio stage (`GGCameraHooks.roundVideoAudioStage`, W3-2 R3). The
/// chain is created on the first block, on the pipeline's queue: the hook is also asked with a nominal
/// format just to learn whether processing is needed, and that must stay cheap.
final class GGVoiceRoundVideoStage: GGRoundVideoAudioStage {
    private let params: GGVoiceParams
    private let format: GGRoundVideoAudioFormat
    private var box: GGVoiceChainBox?
    private var failed = false

    init(params: GGVoiceParams, format: GGRoundVideoAudioFormat) {
        self.params = params
        self.format = format
    }

    var hasFailed: Bool {
        return self.failed
    }

    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        if self.box == nil && !self.failed {
            let sampleRate = UInt32(max(8000.0, min(96000.0, self.format.sampleRate)))
            self.box = GGVoiceChainBox(params: self.params, maxSampleRate: sampleRate)
            self.failed = self.box == nil
        }
        guard let box = self.box else {
            // No chain: silence, and the processor refuses the clip (`hasFailed`).
            samples.update(repeating: 0.0, count: frameCount * max(1, self.format.channelCount))
            return
        }
        GGVoiceChainProcessFloat(box.chain, samples, frameCount, max(1, self.format.channelCount), UInt32(max(8000.0, self.format.sampleRate)))
    }
}

/// The account the UI works with now: voice messages are recorded from the primary account's chats
/// (the chat and the story reply both use it). Atomic: the recorder asks on its own queue.
final class GGVoiceAccounts {
    static let shared = GGVoiceAccounts()

    private let primaryAccount = Atomic<GGAccountID?>(value: nil)
    private(set) var contexts: [AccountRecordId: AccountContext] = [:]
    private var disposable: Disposable?
    private var isStarted = false

    var primary: GGAccountID? {
        return self.primaryAccount.with { $0 }
    }

    /// Main thread; idempotent. Called from `GGLifecycleHooks.rootControllersDidLoad`.
    func start(sharedContext: SharedAccountContext) {
        if self.isStarted {
            return
        }
        self.isStarted = true
        self.disposable = (sharedContext.activeAccountContexts
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else {
                return
            }
            let _ = self.primaryAccount.swap(value.primary?.account.id.gg)
            var contexts: [AccountRecordId: AccountContext] = [:]
            for (id, context, _) in value.accounts {
                contexts[id] = context
            }
            self.contexts = contexts
        })
    }

    func context(for account: AccountRecordId) -> AccountContext? {
        return self.contexts[account]
    }
}

enum GGVoiceMorphHooks {
    static func register() {
        GGVoiceRecordingHooks.effect.register({
            guard let params = GGVoicePresets.effectiveParams(scope: .voiceMessages, account: GGVoiceAccounts.shared.primary) else {
                return nil
            }
            return GGVoiceRecorderEffect(params: params)
        }, order: 100)

        GGCameraHooks.roundVideoAudioStage.register({ format in
            guard let params = GGVoicePresets.effectiveParams(scope: .roundVideos, account: format.accountId) else {
                return nil
            }
            return GGVoiceRoundVideoStage(params: params, format: format)
        }, order: 100)
    }
}
