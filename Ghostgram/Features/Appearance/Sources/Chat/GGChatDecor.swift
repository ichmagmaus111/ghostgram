import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import GGCore
import GGHooks
import GGAppearanceSettings

/// Decorations of the chat screen, as feature overlays (GGChatScreenHooks.overlays) instead of edits
/// in ChatControllerNode: the animated background and the snowfall above the wallpaper, the blur and
/// gradient bands at the screen edges above the messages. Each overlay follows its settings with one
/// signal, created once per chat screen; nothing here takes part in theme rebuilds.
enum GGChatDecor {
    static func register() {
        GGChatScreenHooks.overlays.register({ screen in
            if screen.isPreview {
                return []
            }
            return [GGChatBackgroundOverlay(), GGChatEdgesOverlay(context: screen.context)]
        }, order: 100)

        GGLifecycleHooks.applicationDidBecomeActive.register({
            GGLoopingVideoView.resumeAll()
        }, order: 100)
    }
}

// MARK: - Settings as values

struct GGBackgroundDecorSettings: Equatable {
    var background: Bool
    var backgroundOpacity: Double
    var backgroundVersion: Int
    var snow: Bool
    var snowInChats: Bool
    var snowStyle: GGSnowStyle
    var snowIntensity: Double

    /// `double` reads the sliders (the stored value, or the menu preview's draft).
    static func current(double: (GGSetting<Double>) -> Double = { $0.value }) -> GGBackgroundDecorSettings {
        return GGBackgroundDecorSettings(
            background: GGAppearanceSettings.chatBackground.value,
            backgroundOpacity: ggClampPercent(double(GGAppearanceSettings.chatBackgroundOpacity)),
            backgroundVersion: GGAppearanceSettings.chatBackgroundVersion.value,
            snow: GGAppearanceSettings.snow.value,
            snowInChats: !GGAppearanceSettings.snowHideInChats.value,
            snowStyle: GGSnowStyle(rawValue: GGAppearanceSettings.snowStyle.value) ?? .snow,
            snowIntensity: ggClampPercent(double(GGAppearanceSettings.snowIntensity))
        )
    }

    /// Distinct values only, re-read on every settings revision (a struct compare, no disk).
    static var signal: Signal<GGBackgroundDecorSettings, NoError> {
        return GGSettingsStore.shared.revision
        |> map { _ -> GGBackgroundDecorSettings in
            return GGBackgroundDecorSettings.current()
        }
        |> distinctUntilChanged
    }
}

/// «Затемнение краёв»: one kind of band (blur or gradient) with one color, height and strength.
struct GGEdgeDecorSettings: Equatable {
    var style: GGEdgeStyle
    var rgb: UInt32?
    var size: Double
    var intensity: Double
    var hideInChatList: Bool

    var isEmpty: Bool {
        return self.style == .off
    }

    /// The chat list shows the gradient only (the blur is drawn in chats).
    var showsInChatList: Bool {
        return self.style == .gradient && !self.hideInChatList
    }

    /// `double` reads the sliders (the stored value, or the menu preview's draft).
    static func current(double: (GGSetting<Double>) -> Double = { $0.value }) -> GGEdgeDecorSettings {
        return GGEdgeDecorSettings(
            style: GGEdgeStyle(rawValue: GGAppearanceSettings.edgeStyle.value) ?? .off,
            rgb: ggAppearanceParseColor(GGAppearanceSettings.edgeColor.value),
            size: min(GGEdgeStyle.sizeRange.upperBound, max(GGEdgeStyle.sizeRange.lowerBound, double(GGAppearanceSettings.edgeSize))),
            intensity: ggClampPercent(double(GGAppearanceSettings.edgeIntensity)),
            hideInChatList: GGAppearanceSettings.edgeHideInChatList.value
        )
    }

    static var signal: Signal<GGEdgeDecorSettings, NoError> {
        return GGSettingsStore.shared.revision
        |> map { _ -> GGEdgeDecorSettings in
            return GGEdgeDecorSettings.current()
        }
        |> distinctUntilChanged
    }

    /// The band for one edge, with the theme's color where the user chose «automatic»: in the
    /// `blur` or the `gradient` slot, by the style.
    func bands(autoColor: UIColor) -> (blur: GGEdgeBandView.Band?, gradient: GGEdgeBandView.Band?) {
        let band = GGEdgeBandView.Band(color: self.rgb.flatMap { UIColor(rgb: $0) } ?? autoColor, size: CGFloat(self.size), intensity: CGFloat(self.intensity))
        switch self.style {
        case .off:
            return (nil, nil)
        case .blur:
            return (band, nil)
        case .gradient:
            return (nil, band)
        }
    }
}

