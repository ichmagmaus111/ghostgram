import Foundation
import UIKit
import CoreVideo
import CoreMedia
import SwiftSignalKit
import GGCore
import GGCameraPipeline
import GGCallFrameBridge
import GGCallsMediaHooks
import GGFeaturesShared

/// Masks in calls. One processor for every call frame of the front camera, installed in the
/// capturer's single hook (`GGCallFrameBridge`) at launch. The block itself is cheap: it reads two
/// settings and returns at once when masks are off; the Core Image context and Vision are created
/// only on the first frame that really has a mask (an audio call never touches them).
final class GGCallMasks {
    static let shared = GGCallMasks()

    private let lock = NSLock()
    private var accountValue: GGAccountID?
    private lazy var processor: GGMaskFrameProcessor = GGMaskFrameProcessor(maskProvider: { [weak self] in
        return self?.currentMask()
    })

    /// The account of the call on screen (set by the call screen's overlay).
    var currentAccount: GGAccountID? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.accountValue
        }
        set {
            self.lock.lock()
            self.accountValue = newValue
            self.lock.unlock()
        }
    }

    static func install() {
        GGCallFrameBridge.setProcessor({ pixelBuffer, isFrontCamera, rotation in
            guard isFrontCamera, let processed = GGCallMasks.shared.process(pixelBuffer, rotation: Int(rotation)) else {
                return nil
            }
            return Unmanaged.passRetained(processed)
        })
    }

    /// Masks apply in calls when the user turned them on there, or while the anonymous mode is on.
    private func isEnabled(account: GGAccountID?) -> Bool {
        if let account, GGAnonymousMode.isActive.value(for: account) {
            return true
        }
        return GGMaskSettings.inCalls.value
    }

    private func currentMask() -> GGPreparedMask? {
        let account = self.currentAccount
        guard self.isEnabled(account: account) else {
            return nil
        }
        return GGMaskEngine.shared.mask(for: GGMaskEngine.selection(for: account))
    }

    /// Capture queue of tgcalls. `rotation` is the clockwise angle tgcalls applies for display; the
    /// other side sees the picture unmirrored, so the mask is drawn unmirrored too.
    private func process(_ pixelBuffer: CVPixelBuffer, rotation: Int) -> CVPixelBuffer? {
        guard self.isEnabled(account: self.currentAccount) else {
            return nil
        }
        let info = GGCameraFrameInfo(facing: .front, timestamp: CMClockGetTime(CMClockGetHostTimeClock()), orientation: GGCameraFrameInfo.orientation(quarterTurns: rotation / 90, mirrored: false))
        return self.processor.process(pixelBuffer, info: info)
    }
}

/// The «Masks» button of the call screen's column (W3-3's overlay): the strip of masks.
final class GGCallMasksOverlayItem: GGCallOverlayItem {
    private let accountId: GGAccountID
    private var panel: GGMaskChipsPanel?

    init(accountId: GGAccountID) {
        self.accountId = accountId
    }

    var id: String {
        return "cameraMasks.masks"
    }

    var order: Int {
        return 100
    }

    var icon: UIImage? {
        return UIImage(systemName: "theatermasks.fill")
    }

    func isVisible(state: GGCallScreenState) -> Bool {
        guard state.hasLocalVideo, !state.isTerminated else {
            return false
        }
        return GGMaskSettings.inCalls.value || GGAnonymousMode.isActive.value(for: self.accountId)
    }

    func makePanel() -> UIView? {
        let panel = GGMaskChipsPanel(accountId: self.accountId)
        panel.frame = CGRect(x: 0.0, y: 0.0, width: 320.0, height: GGMaskChipsPanel.height)
        panel.activate()
        self.panel = panel
        return panel
    }

    func buttonTapped() {
    }

    func screenWillClose() {
        self.panel?.invalidate()
        self.panel = nil
    }
}
