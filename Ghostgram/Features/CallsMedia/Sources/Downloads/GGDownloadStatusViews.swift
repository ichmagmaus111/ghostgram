import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatListUI
import GGCore
import GGHooks

/// «Статус загрузок» in the chat list (instead of the message preview) and in the chat (a pill under
/// the navigation bar). The row text comes from the published snapshot; the bar and the percent are
/// the row's own view, which follows its chat's status without any re-layout of the list.
enum GGDownloadStatusViews {
    static func register() {
        // One service per account; it subscribes to anything only while a status switch is on.
        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            let _ = GGDownloadStatusService.service(for: context)
        })

        GGChatListHooks.previewText.register({ rowContext in
            // The «Archived Chats» row has no progress view of its own: no status there.
            guard GGCallsMediaSettings.statusInChatList.value, !rowContext.isArchive, let peer = rowContext.peer else {
                return nil
            }
            guard let status = GGDownloadStatusService.existing(accountId: rowContext.context.account.id)?.status(peerId: peer.id) else {
                return nil
            }
            let presentationData = rowContext.context.sharedContext.currentPresentationData.with { $0 }
            let font = Font.regular(floor(presentationData.listsFontSize.itemListBaseFontSize * 15.0 / 17.0))
            var title = "⬇︎ " + GGDownloadStatusViews.itemTitle(status)
            if status.count > 1 {
                title += " +\(status.count - 1)"
            }
            // The second line is kept free for the progress bar of the row's own view.
            return NSAttributedString(string: title + "\n\u{00A0}", font: font, textColor: rowContext.theme.chatList.messageTextColor)
        }, order: 500)

        GGChatListHooks.rowDidLayout.register({ layout in
            GGDownloadRowProgressView.update(layout: layout)
        }, order: 500)

        GGChatScreenHooks.overlays.register({ screen in
            // Off: no node, no subscription over the chat (a chat opened before the switch is turned
            // on gets the pill the next time it opens).
            guard GGCallsMediaSettings.statusInChat.value, !screen.isPreview, case .peer = screen.chatLocation else {
                return []
            }
            return [GGDownloadChatOverlay(screen: screen)]
        }, order: 500)
    }

    static func itemTitle(_ status: GGDownloadPeerStatus) -> String {
        if let name = status.topFileName, !name.isEmpty {
            return name
        }
        switch status.topKind {
        case .video:
            return GGStrings.Downloads.Status.video
        case .audio:
            return GGStrings.Downloads.Status.audio
        case .image:
            return GGStrings.Downloads.Status.image
        case .file:
            return GGStrings.Downloads.Status.file
        }
    }

    static func progressText(_ status: GGDownloadPeerStatus) -> String {
        if status.isPaused {
            return GGStrings.Downloads.Status.paused
        }
        return "\(Int((status.progress * 100.0).rounded())) %"
    }

    static func sizeText(_ status: GGDownloadPeerStatus) -> String? {
        if status.totalSize <= 0 {
            return nil
        }
        return GGStrings.Downloads.Status.size(downloaded: GGCallsMediaUI.sizeText(status.downloadedSize), total: GGCallsMediaUI.sizeText(status.totalSize))
    }
}

private var ggDownloadRowViewKey: UInt8 = 0

/// Bar + percent under the download line of a chat list row. One per row node, reused with it.
final class GGDownloadRowProgressView: UIView {
    /// Some row got a view in this process (main thread). Until then a row has none to remove, so a
    /// layout with the switch off costs one load of a flag.
    private static var hasCreatedViews = false

