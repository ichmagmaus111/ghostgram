import Foundation
import UIKit
import ObjectiveC
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import AccountContext
import UndoUI
import GGCore
import GGHooks
import GGAppearanceSettings

/// Profile appearance (profile_ui_toggles, SG-C1/C2/C4):
/// - ID, data center, dates of creation / joining and «mutual contact» as info rows — all from the
///   peer record on the device, no network, texts from Ghostgram's own strings;
/// - the own animated header background (gif_wallpapers);
/// - no star-rating («level») badge (`GGPeerInfoHooks.hidesItem(.starRating)`, GGAppearancePendingPoints:
///   the header then keeps no room for it).
enum GGProfileDecor {
    static func register() {
        GGPeerInfoHooks.infoRows.register({ context in
            return GGProfileDecor.rows(context)
        }, order: 100)

        GGPeerInfoHooks.headerDidLayout.register({ header in
            GGProfileHeaderDecor.update(header)
        }, order: 100)
    }

    // MARK: Info rows

    private static func rows(_ info: GGPeerInfoContext) -> [GGPeerInfoRow] {
        let showId = GGAppearanceSettings.profileShowId.value
        let showDataCenter = GGAppearanceSettings.profileShowDataCenter.value
        let showDates = GGAppearanceSettings.profileShowDates.value
        if !showId && !showDataCenter && !showDates {
            return []
        }
        let context = info.context
        let peer = info.peer
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        var result: [GGPeerInfoRow] = []

        if showId {
            let idText = GGProfileDecor.idText(peer)
            result.append(GGPeerInfoRow(id: "appearance.profile.id", label: GGStrings.Appearance.Profile.idLabel, text: idText, longTapAction: { [weak controller = info.controller] in
                GGProfileDecor.copy(idText, context: context, controller: controller)
            }))
        }

        if showDataCenter, let resource = peer.smallProfileImage?.resource as? CloudPeerPhotoSizeMediaResource {
            let text = GGStrings.Appearance.Profile.dataCenterValue(number: "\(resource.datacenterId)")
            result.append(GGPeerInfoRow(id: "appearance.profile.dataCenter", label: GGStrings.Appearance.Profile.dataCenterLabel, text: text, longTapAction: { [weak controller = info.controller] in
                GGProfileDecor.copy(text, context: context, controller: controller)
            }))
        }

        if showDates {
            switch peer {
            case let .channel(channel):
                // `date` of a channel is the day the account joined it, or its creation date for
                // somebody who is not a member (Telegram API).
                let label: String
                if case .member = channel.participationStatus {
                    label = GGStrings.Appearance.Profile.joinedLabel
                } else if case .broadcast = channel.info {
                    label = GGStrings.Appearance.Profile.channelCreatedLabel
                } else {
                    label = GGStrings.Appearance.Profile.groupCreatedLabel
                }
                if channel.creationDate > 0 {
                    let text = stringForDate(timestamp: channel.creationDate, strings: strings)
                    result.append(GGPeerInfoRow(id: "appearance.profile.date", label: label, text: text, longTapAction: { [weak controller = info.controller] in
                        GGProfileDecor.copy(text, context: context, controller: controller)
                    }))
                }
            case let .legacyGroup(group):
                if group.creationDate > 0 {
                    let text = stringForDate(timestamp: group.creationDate, strings: strings)
                    result.append(GGPeerInfoRow(id: "appearance.profile.date", label: GGStrings.Appearance.Profile.groupCreatedLabel, text: text, longTapAction: { [weak controller = info.controller] in
                        GGProfileDecor.copy(text, context: context, controller: controller)
                    }))
                }
            case let .user(user):
                if user.flags.contains(.mutualContact) && user.id != context.account.peerId {
                    result.append(GGPeerInfoRow(id: "appearance.profile.mutual", label: GGStrings.Appearance.Profile.mutualContactLabel, text: GGStrings.Appearance.Profile.mutualContactValue))
                }
                // A member's profile opened from a group: when they joined it.
                if let groupId = info.sourceChatPeerId, let joined = GGMemberJoinDates.shared.joinDate(context: context, groupId: groupId, memberId: user.id, controller: info.controller) {
                    let text = stringForDate(timestamp: joined.date, strings: strings)
                    result.append(GGPeerInfoRow(id: "appearance.profile.joinedGroup", label: GGStrings.Appearance.Profile.memberJoinedLabel(chat: joined.groupTitle), text: text, longTapAction: { [weak controller = info.controller] in
                        GGProfileDecor.copy(text, context: context, controller: controller)
                    }))
                }
            case .secretChat, .community:
                break
            }
        }
        return result
    }

    /// The ID as bots and the Bot API see it: users as is, groups negative, channels with -100.
    private static func idText(_ peer: EnginePeer) -> String {
        let id = peer.id.id._internalGetInt64Value()
        switch peer {
        case .user, .secretChat:
            return "\(id)"
        case .legacyGroup:
            return "-\(id)"
        case .channel:
            return "-100\(id)"
        case .community:
            return "\(id)"
        }
    }

    private static func copy(_ text: String, context: AccountContext, controller: ViewController?) {
        UIPasteboard.general.string = text
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: .copy(text: GGStrings.Appearance.Profile.copied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in
            return false
        }), in: .current)
    }
}

/// When a member joined a group (SG-C4, «Дата вступления»), for the profile opened from that group.
/// Only from data on the device, as the row's description promises: a basic group's cached
/// participant list carries the date. A supergroup keeps no participant list on the device, and
/// asking the server (`channels.getParticipant`) would tell it whose profile was opened from which
/// group — so a supergroup member gets no row. The rows are built synchronously from what is known;
/// an unknown date is read once, then the profile is laid out again (`requestLayout`) and reads the
/// answer here. Main thread; answers live for the session.
final class GGMemberJoinDates {
    struct Joined {
        let date: Int32
        let groupTitle: String
    }

