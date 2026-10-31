import Foundation
import UIKit
import AVKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramAudio
import AccountContext
import ContextUI
import AppBundle
import GGCore
import GGHooks

/// Gallery «…» items: «Скопировать фото» and «AirPlay».
///
/// AirPlay: upstream 13.0 removed it from the gallery together with its external player. That player
/// is not brought back; the item opens the system player (AVPlayerViewController) for the video file
/// that is already on the device, and the system's own AirPlay button does the rest.
enum GGGalleryTweaks {
    static func register() {
        GGGalleryHooks.menuItems.register({ menuContext in
            guard let message = menuContext.message else {
                return []
            }
            switch menuContext.kind {
            case .image:
                if GGCallsMediaSettings.copyPhotoItem.value, let item = GGGalleryTweaks.copyPhotoItem(context: menuContext.context, message: message) {
                    return [item]
                }
            case .video:
                if GGCallsMediaSettings.airPlayItem.value, let item = GGGalleryTweaks.airPlayItem(context: menuContext.context, message: message) {
                    return [item]
                }
            }
            return []
        })
    }

    private static func isProtected(_ message: Message) -> Bool {
        if message.isCopyProtected() || message.containsSecretMedia {
            return true
        }
        if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
            return true
        }
        for media in message.media {
            if media is TelegramMediaPaidContent {
                return true
            }
        }
        return false
    }

    // MARK: Copy photo

    private static func copyPhotoItem(context: AccountContext, message: Message) -> ContextMenuItem? {
        if GGGalleryTweaks.isProtected(message) {
            return nil
        }
        var image: TelegramMediaImage?
        for media in message.media {
            if let value = media as? TelegramMediaImage {
                image = value
                break
            }
        }
        guard let image = image, let representation = largestImageRepresentation(image.representations) else {
            return nil
        }
        let resource = representation.resource
        return .action(ContextMenuActionItem(text: GGStrings.Gallery.copyPhoto, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            let mediaBox = context.account.postbox.mediaBox
            // The full-size file, decoded off the main thread; not a snapshot of the screen.
            Queue.concurrentDefaultQueue().async {
                let loaded = mediaBox.completedResourcePath(resource).flatMap { UIImage(contentsOfFile: $0) }
                Queue.mainQueue().async {
                    if let loaded = loaded {
                        UIPasteboard.general.image = loaded
                        GGCallsMediaUI.toast(context: context, text: GGStrings.Gallery.photoCopied)
                    } else {
                        GGCallsMediaUI.toast(context: context, text: GGStrings.Gallery.photoNotLoaded)
                    }
                }
            }
        }))
    }

    // MARK: AirPlay

    private static func airPlayItem(context: AccountContext, message: Message) -> ContextMenuItem? {
        if GGGalleryTweaks.isProtected(message) {
            return nil
        }
        var file: TelegramMediaFile?
        for media in message.media {
            if let value = media as? TelegramMediaFile, value.isVideo, !value.isAnimated, !value.isInstantVideo {
                file = value
                break
            }
        }
        guard let file = file else {
            return nil
        }
        return .action(ContextMenuActionItem(text: GGStrings.Gallery.airPlay, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Media Gallery/AirPlay"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            let mediaBox = context.account.postbox.mediaBox
            Queue.concurrentDefaultQueue().async {
                // AVPlayer needs a file extension; the media box links one next to the cached file.
                let path = mediaBox.completedResourcePath(file.resource, pathExtension: "mp4")
                Queue.mainQueue().async {
                    guard let path = path else {
                        GGCallsMediaUI.toast(context: context, text: GGStrings.Gallery.videoNotLoaded)
                        return
                    }
                    let controller = GGSystemPlayerController(url: URL(fileURLWithPath: path), audioSession: context.sharedContext.mediaManager.audioSession)
                    GGCallsMediaUI.presentNative(controller)
                }
            }
        }))
    }
}

/// The system player with AirPlay. Holds a playback audio session of Telegram's audio session
/// manager while it is on screen, so other Telegram audio pauses and the session is handed back.
final class GGSystemPlayerController: AVPlayerViewController {
    private let audioSession: ManagedAudioSession
    private var audioSessionDisposable: Disposable?

    init(url: URL, audioSession: ManagedAudioSession) {
        self.audioSession = audioSession
        super.init(nibName: nil, bundle: nil)
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player
        self.modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.audioSessionDisposable?.dispose()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.audioSessionDisposable == nil {
            self.audioSessionDisposable = self.audioSession.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
                self?.player?.play()
            }, deactivate: { [weak self] _ in
                self?.player?.pause()
                return .complete()
            })
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if self.isBeingDismissed || self.presentingViewController == nil {
            self.player?.pause()
            self.audioSessionDisposable?.dispose()
            self.audioSessionDisposable = nil
        }
    }
}