    static func update(layout: GGChatListRowLayout) {
        if !GGDownloadRowProgressView.hasCreatedViews && !GGCallsMediaSettings.statusInChatList.value {
            return
        }
        let existing = objc_getAssociatedObject(layout.node, &ggDownloadRowViewKey) as? GGDownloadRowProgressView
        guard GGCallsMediaSettings.statusInChatList.value, let peer = layout.peer, let itemNode = layout.node as? ChatListItemNode, let service = GGDownloadStatusService.existing(accountId: layout.context.account.id), service.status(peerId: peer.id) != nil else {
            existing?.detach()
            return
        }
        let textNode = itemNode.textNode.textNode
        guard let container = textNode.supernode?.view else {
            existing?.detach()
            return
        }
        let view: GGDownloadRowProgressView
        if let existing = existing {
            view = existing
        } else {
            view = GGDownloadRowProgressView(frame: .zero)
            objc_setAssociatedObject(layout.node, &ggDownloadRowViewKey, view, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            GGDownloadRowProgressView.hasCreatedViews = true
        }
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view)
        }
        let presentationData = layout.context.sharedContext.currentPresentationData.with { $0 }
        view.setup(service: service, peerId: peer.id, theme: presentationData.theme, fontSize: presentationData.listsFontSize.itemListBaseFontSize)
        // The text node has two lines: the file name and an empty one held for this view.
        let textFrame = textNode.frame
        let lineHeight = floor(textFrame.height / 2.0)
        if textFrame.height > 0.0 && lineHeight > 8.0 {
            view.frame = CGRect(x: textFrame.minX + 1.0, y: textFrame.minY + lineHeight, width: max(0.0, textFrame.width - 2.0), height: lineHeight)
        } else {
            view.frame = CGRect(x: textFrame.minX + 1.0, y: textFrame.maxY - 3.0, width: max(0.0, textFrame.width - 2.0), height: 3.0)
        }
        view.layoutBar()
    }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let percentLabel = UILabel()
    private let disposable = MetaDisposable()
    private var peerId: EnginePeer.Id?
    private var status: GGDownloadPeerStatus?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.trackLayer.cornerRadius = 1.5
        self.fillLayer.cornerRadius = 1.5
        self.layer.addSublayer(self.trackLayer)
        self.layer.addSublayer(self.fillLayer)
        self.percentLabel.textAlignment = .right
        self.addSubview(self.percentLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable.dispose()
    }

    func detach() {
        self.disposable.set(nil)
        self.peerId = nil
        self.status = nil
        self.removeFromSuperview()
    }

    func setup(service: GGDownloadStatusService, peerId: EnginePeer.Id, theme: PresentationTheme, fontSize: CGFloat) {
        self.trackLayer.backgroundColor = theme.chatList.messageTextColor.withAlphaComponent(0.15).cgColor
        self.fillLayer.backgroundColor = theme.list.itemAccentColor.cgColor
        self.percentLabel.font = Font.regular(floor(fontSize * 13.0 / 17.0))
        self.percentLabel.textColor = theme.chatList.messageTextColor.withAlphaComponent(0.6)
        if self.peerId == peerId {
            return
        }
        self.peerId = peerId
        self.status = service.status(peerId: peerId)
        self.disposable.set((service.statusSignal(peerId: peerId)
        |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let strongSelf = self else {
                return
            }
            strongSelf.status = status
            strongSelf.layoutBar()
        }))
    }

    func layoutBar() {
        let bounds = self.bounds
        guard let status = self.status else {
            self.isHidden = true
            return
        }
        self.isHidden = false
        let text = GGDownloadStatusViews.progressText(status)
        let showsLabel = bounds.height > 6.0
        var barWidth = bounds.width
        if showsLabel {
            self.percentLabel.isHidden = false
            self.percentLabel.text = text
            let labelSize = self.percentLabel.sizeThatFits(CGSize(width: 120.0, height: bounds.height))
            self.percentLabel.frame = CGRect(x: bounds.width - labelSize.width, y: floor((bounds.height - labelSize.height) / 2.0), width: labelSize.width, height: labelSize.height)
            barWidth = max(0.0, bounds.width - labelSize.width - 8.0)
        } else {
            self.percentLabel.isHidden = true
        }
        let barY = showsLabel ? floor((bounds.height - 3.0) / 2.0) : 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.trackLayer.frame = CGRect(x: 0.0, y: barY, width: barWidth, height: 3.0)
        self.fillLayer.frame = CGRect(x: 0.0, y: barY, width: floor(barWidth * CGFloat(max(0.0, min(1.0, status.progress)))), height: 3.0)
        CATransaction.commit()
    }
}

/// The pill under the chat's navigation bar: the top download (this chat's first), its size and
/// percent, with a thin bar. Tapping it opens the message being downloaded.
private final class GGDownloadChatOverlay: GGChatOverlay {
    let node: ASDisplayNode
    let placement: GGChatOverlayPlacement = .aboveHistory

    private let context: AccountContext
    private let chatPeerId: EnginePeer.Id?
    private weak var controller: ChatController?
    private let pillNode = GGDownloadPillNode()
    private let disposable = MetaDisposable()
    private var statuses: [EnginePeer.Id: GGDownloadPeerStatus] = [:]
    private var lastLayout: (bounds: CGRect, insets: UIEdgeInsets)?

    init(screen: GGChatScreen) {
        self.context = screen.context
        if case let .peer(peerId) = screen.chatLocation {
            self.chatPeerId = peerId
        } else {
            self.chatPeerId = nil
        }
        self.controller = screen.controller
        self.node = GGPassThroughNode()
        self.node.addSubnode(self.pillNode)
        self.pillNode.alpha = 0.0
        self.pillNode.pressed = { [weak self] in
            self?.openTopItem()
        }

        let service = GGDownloadStatusService.service(for: screen.context)
        self.disposable.set((combineLatest(service.statuses, GGCallsMediaSettings.statusInChat.signal)
        |> deliverOnMainQueue).start(next: { [weak self] statuses, enabled in
            guard let strongSelf = self else {
                return
            }
            strongSelf.statuses = enabled ? statuses : [:]
            strongSelf.refresh(animated: true)
        }))
    }

    deinit {
        self.disposable.dispose()
    }

    private var current: GGDownloadPeerStatus? {
        if let chatPeerId = self.chatPeerId, let own = self.statuses[chatPeerId] {
            return own
        }
        return self.statuses.values.sorted(by: { $0.topMessageId < $1.topMessageId }).first
    }

