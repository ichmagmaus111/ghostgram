import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences
import GGCore
import GGFeaturesShared

/// «Не останавливать музыку при записи ГС и кружков» is upstream's own Data & Storage switch
/// («Pause Music While Recording», inverted), not a second setting: the row writes upstream, and the
/// mirror `voice.keepMusicMirror` only follows upstream so the menu redraws when Data & Storage changes it.
/// Upstream is read first: a stale mirror can never overwrite it at launch.
final class GGVoiceKeepMusic {
    static let shared = GGVoiceKeepMusic()

    private var upstreamDisposable: Disposable?
    private var mirrorDisposable: Disposable?
    private var upstreamPause: Bool?

    func start(sharedContext: SharedAccountContext) {
        if self.upstreamDisposable != nil {
            return
        }
        let accountManager = sharedContext.accountManager
        self.upstreamDisposable = (accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.mediaInputSettings])
        |> map { sharedData -> Bool in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.mediaInputSettings]?.get(MediaInputSettings.self) ?? MediaInputSettings.defaultSettings
            return settings.pauseMusicOnRecording
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] pause in
            guard let self else {
                return
            }
            self.upstreamPause = pause
            if GGVoiceSettings.keepMusicMirror.value != !pause {
                GGVoiceSettings.keepMusicMirror.set(!pause)
            }
        })
        self.mirrorDisposable = (GGVoiceSettings.keepMusicMirror.signal
        |> deliverOnMainQueue).start(next: { [weak self] keep in
            guard let self, let upstreamPause = self.upstreamPause else {
                return
            }
            if upstreamPause == keep {
                self.upstreamPause = !keep
                let _ = updateMediaInputSettingsInteractively(accountManager: accountManager, { settings in
                    return settings.withUpdatedPauseMusicOnRecording(!keep)
                }).start()
            }
        })
    }
}
