import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import AppBundle
import UniversalMediaPlayer
import GGCore
import GGHooks

/// «Субтитры к видео»: «…» of a gallery video → «Показать субтитры». The line is drawn over the
/// video and follows the player's own status: it changes on the cue boundaries while the video
/// plays and nothing ticks while it is paused.
enum GGSubtitlesFeature {
    static func register() {
        GGGalleryHooks.menuItems.register({ menuContext in
            guard GGCallsMediaSettings.subtitles.value, menuContext.kind == .video, let message = menuContext.message else {
                return []
            }
            guard let controller = GGSubtitlesItemController.controller(for: message.id) else {
                return []
            }
            let isActive = controller.isActive
            return [.action(ContextMenuActionItem(text: isActive ? GGStrings.Subtitles.hide : GGStrings.Subtitles.show, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                controller.toggle()
            }))]
        })
    }

    /// From the gallery point (`Sources/Pending`): a video item got its player.
    static func videoItemDidLoad(context: AccountContext, message: Message?, file: TelegramMediaFile?, itemNode: ASDisplayNode, status: Signal<MediaPlayerStatus?, NoError>) {
        guard let message = message, let file = file else {
            GGSubtitlesItemController.existing(on: itemNode)?.detach()
            return
        }
        let controller = GGSubtitlesItemController.attached(to: itemNode)
        controller.update(context: context, message: message, file: file, status: status)
    }

    /// From the gallery point: the item was laid out (size, the space the controls take at the bottom).
    static func videoItemDidLayout(itemNode: ASDisplayNode, size: CGSize, bottomInset: CGFloat, transition: ContainedViewLayoutTransition) {
        GGSubtitlesItemController.existing(on: itemNode)?.updateLayout(size: size, bottomInset: bottomInset, transition: transition)
    }
}

private var ggSubtitlesControllerKey: UInt8 = 0

/// Subtitles of one gallery video item. Lives as long as the item node.
final class GGSubtitlesItemController {
    private static var live: [WeakBox] = []

    private final class WeakBox {
        weak var controller: GGSubtitlesItemController?

        init(_ controller: GGSubtitlesItemController) {
            self.controller = controller
        }
    }

    static func attached(to itemNode: ASDisplayNode) -> GGSubtitlesItemController {
        if let existing = GGSubtitlesItemController.existing(on: itemNode) {
            return existing
        }
        let controller = GGSubtitlesItemController(itemNode: itemNode)
        objc_setAssociatedObject(itemNode, &ggSubtitlesControllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        GGSubtitlesItemController.live = GGSubtitlesItemController.live.filter { $0.controller != nil }
        GGSubtitlesItemController.live.append(WeakBox(controller))
        return controller
    }

    static func existing(on itemNode: ASDisplayNode) -> GGSubtitlesItemController? {
        return objc_getAssociatedObject(itemNode, &ggSubtitlesControllerKey) as? GGSubtitlesItemController
    }

    static func controller(for messageId: MessageId) -> GGSubtitlesItemController? {
        for box in GGSubtitlesItemController.live {
            if let controller = box.controller, controller.message?.id == messageId {
                return controller
            }
        }
        return nil
    }

    private weak var itemNode: ASDisplayNode?
    private var context: AccountContext?
    private(set) var message: Message?
    private var file: TelegramMediaFile?
    private var statusSignal: Signal<MediaPlayerStatus?, NoError>?

    private(set) var isActive = false
    private var track: GGSubtitleTrack?
    private var status: MediaPlayerStatus?

    private let overlayNode = GGSubtitleOverlayNode()
    private let trackDisposable = MetaDisposable()
    private let statusDisposable = MetaDisposable()
    private var boundaryTimer: SwiftSignalKit.Timer?
    private var layout: (size: CGSize, bottomInset: CGFloat)?

    private init(itemNode: ASDisplayNode) {
        self.itemNode = itemNode
    }

    deinit {
        self.trackDisposable.dispose()
        self.statusDisposable.dispose()
        self.boundaryTimer?.invalidate()
    }

    func update(context: AccountContext, message: Message, file: TelegramMediaFile, status: Signal<MediaPlayerStatus?, NoError>) {
        let sameMedia = self.message?.id == message.id && self.file?.fileId == file.fileId
        self.context = context
        self.message = message
        self.file = file
        self.statusSignal = status
        if !sameMedia {
            self.deactivate()
        } else if self.isActive {
            self.subscribeStatus()
        }
    }

    func detach() {
        self.deactivate()
        self.message = nil
        self.file = nil
        self.statusSignal = nil
    }

    func toggle() {
        if self.isActive {
            self.deactivate()
        } else {
            self.activate()
        }
    }

    func updateLayout(size: CGSize, bottomInset: CGFloat, transition: ContainedViewLayoutTransition) {
        self.layout = (size, bottomInset)
        self.overlayNode.updateLayout(size: size, bottomInset: bottomInset, transition: transition)
    }

    private func activate() {
        guard let context = self.context, let message = self.message, let file = self.file, let itemNode = self.itemNode else {
            return
        }
        self.isActive = true
        if self.overlayNode.supernode == nil {
            itemNode.addSubnode(self.overlayNode)
        }
        if let layout = self.layout {
            self.overlayNode.updateLayout(size: layout.size, bottomInset: layout.bottomInset, transition: .immediate)
        }
        self.overlayNode.setText(GGStrings.Subtitles.recognizing, isStatus: true)
        self.trackDisposable.set((GGSubtitlesEngine.shared.track(context: context, message: message, file: file)
        |> deliverOnMainQueue).start(next: { [weak self] track in
            guard let strongSelf = self, strongSelf.isActive else {
                return
            }
            strongSelf.track = track
            if track.isTimingEstimated {
                GGCallsMediaUI.toast(context: context, text: GGStrings.Subtitles.estimatedTiming)
            }
            strongSelf.subscribeStatus()
        }, error: { [weak self] error in
            guard let strongSelf = self else {
                return
            }
            strongSelf.deactivate()
            let text: String
            switch error {
            case .noAudio:
                text = GGStrings.Subtitles.noAudio
            case .noPermission:
                text = GGStrings.Subtitles.noPermission
            case .notRecognized:
                text = GGStrings.Subtitles.failed
            case .cancelled:
                return
            }
            GGCallsMediaUI.toast(context: context, text: text)
        }))
    }

    private func deactivate() {
        self.isActive = false
        self.track = nil
        self.status = nil
        self.trackDisposable.set(nil)
        self.statusDisposable.set(nil)
        self.boundaryTimer?.invalidate()
        self.boundaryTimer = nil
        self.overlayNode.setText(nil, isStatus: false)
        self.overlayNode.removeFromSupernode()
    }

    private func subscribeStatus() {
        guard let statusSignal = self.statusSignal, self.track != nil else {
            return
        }
        self.statusDisposable.set((statusSignal
        |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let strongSelf = self else {
                return
            }
            strongSelf.status = status
            strongSelf.refresh()
        }))
    }

