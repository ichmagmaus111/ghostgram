import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import UndoUI
import GGCore

/// Small UI helpers shared by the zone's features.
enum GGCallsMediaUI {
    /// A short info toast over the whole app (main thread).
    static func toast(context: AccountContext, text: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), on: .root)
    }

    /// The top-most UIKit controller of the key window, for system controllers (document picker,
    /// share sheet, the system video player).
    static func topViewController() -> UIViewController? {
        var keyWindow: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else {
                continue
            }
            for window in windowScene.windows where window.isKeyWindow {
                keyWindow = window
            }
        }
        guard var controller = keyWindow?.rootViewController else {
            return nil
        }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    static func presentNative(_ controller: UIViewController) {
        guard let presenter = GGCallsMediaUI.topViewController() else {
            return
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0.0, height: 0.0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    /// "12:05" or "1:02:03".
    static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        } else {
            return String(format: "%d:%02d", minutes, rest)
        }
    }

    /// Sizes in the user's locale ("3,4 МБ"); formatting is the system's, not a translated string.
    static func sizeText(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
