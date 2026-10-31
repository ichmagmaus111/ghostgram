import Foundation
import AccountContext
import TelegramAudio
import GGCore
import GGHooks
import GGFeaturesShared

/// Entry point of the GGVoice feature module. Owner: W3-1.
public enum GGVoiceModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        // Settings are declared by GGVoiceShared (GGFeaturesShared): upstream modules read them.
        GGVoiceMigrations.register()
        GGVoiceMenu.register()

        // The voice changer: recorder (voice messages), round video audio stage, calls.
        GGVoiceMorphHooks.register()
        // «Всегда встроенный микрофон» (SG-F3), read by ManagedAudioSession while recording.
        GGAudioSessionHooks.prefersBuiltInMicrophoneForRecording.register({
            return GGVoiceSettings.builtInMicrophone.value
        }, order: 100)
        // Auto-transcription of own voice messages and round videos.
        GGAutoTranscription.register()

        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            let sharedContext = context.sharedContext
            GGVoiceAccounts.shared.start(sharedContext: sharedContext)
            GGVoiceCallEffectController.shared.start(sharedContext: sharedContext)
            GGVoiceKeepMusic.shared.start(sharedContext: sharedContext)
        }, order: 300)

        // Publishes the playback equalizer's parameters (one subscription for the process).
        GGVoiceEqualizer.start()
    }
}
