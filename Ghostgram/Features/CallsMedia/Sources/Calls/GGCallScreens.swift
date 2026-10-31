import Foundation
import UIKit
import AVFoundation
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramAudio
import AccountContext
import PresentationDataUtils
import PromptUI
import GGCore
import GGSettingsUI

// MARK: - Sounds

/// «Звуки в звонке › Библиотека»: add a sound from Files or from a video in Photos, listen, rename,
/// delete. The files stay in the container; the list is the registry's metadata.
func ggMakeSoundLibraryScreen(menuContext: GGMenuContext) -> ViewController {
    let context = menuContext.context
    return ggMakeMediaListScreen(context: context, content: {
        let items = GGCallSoundLibrary.shared.items.map { item in
            return GGMediaListItem(id: item.id, title: item.title)
        }
        return GGMediaListContent(title: GGStrings.Calls.Sounds.title, actions: [
            GGMediaListAction(id: "files", title: GGStrings.Calls.Sounds.addFromFiles, action: {
                GGSoundImport.pickFromFiles(context: context)
            }),
            GGMediaListAction(id: "photos", title: GGStrings.Calls.Sounds.addFromVideo, action: {
                GGSoundImport.pickVideo(context: context)
            })
        ], emptyText: GGStrings.Calls.Sounds.empty, footer: GGStrings.Calls.Sounds.footer, items: items)
    }, select: { id in
        guard let item = GGCallsMediaSettings.soundboardItems.value.first(where: { $0.id == id }) else {
            return
        }
        ggPresentMediaActionSheet(context: context, title: item.title, actions: [
            (GGStrings.Calls.Sounds.listen, false, {
                GGSoundPreviewPlayer.shared.play(item, audioSession: context.sharedContext.mediaManager.audioSession)
            }),
            (GGStrings.Calls.Sounds.rename, false, {
                menuContext.present(promptController(context: context, text: GGStrings.Calls.Sounds.renamePrompt, value: item.title, characterLimit: 64, apply: { value in
                    if let value = value {
                        GGCallSoundLibrary.shared.rename(item, title: value)
                    }
                }))
            }),
            (GGStrings.Calls.Sounds.delete, true, {
                GGSoundPreviewPlayer.shared.stop()
                GGCallSoundLibrary.shared.delete(item)
            })
        ], present: { menuContext.present($0) })
    })
}

/// Pickers for new sounds. Each delegate lives as long as its picker.
private enum GGSoundImport {
    private static var delegateKey: UInt8 = 0

    static func pickFromFiles(context: AccountContext) {
        let types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .movie, .mpeg4Movie, .quickTimeMovie]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = GGSoundDocumentDelegate(context: context)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &GGSoundImport.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        GGCallsMediaUI.presentNative(picker)
    }

    static func pickVideo(context: AccountContext) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = GGSoundVideoPickerDelegate(context: context)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &GGSoundImport.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        GGCallsMediaUI.presentNative(picker)
    }

    static func finish(context: AccountContext, url: URL, title: String?, removeSource: Bool) {
        GGCallSoundLibrary.shared.importFile(at: url, suggestedTitle: title, completion: { item in
            if removeSource {
                try? FileManager.default.removeItem(at: url)
            }
            GGCallsMediaUI.toast(context: context, text: item == nil ? GGStrings.Calls.Sounds.importFailed : GGStrings.Calls.Sounds.imported)
        })
    }
}

private final class GGSoundDocumentDelegate: NSObject, UIDocumentPickerDelegate {
    private let context: AccountContext

    init(context: AccountContext) {
        self.context = context
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            return
        }
        GGSoundImport.finish(context: self.context, url: url, title: url.deletingPathExtension().lastPathComponent, removeSource: true)
    }
}

private final class GGSoundVideoPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    private let context: AccountContext

    init(context: AccountContext) {
        self.context = context
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else {
            return
        }
        let context = self.context
        let title = result.itemProvider.suggestedName
        result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier, completionHandler: { url, _ in
            guard let url = url else {
                Queue.mainQueue().async {
                    GGCallsMediaUI.toast(context: context, text: GGStrings.Calls.Sounds.importFailed)
                }
                return
            }
            // The provider's file is deleted when this handler returns: keep a copy until imported.
            let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                Queue.mainQueue().async {
                    GGCallsMediaUI.toast(context: context, text: GGStrings.Calls.Sounds.importFailed)
                }
                return
            }
            Queue.mainQueue().async {
                GGSoundImport.finish(context: context, url: copy, title: title, removeSource: true)
            }
        })
    }
}