    private func refresh(animated: Bool) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        if let status = self.current {
            let otherCount = self.statuses.values.reduce(0) { $0 + $1.count } - 1
            var title = GGDownloadStatusViews.itemTitle(status)
            if otherCount > 0 {
                title += " +\(otherCount)"
            }
            if let size = GGDownloadStatusViews.sizeText(status) {
                title += " · " + size
            }
            self.pillNode.update(title: title, progressText: GGDownloadStatusViews.progressText(status), progress: status.progress, isPaused: status.isPaused, theme: presentationData.theme)
            let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.2, curve: .easeInOut) : .immediate
            transition.updateAlpha(node: self.pillNode, alpha: 1.0)
        } else {
            let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.2, curve: .easeInOut) : .immediate
            transition.updateAlpha(node: self.pillNode, alpha: 0.0)
        }
        if let lastLayout = self.lastLayout {
            self.updateLayout(bounds: lastLayout.bounds, insets: lastLayout.insets, transition: .immediate)
        }
    }

    func updateLayout(bounds: CGRect, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        self.lastLayout = (bounds, insets)
        transition.updateFrame(node: self.node, frame: bounds)
        let width = min(bounds.width - 24.0, 420.0)
        let size = self.pillNode.measure(width: width)
        transition.updateFrame(node: self.pillNode, frame: CGRect(origin: CGPoint(x: floor((bounds.width - size.width) / 2.0), y: insets.top + 6.0), size: size))
    }

    private func openTopItem() {
        guard let status = self.current, let navigationController = self.controller?.navigationController as? NavigationController else {
            return
        }
        let context = self.context
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: status.topMessageId.peerId))
        |> deliverOnMainQueue).start(next: { peer in
            guard let peer = peer else {
                return
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), subject: .message(id: .id(status.topMessageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false), keepStack: .always))
        })
    }
}

/// A container that only takes touches inside its subnodes.
final class GGPassThroughNode: ASDisplayNode {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result === self.view {
            return nil
        }
        return result
    }
}

private final class GGDownloadPillNode: HighlightTrackingButtonNode {
    private let backgroundNode = ASDisplayNode()
    private let pillTitleNode = ImmediateTextNode()
    private let percentNode = ImmediateTextNode()
    private let trackNode = ASDisplayNode()
    private let fillNode = ASDisplayNode()
    private var progress: Double = 0.0
    var pressed: (() -> Void)?

    init() {
        super.init(pointerStyle: nil)
        self.backgroundNode.cornerRadius = 14.0
        self.backgroundNode.isUserInteractionEnabled = false
        self.pillTitleNode.maximumNumberOfLines = 1
        self.pillTitleNode.truncationMode = .byTruncatingMiddle
        self.pillTitleNode.isUserInteractionEnabled = false
        self.percentNode.isUserInteractionEnabled = false
        self.trackNode.cornerRadius = 1.0
        self.fillNode.cornerRadius = 1.0
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.pillTitleNode)
        self.addSubnode(self.percentNode)
        self.addSubnode(self.trackNode)
        self.addSubnode(self.fillNode)
        self.highligthedChanged = { [weak self] highlighted in
            self?.alpha = highlighted ? 0.55 : 1.0
        }
        self.addTarget(self, action: #selector(self.pressedAction), forControlEvents: .touchUpInside)
    }

    @objc private func pressedAction() {
        self.pressed?()
    }

    func update(title: String, progressText: String, progress: Double, isPaused: Bool, theme: PresentationTheme) {
        self.progress = progress
        self.backgroundNode.backgroundColor = theme.rootController.navigationBar.opaqueBackgroundColor.withAlphaComponent(0.92)
        self.pillTitleNode.attributedText = NSAttributedString(string: title, font: Font.regular(14.0), textColor: theme.rootController.navigationBar.primaryTextColor)
        self.percentNode.attributedText = NSAttributedString(string: progressText, font: Font.regular(13.0), textColor: theme.rootController.navigationBar.secondaryTextColor)
        let accent = isPaused ? theme.rootController.navigationBar.secondaryTextColor : theme.rootController.navigationBar.accentTextColor
        self.trackNode.backgroundColor = accent.withAlphaComponent(0.2)
        self.fillNode.backgroundColor = accent
    }

    func measure(width: CGFloat) -> CGSize {
        let percentSize = self.percentNode.updateLayout(CGSize(width: 90.0, height: 20.0))
        let titleSize = self.pillTitleNode.updateLayout(CGSize(width: max(10.0, width - 24.0 - percentSize.width - 8.0), height: 20.0))
        let size = CGSize(width: width, height: 40.0)
        self.backgroundNode.frame = CGRect(origin: CGPoint(), size: size)
        self.pillTitleNode.frame = CGRect(origin: CGPoint(x: 12.0, y: 7.0), size: titleSize)
        self.percentNode.frame = CGRect(origin: CGPoint(x: width - 12.0 - percentSize.width, y: 8.0), size: percentSize)
        let barFrame = CGRect(x: 12.0, y: 30.0, width: width - 24.0, height: 2.0)
        self.trackNode.frame = barFrame
        self.fillNode.frame = CGRect(x: barFrame.minX, y: barFrame.minY, width: floor(barFrame.width * CGFloat(max(0.0, min(1.0, self.progress)))), height: barFrame.height)
        return size
    }
}