/// 0…100 % → 0…1.
func ggClampPercent(_ value: Double) -> Double {
    return min(1.0, max(0.0, value / 100.0))
}

// MARK: - Above the wallpaper: animated background and snow

final class GGChatBackgroundOverlay: GGChatOverlay {
    let node: ASDisplayNode
    let placement: GGChatOverlayPlacement = .aboveWallpaper

    private var videoView: GGLoopingVideoView?
    private var snowView: GGSnowView?
    private var settings: GGBackgroundDecorSettings?
    private var reducesMotion = false
    private var bounds = CGRect()
    private var disposable: Disposable?

    init() {
        self.node = ASDisplayNode()
        self.node.isUserInteractionEnabled = false

        self.disposable = (combineLatest(GGBackgroundDecorSettings.signal, GGSystemState.reducesMotion)
        |> deliverOnMainQueue).start(next: { [weak self] settings, reducesMotion in
            guard let self else {
                return
            }
            self.settings = settings
            self.reducesMotion = reducesMotion
            self.apply()
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    func updateLayout(bounds: CGRect, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        self.bounds = bounds
        self.videoView?.frame = bounds
        self.snowView?.frame = bounds
    }

    private func apply() {
        guard let settings = self.settings else {
            return
        }
        if settings.background, let url = GGAnimatedBackgrounds.fileURL(.chat) {
            let videoView: GGLoopingVideoView
            if let current = self.videoView {
                videoView = current
            } else {
                videoView = GGLoopingVideoView(frame: self.bounds)
                self.node.view.insertSubview(videoView, at: 0)
                self.videoView = videoView
            }
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
                snowView = GGSnowView(frame: self.bounds, kind: .background)
                self.node.view.addSubview(snowView)
                self.snowView = snowView
            }
            snowView.update(style: settings.snowStyle, intensity: settings.snowIntensity, isPaused: self.reducesMotion)
        } else if let snowView = self.snowView {
            self.snowView = nil
            snowView.removeFromSuperview()
        }
    }
}

// MARK: - Above the messages: blur and gradient at the edges

final class GGChatEdgesOverlay: GGChatOverlay {
    let node: ASDisplayNode
    let placement: GGChatOverlayPlacement = .aboveHistory

    private let topView = GGEdgeBandView(edge: .top)
    private let bottomView = GGEdgeBandView(edge: .bottom)
    private var settings: GGEdgeDecorSettings?
    private var theme: PresentationTheme?
    private var layout: (bounds: CGRect, insets: UIEdgeInsets)?
    private var disposable: Disposable?

    init(context: AccountContext) {
        self.node = ASDisplayNode()
        self.node.isUserInteractionEnabled = false
        self.node.view.addSubview(self.topView)
        self.node.view.addSubview(self.bottomView)

        self.disposable = (combineLatest(GGEdgeDecorSettings.signal, context.sharedContext.presentationData)
        |> deliverOnMainQueue).start(next: { [weak self] settings, presentationData in
            guard let self else {
                return
            }
            self.settings = settings
            self.theme = presentationData.theme
            self.apply()
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    func updateLayout(bounds: CGRect, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        self.layout = (bounds, insets)
        self.apply()
    }

    private func apply() {
        guard let settings = self.settings, let theme = self.theme, let layout = self.layout else {
            return
        }
        self.node.isHidden = settings.isEmpty
        if settings.isEmpty {
            return
        }
        let width = layout.bounds.width
        let topBands = settings.bands(autoColor: theme.rootController.navigationBar.opaqueBackgroundColor)
        self.topView.update(width: width, inset: layout.insets.top, blur: topBands.blur, gradient: topBands.gradient)
        self.topView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: self.topView.bandHeight(inset: layout.insets.top, blur: topBands.blur, gradient: topBands.gradient))

        // The overlay's bottom inset includes the input panels (GGChatScreenHooks.overlays).
        let bottomInset = layout.insets.bottom
        let bottomBands = settings.bands(autoColor: theme.chat.inputPanel.panelBackgroundColor.withAlphaComponent(1.0))
        self.bottomView.update(width: width, inset: bottomInset, blur: bottomBands.blur, gradient: bottomBands.gradient)
        let bottomHeight = self.bottomView.bandHeight(inset: bottomInset, blur: bottomBands.blur, gradient: bottomBands.gradient)
        self.bottomView.frame = CGRect(x: 0.0, y: layout.bounds.height - bottomHeight, width: width, height: bottomHeight)
    }
}

extension GGEdgeBandView {
    func bandHeight(inset: CGFloat, blur: Band?, gradient: Band?) -> CGFloat {
        return max(1.0, inset + max(blur?.size ?? 0.0, gradient?.size ?? 0.0))
    }
}
