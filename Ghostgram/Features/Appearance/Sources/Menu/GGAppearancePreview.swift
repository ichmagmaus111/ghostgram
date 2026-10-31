import Foundation
import UIKit
import TelegramPresentationData
import GGCore
import GGSettingsUI
import GGAppearanceSettings

/// The live mini chats of «Сообщения» and «Тема и фон» (W2-4 U6, U7): while a slider is dragged the
/// bubbles follow it (radii, padding, width, outline, background, name saturation) and the chat
/// layers of the theme tab (animated background, snow, edge bands) follow theirs. Nothing is
/// written before the finger is lifted: the drafts of the screen become a snapshot that the theme
/// transformer and the layout hooks see on the main thread for the duration of the preview's layout
/// (`GGAppearanceSnapshot.withPreview`). The chat's top bar follows «Скрыть в шапке чата».
enum GGAppearancePreview {
    /// Every slider the snapshot is built from (its drafts change the bubbles).
    private static var snapshotSliders: [GGSetting<Double>] {
        return [
            GGAppearanceSettings.bubbleIncomingRadius,
            GGAppearanceSettings.bubbleOutgoingRadius,
            GGAppearanceSettings.bubblePadding,
            GGAppearanceSettings.bubbleWidth,
            GGAppearanceSettings.bubbleBackgroundOpacity,
            GGAppearanceSettings.bubbleOutlineOpacity,
            GGAppearanceSettings.stickerSize,
            GGAppearanceSettings.nameColorSaturation
        ]
    }

    /// The configuration of a mini chat that follows the drafts of its screen.
    static func configuration(scope: String, overlays: Bool, content: @escaping (GGMenuContext) -> GGMiniChatContent) -> GGMiniChatConfiguration {
        var makeOverlays: ((GGMenuContext) -> [GGMiniChatOverlay])?
        if overlays {
            makeOverlays = { _ in
                let layers: [GGMiniChatOverlay] = [GGPreviewBackgroundOverlay(), GGPreviewEdgesOverlay()]
                return layers
            }
        }
        return GGMiniChatConfiguration(scope: scope, height: 196.0, content: content, presentationData: { context in
            // No slider is dragged: the app's own theme (already through the transformer).
            if GGAppearancePreview.drafts(context).isEmpty {
                return context.presentationData
            }
            return GGAppearanceTheme.previewPresentationData(context.presentationData)
        }, draftScope: { context, body in
            let drafts = GGAppearancePreview.drafts(context)
            if drafts.isEmpty {
                body()
            } else {
                GGAppearanceSnapshot.withPreview(GGAppearanceSnapshot.make(overriding: drafts), body)
            }
        }, overlays: makeOverlays)
    }

    /// The values the screen's sliders are being dragged to, of the sliders the snapshot is made of.
    private static func drafts(_ context: GGMenuContext) -> [String: Double] {
        var drafts: [String: Double] = [:]
        for setting in GGAppearancePreview.snapshotSliders {
            if let value = context.draftValue(forKey: setting.key) {
                drafts[setting.key] = value
            }
        }
        return drafts
    }

    /// The sample conversation with the chat's top bar as «Скрыть в шапке чата» sets it.
    static func sampleContent() -> GGMiniChatContent {
        var header = GGMiniChatContent.sampleHeader()
        header.hidesAvatar = GGAppearanceSettings.hideAvatar.value
        header.hidesTitle = GGAppearanceSettings.hideTitlePanel.value
        return GGMiniChatContent.sample(header: header)
    }

    /// A slider's value as the preview shows it: the draft while dragged.
    fileprivate static func reader(_ context: GGMenuContext) -> (GGSetting<Double>) -> Double {
        return { setting in
            return context.draftValue(forKey: setting.key) ?? setting.value
        }
    }
}

/// The animated chat background and the snow, under the bubbles.
private final class GGPreviewBackgroundOverlay: GGMiniChatOverlay {
    let view = UIView()
    let placement: GGMiniChatOverlayPlacement = .belowMessages

    private var videoView: GGLoopingVideoView?
    private var snowView: GGSnowView?

    init() {
        self.view.isUserInteractionEnabled = false
        self.view.clipsToBounds = true
    }

    func update(context: GGMenuContext, size: CGSize, insets: UIEdgeInsets) {
        let settings = GGBackgroundDecorSettings.current(double: GGAppearancePreview.reader(context))
        let bounds = CGRect(origin: CGPoint(), size: size)

        if settings.background, let url = GGAnimatedBackgrounds.fileURL(.chat) {
            let videoView: GGLoopingVideoView
            if let current = self.videoView {
                videoView = current
            } else {
                videoView = GGLoopingVideoView(frame: bounds)
                self.view.insertSubview(videoView, at: 0)
                self.videoView = videoView
            }
            videoView.frame = bounds
            videoView.alpha = CGFloat(settings.backgroundOpacity)
            videoView.setVideo(url: url, version: settings.backgroundVersion)
        } else if let videoView = self.videoView {
            self.videoView = nil
            videoView.setVideo(url: nil, version: 0)
            videoView.removeFromSuperview()
        }

        if settings.snow && settings.snowInChats {
            let snowView: GGSnowView
            if let current = self.snowView {
                snowView = current
            } else {
                snowView = GGSnowView(frame: bounds, kind: .background)
                self.view.addSubview(snowView)
                self.snowView = snowView
            }
            snowView.frame = bounds
            snowView.update(style: settings.snowStyle, intensity: settings.snowIntensity, isPaused: GGSystemState.current)
        } else if let snowView = self.snowView {
            self.snowView = nil
            snowView.removeFromSuperview()
        }
    }
}

/// The blur and gradient bands of the screen edges, above the bubbles: the top one under the
/// preview's top bar, the bottom one at the block's lower edge (the preview has no input panel).
private final class GGPreviewEdgesOverlay: GGMiniChatOverlay {
    let view = UIView()
    let placement: GGMiniChatOverlayPlacement = .aboveMessages

    private let topView = GGEdgeBandView(edge: .top)
    private let bottomView = GGEdgeBandView(edge: .bottom)

    init() {
        self.view.isUserInteractionEnabled = false
        self.view.clipsToBounds = true
        self.view.addSubview(self.topView)
        self.view.addSubview(self.bottomView)
    }

    func update(context: GGMenuContext, size: CGSize, insets: UIEdgeInsets) {
        let settings = GGEdgeDecorSettings.current(double: GGAppearancePreview.reader(context))
        self.view.isHidden = settings.isEmpty
        if settings.isEmpty {
            return
        }
        let theme = context.presentationData.theme
        let width = size.width

        let topBands = settings.bands(autoColor: theme.rootController.navigationBar.opaqueBackgroundColor)
        self.topView.update(width: width, inset: insets.top, blur: topBands.blur, gradient: topBands.gradient)
        self.topView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: self.topView.bandHeight(inset: insets.top, blur: topBands.blur, gradient: topBands.gradient))

        let bottomBands = settings.bands(autoColor: theme.chat.inputPanel.panelBackgroundColor.withAlphaComponent(1.0))
        self.bottomView.update(width: width, inset: 0.0, blur: bottomBands.blur, gradient: bottomBands.gradient)
        let bottomHeight = self.bottomView.bandHeight(inset: 0.0, blur: bottomBands.blur, gradient: bottomBands.gradient)
        self.bottomView.frame = CGRect(x: 0.0, y: size.height - bottomHeight, width: width, height: bottomHeight)
    }
}