/// «Прослушать» in the library: plays a sound locally through Telegram's audio session manager.
final class GGSoundPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = GGSoundPreviewPlayer()

    private var player: AVAudioPlayer?
    private var audioSessionDisposable: Disposable?

    func play(_ item: GGCallSoundItem, audioSession: ManagedAudioSession) {
        self.stop()
        guard let url = GGCallSoundLibrary.url(for: item), let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }
        player.delegate = self
        self.player = player
        self.audioSessionDisposable = audioSession.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
            self?.player?.play()
        }, deactivate: { [weak self] _ in
            self?.player?.stop()
            return .complete()
        })
    }

    func stop() {
        self.player?.stop()
        self.player = nil
        self.audioSessionDisposable?.dispose()
        self.audioSessionDisposable = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === self.player {
            self.stop()
        }
    }
}

// MARK: - Recordings

/// «Записи звонков» of the menu's account: play, share, send to Saved Messages, delete. Nothing
/// leaves the device unless one of these buttons is pressed.
func ggMakeCallRecordingsScreen(menuContext: GGMenuContext) -> ViewController {
    let context = menuContext.context
    let accountId = menuContext.accountID
    let basePath = context.account.basePath
    return ggMakeMediaListScreen(context: context, content: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: presentationData.strings.baseLanguageCode)
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let items = GGCallsMediaSettings.recordings.value(for: accountId).map { item -> GGMediaListItem in
            let title = item.peerTitle.isEmpty ? GGStrings.Calls.Recordings.unknownPeer : item.peerTitle
            let kind = item.kind == .video ? GGStrings.Calls.Recordings.video : GGStrings.Calls.Recordings.audio
            let label = GGStrings.Calls.Recordings.itemLabel(kind: kind, date: formatter.string(from: Date(timeIntervalSince1970: item.startDate)), duration: GGCallsMediaUI.durationText(item.duration), size: GGCallsMediaUI.sizeText(item.size))
            return GGMediaListItem(id: item.id, title: title, label: label)
        }
        return GGMediaListContent(title: GGStrings.Calls.Recordings.title, actions: [], emptyText: GGStrings.Calls.Recordings.empty, footer: GGStrings.Calls.Recordings.footer, items: items)
    }, select: { id in
        guard let item = GGCallsMediaSettings.recordings.value(for: accountId).first(where: { $0.id == id }) else {
            return
        }
        let url = GGCallRecordingStorage.url(basePath: basePath, item: item)
        ggPresentMediaActionSheet(context: context, title: nil, actions: [
            (GGStrings.Calls.Recordings.play, false, {
                GGCallsMediaUI.presentNative(GGSystemPlayerController(url: url, audioSession: context.sharedContext.mediaManager.audioSession))
            }),
            (GGStrings.Calls.Recordings.share, false, {
                GGCallsMediaUI.presentNative(UIActivityViewController(activityItems: [url], applicationActivities: nil))
            }),
            (GGStrings.Calls.Recordings.sendToSaved, false, {
                GGCallRecordingsActions.sendToSavedMessages(context: context, item: item, url: url)
            }),
            (GGStrings.Calls.Recordings.delete, true, {
                GGCallRecordingsActions.delete(item, accountId: accountId, url: url)
            })
        ], present: { menuContext.present($0) })
    })
}

enum GGCallRecordingsActions {
    /// Explicit user action only: the file goes to the account's own Saved Messages.
    static func sendToSavedMessages(context: AccountContext, item: GGCallRecordingItem, url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            GGCallsMediaUI.toast(context: context, text: GGStrings.Calls.Recordings.missing)
            return
        }
        let id = Int64.random(in: Int64.min ... Int64.max)
        let title = item.peerTitle.isEmpty ? GGStrings.Calls.Recordings.unknownPeer : item.peerTitle
        var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: url.lastPathComponent)]
        let mimeType: String
        switch item.kind {
        case .audio:
            mimeType = "audio/mp4"
            attributes.append(.Audio(isVoice: false, duration: Int(item.duration.rounded()), title: title, performer: nil, waveform: nil))
        case .video:
            mimeType = "video/mp4"
            attributes.append(.Video(duration: item.duration, size: PixelDimensions(width: Int32(GGCallRecorder.videoSize.width), height: Int32(GGCallRecorder.videoSize.height)), flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil))
        }
        let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: LocalFileReferenceMediaResource(localFilePath: url.path, randomId: id, isUniquelyReferencedTemporaryFile: false, size: item.size), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType, size: item.size, attributes: attributes, alternativeRepresentations: [])
        let message: EnqueueMessage = .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let _ = enqueueMessages(account: context.account, peerId: context.account.peerId, messages: [message]).start()
        GGCallsMediaUI.toast(context: context, text: GGStrings.Calls.Recordings.sent)
    }

    static func delete(_ item: GGCallRecordingItem, accountId: GGAccountID, url: URL) {
        var items = GGCallsMediaSettings.recordings.value(for: accountId)
        items.removeAll(where: { $0.id == item.id })
        GGCallsMediaSettings.recordings.set(items, for: accountId)
        Queue.concurrentDefaultQueue().async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