    private enum State {
        case loading
        case known(Joined?)
    }

    static let shared = GGMemberJoinDates()

    private var states: [String: State] = [:]

    private init() {
    }

    func joinDate(context: AccountContext, groupId: EnginePeer.Id, memberId: EnginePeer.Id, controller: ViewController?) -> Joined? {
        assert(Thread.isMainThread)
        // Basic groups only: see the type's comment (no network).
        guard groupId.namespace == Namespaces.Peer.CloudGroup else {
            return nil
        }
        let key = "\(context.account.id.gg.rawValue):\(groupId.ggKey.stringValue):\(memberId.ggKey.stringValue)"
        if let state = self.states[key] {
            switch state {
            case let .known(joined):
                return joined
            case .loading:
                return nil
            }
        }
        self.states[key] = .loading

        let title: Signal<String, NoError> = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: groupId))
        |> map { peer -> String in
            guard let peer else {
                return ""
            }
            switch peer {
            case let .channel(channel):
                return channel.title
            case let .legacyGroup(group):
                return group.title
            default:
                return ""
            }
        }
        // The group's cached participants (Postbox), never the network.
        let date: Signal<Int32?, NoError> = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.LegacyGroupParticipants(id: groupId))
        |> map { participants -> Int32? in
            guard case let .known(list) = participants else {
                return nil
            }
            for participant in list where participant.peerId == memberId {
                switch participant {
                case let .member(_, _, invitedAt, _), let .admin(_, _, invitedAt, _):
                    return invitedAt
                case .creator:
                    return nil
                }
            }
            return nil
        }
        let _ = (combineLatest(date |> take(1), title)
        |> deliverOnMainQueue).start(next: { [weak controller] date, title in
            var joined: Joined?
            if let date, date > 0 {
                joined = Joined(date: date, groupTitle: title)
            }
            self.states[key] = .known(joined)
            if joined != nil {
                controller?.requestLayout(transition: .immediate)
            }
        })
        return nil
    }
}

/// The own profile header: the animated background behind the avatar. Attached once per header node;
/// the per-layout work is a frame update.
///
/// The background banner comes with the header layout (`GGPeerInfoHeader.backgroundContainerView`);
/// the first subview of the header is only the fallback. It is kept weakly.
private final class GGProfileHeaderDecor {
    private static var key: UInt8 = 0

    private weak var node: ASDisplayNode?
    private var videoView: GGLoopingVideoView?
    private weak var bannerView: UIView?
    private var disposable: Disposable?
    private var lastWidth: CGFloat = 0.0

    private init(node: ASDisplayNode) {
        self.node = node
        self.disposable = (GGProfileBackgroundSettings.signal
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.applyBackground()
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    static func update(_ header: GGPeerInfoHeader) {
        let isOwn = header.isSettings || header.peer?.id == header.context.account.peerId
        if !isOwn {
            return
        }
        let decor: GGProfileHeaderDecor
        if let current = objc_getAssociatedObject(header.node, &GGProfileHeaderDecor.key) as? GGProfileHeaderDecor {
            decor = current
        } else {
            decor = GGProfileHeaderDecor(node: header.node)
            objc_setAssociatedObject(header.node, &GGProfileHeaderDecor.key, decor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        decor.lastWidth = header.width
        if let bannerView = header.backgroundContainerView {
            decor.bannerView = bannerView
        }
        decor.applyBackground()
    }

    private func applyBackground() {
        guard let node = self.node else {
            return
        }
        let settings = GGProfileBackgroundSettings.current()
        guard settings.enabled, let url = GGAnimatedBackgrounds.fileURL(.profile) else {
            if let videoView = self.videoView {
                self.videoView = nil
                videoView.setVideo(url: nil, version: 0)
                videoView.removeFromSuperview()
            }
            return
        }
        // The header's background banner (cover, emoji pattern); the video goes right above it,
        // under the avatar, the name and the buttons.
        guard let banner = self.bannerView ?? node.view.subviews.first(where: { !($0 is GGLoopingVideoView) }) else {
            return
        }
        let videoView: GGLoopingVideoView
        if let current = self.videoView {
            videoView = current
        } else {
            videoView = GGLoopingVideoView(frame: CGRect())
            self.videoView = videoView
        }
        if videoView.superview !== node.view {
            node.view.insertSubview(videoView, aboveSubview: banner)
        }
        let bannerBottom = banner.frame.maxY
        videoView.frame = CGRect(x: 0.0, y: 0.0, width: max(self.lastWidth, banner.frame.width), height: max(0.0, bannerBottom))
        videoView.alpha = CGFloat(settings.opacity)
        videoView.setVideo(url: url, version: settings.version)
    }
}

struct GGProfileBackgroundSettings: Equatable {
    var enabled: Bool
    var opacity: Double
    var version: Int

    static func current() -> GGProfileBackgroundSettings {
        return GGProfileBackgroundSettings(enabled: GGAppearanceSettings.profileBackground.value, opacity: ggClampPercent(GGAppearanceSettings.profileBackgroundOpacity.value), version: GGAppearanceSettings.profileBackgroundVersion.value)
    }

    static var signal: Signal<GGProfileBackgroundSettings, NoError> {
        return GGSettingsStore.shared.revision
        |> map { _ -> GGProfileBackgroundSettings in
            return GGProfileBackgroundSettings.current()
        }
        |> distinctUntilChanged
    }
}
