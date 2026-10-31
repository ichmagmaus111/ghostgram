import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import UIKitRuntimeUtils
import GGCore
import GGHooks
import GGFeaturesShared

/// «Скрывать чат на скриншотах»: one setting (`security.screenshotPrivacy`), one point that applies
/// it (`GGChatScreenHooks.hidesChromeFromCapture` → header, input panel, the panels over it,
/// navigation buttons, quick buttons come out empty on screenshots and screen recordings; the
/// messages stay; no send animation). The menu row and the chat's quick button write the same
/// setting — the button no longer flips any master switch. «И список чатов» does the same for the
/// whole chat list screen (rows, header, folder tabs).
enum GGScreenshotPrivacy {
    private static var chatListKey: UInt8 = 0

    static func register() {
        GGChatScreenHooks.hidesChromeFromCapture.register({ _, _ in
            return GGSecuritySettings.screenshotPrivacy.value
        })
        GGQuickActions.actions.register(GGQuickAction(
            id: GGQuickActionIds.screenshotPrivacy,
            order: 700,
            title: { GGStrings.Security.Screenshot.quickAction },
            iconName: "Chat/Context Menu/Lock",
            isOn: { _ in
                return GGSecuritySettings.screenshotPrivacy.value
            },
            perform: { context in
                GGSecuritySettings.screenshotPrivacy.set(!GGSecuritySettings.screenshotPrivacy.value)
                // The chat applies it on its next layout: ask for one now.
                (context.chatController as? ViewController)?.requestLayout(transition: .immediate)
            }
        ))
        GGChatListChromeHooks.containerDidLayout.register({ layout in
            let hides = GGSecuritySettings.screenshotPrivacy.value && GGSecuritySettings.screenshotPrivacyChatList.value
            let node = layout.node
            let applied = (objc_getAssociatedObject(node, &GGScreenshotPrivacy.chatListKey) as? NSNumber)?.boolValue ?? false
            if hides == applied {
                return
            }
            objc_setAssociatedObject(node, &GGScreenshotPrivacy.chatListKey, NSNumber(value: hides), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            setLayerDisableScreenshots(node.layer, hides)
        })
    }
}
