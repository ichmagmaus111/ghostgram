import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import DeviceModel
import GGCore
import GGHooks

/// «Бейдж под островом» (app_icons_badges, SG-I2/I3): a pill drawn behind the cutout / Dynamic
/// Island. It is invisible to the eye (the cutout covers it) and shows up on screenshots and
/// screen recordings.
///
/// Telegram has a badge of its own there (`Window1.badgeView`, the blue «Telegram» pill, notch
/// phones only, fixed y = 5). It is never shown (owner, 2026-10-28: only the Ghostgram badge): its
/// image is dropped and it is faded out (`alpha`, which Telegram never touches — it only drives
/// `isHidden`); the view itself stays, Telegram inserts controllers below it. Our badge lives in a
/// full-window pass-through host; with the feature off there is no badge at all. Visibility
/// follows Telegram's own rules: phone with a cutout, app active, portrait.
final class GGIslandBadge {
    static let shared = GGIslandBadge()

    private weak var window: Window1?
    private var hostView: GGIslandBadgeHostView?
    private var isActive = true
    private var activeDisposable: Disposable?
    private var settingsDisposable: Disposable?
    private var storeDisposable: Disposable?

    private init() {
    }

    func register() {
        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGIslandBadge.shared.attach(context: context)
        })
        GGBadgeStore.shared.migrateLegacyBadgesIfNeeded()
    }

    /// Main thread. The window is the same for every account; the first call wires everything.
    private func attach(context: AccountContext) {
        guard context.sharedContext.applicationBindings.isMainApp, let window = context.sharedContext.mainWindow else {
            return
        }
        if self.window === window {
            return
        }
        self.window = window
        // Telegram shows its badge only once the root controller exists (`setForceBadgeHidden`,
        // after a 0.4 s delay), i.e. after this point.
        window.badgeView.image = nil
        window.badgeView.alpha = 0.0

        self.activeDisposable = (context.sharedContext.applicationBindings.applicationIsActive
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else {
                return
            }
            self.isActive = value
            self.hostView?.isAppActive = value
        })

        self.settingsDisposable = (combineLatest(InterfaceSettings.islandBadge.signal, InterfaceSettings.islandBadgeSelection.signal)
        |> deliverOnMainQueue).start(next: { [weak self] enabled, selection in
            self?.apply(enabled: enabled, selection: selection)
        })
    }

    private func apply(enabled: Bool, selection: String) {
        guard let window = self.window else {
            return
        }
        guard enabled, GGIslandBadgeGeometry.isSupported else {
            if let hostView = self.hostView {
                hostView.removeFromSuperview()
                self.hostView = nil
            }
            return
        }
        let hostView: GGIslandBadgeHostView
        if let current = self.hostView {
            hostView = current
        } else {
            hostView = GGIslandBadgeHostView(frame: window.hostView.containerView.bounds)
            hostView.isAppActive = self.isActive
            window.hostView.containerView.addSubview(hostView)
            self.hostView = hostView
        }
        hostView.image = GGBadgeStore.shared.image(selection: selection)
    }

    /// Called after the studio re-renders the selected badge.
    func reloadImage() {
        if self.hostView != nil {
            self.apply(enabled: InterfaceSettings.islandBadge.value, selection: InterfaceSettings.islandBadgeSelection.value)
        }
    }
}

/// Where the pill goes. Offsets are the measured ones of the old client (top of the pill from the
/// top of the screen, in points at native scale); a phone this build does not know falls back to
/// the safe area: ≥ 59 pt is a Dynamic Island, ≥ 44 pt a notch.
enum GGIslandBadgeGeometry {
    static var isSupported: Bool {
        return GGIslandBadgeGeometry.topOffset(safeTop: GGIslandBadgeGeometry.systemSafeTop) != nil
    }

    static var systemSafeTop: CGFloat {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? windows.first?.safeAreaInsets.top ?? 0.0
    }

    static func topOffset(safeTop: CGFloat) -> CGFloat? {
        if UIDevice.current.userInterfaceIdiom != .phone {
            return nil
        }
        let offset: CGFloat
        switch DeviceModel.current {
        case .iPhoneX, .iPhoneXS, .iPhone11Pro, .iPhone12Mini, .iPhone13Mini:
            offset = 2.0
        case .iPhone11, .iPhoneXR, .iPhone12ProMax, .iPhone13ProMax, .iPhone14Plus:
            offset = 6.0
        case .iPhone11ProMax, .iPhoneXSMax, .iPhone12, .iPhone12Pro, .iPhone13, .iPhone13Pro, .iPhone14, .iPhone16e:
            offset = 4.0
        case .iPhone14Pro, .iPhone15, .iPhone15Pro, .iPhone16, .iPhone17:
            offset = 18.0
        case .iPhone14ProMax, .iPhone15Plus, .iPhone15ProMax, .iPhone16Plus:
            offset = 19.0
        case .iPhone16Pro, .iPhone17Pro, .iPhoneAir:
            offset = 21.0
        case .iPhone16ProMax, .iPhone17ProMax:
            offset = 22.0
        default:
            // Unknown or newer phone: decide by the cutout the system reports.
            if safeTop >= 59.0 {
                offset = 20.0
            } else if safeTop >= 44.0 {
                offset = 4.0
            } else {
                return nil
            }
        }
        // Display Zoom scales the whole interface; the cutout does not move.
        let scaleFactor = UIScreen.main.scale / max(1.0, UIScreen.main.nativeScale)
        return floorToScreenPixels(offset * scaleFactor)
    }
}

/// Full-window, touch-transparent host; positions the pill on every size change (rotation).
private final class GGIslandBadgeHostView: UIView {
    private let imageView = UIImageView()

    var image: UIImage? {
        didSet {
            self.imageView.image = self.image
            self.setNeedsLayout()
        }
    }

    var isAppActive = true {
        didSet {
            if self.isAppActive != oldValue {
                self.setNeedsLayout()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.accessibilityElementsHidden = true
        self.imageView.contentMode = .scaleAspectFit
        self.addSubview(self.imageView)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        let isPortrait = size.width < size.height
        guard isPortrait, self.isAppActive, self.image != nil, let top = GGIslandBadgeGeometry.topOffset(safeTop: self.window?.safeAreaInsets.top ?? GGIslandBadgeGeometry.systemSafeTop) else {
            self.imageView.isHidden = true
            return
        }
        self.imageView.isHidden = false
        let badgeSize = GGBadgeDocument.canvasSize
        self.imageView.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((size.width - badgeSize.width) / 2.0), y: top), size: badgeSize)
    }
}