    /// Shows the line for the current position and, while playing, schedules the next refresh at
    /// the next cue boundary — one timer per change of the line, none while paused.
    private func refresh() {
        self.boundaryTimer?.invalidate()
        self.boundaryTimer = nil
        guard let track = self.track else {
            return
        }
        guard let status = self.status else {
            self.overlayNode.setText(nil, isStatus: false)
            return
        }
        var position = status.timestamp
        let isPlaying: Bool
        if case .playing = status.status {
            isPlaying = true
            position += max(0.0, CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
        } else {
            isPlaying = false
        }
        if let index = track.cueIndex(at: position) {
            self.overlayNode.setText(track.cues[index].text, isStatus: false)
        } else {
            self.overlayNode.setText(nil, isStatus: false)
        }
        if isPlaying, status.baseRate > 0.0, let boundary = track.nextBoundary(after: position) {
            let delay = max(0.02, (boundary - position) / status.baseRate + 0.01)
            let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: { [weak self] in
                self?.refresh()
            }, queue: Queue.mainQueue())
            self.boundaryTimer = timer
            timer.start()
        }
    }
}

/// The line over the video: white semibold text on a dark rounded plate, bottom centre.
private final class GGSubtitleOverlayNode: ASDisplayNode {
    private let backgroundNode = ASDisplayNode()
    private let textNode = ImmediateTextNode()
    private var text: String?
    private var isStatus = false
    private var layout: (size: CGSize, bottomInset: CGFloat)?

    override init() {
        super.init()
        self.isUserInteractionEnabled = false
        self.backgroundNode.backgroundColor = UIColor(white: 0.0, alpha: 0.65)
        self.backgroundNode.cornerRadius = 10.0
        self.textNode.maximumNumberOfLines = 3
        self.textNode.textAlignment = .center
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.textNode)
        self.alpha = 0.0
    }

    func setText(_ text: String?, isStatus: Bool) {
        if self.text == text && self.isStatus == isStatus {
            return
        }
        self.text = text
        self.isStatus = isStatus
        if let text = text {
            let font = isStatus ? Font.regular(14.0) : Font.semibold(17.0)
            self.textNode.attributedText = NSAttributedString(string: text, font: font, textColor: isStatus ? UIColor(white: 1.0, alpha: 0.8) : .white)
        }
        let transition = ContainedViewLayoutTransition.animated(duration: 0.16, curve: .easeInOut)
        transition.updateAlpha(node: self, alpha: text == nil ? 0.0 : 1.0)
        if let layout = self.layout {
            self.updateLayout(size: layout.size, bottomInset: layout.bottomInset, transition: .immediate)
        }
    }

    func updateLayout(size: CGSize, bottomInset: CGFloat, transition: ContainedViewLayoutTransition) {
        self.layout = (size, bottomInset)
        transition.updateFrame(node: self, frame: CGRect(origin: CGPoint(), size: size))
        let sideInset: CGFloat = 20.0
        let textSize = self.textNode.updateLayout(CGSize(width: size.width - sideInset * 2.0 - 20.0, height: 200.0))
        let plateSize = CGSize(width: textSize.width + 20.0, height: textSize.height + 12.0)
        let plateFrame = CGRect(origin: CGPoint(x: floor((size.width - plateSize.width) / 2.0), y: size.height - bottomInset - plateSize.height - 12.0), size: plateSize)
        transition.updateFrame(node: self.backgroundNode, frame: plateFrame)
        transition.updateFrame(node: self.textNode, frame: CGRect(origin: CGPoint(x: plateFrame.minX + 10.0, y: plateFrame.minY + 6.0), size: textSize))
    }
}
