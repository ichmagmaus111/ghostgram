import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI

/// t.me links go through the in-app resolver and are pushed on the current navigation stack.
/// `openExternalUrl` is never used for them: it resets the stack to the chat list.
func ggOpenTelegramLink(context: AccountContext, url: String, navigationController: NavigationController, present: @escaping (ViewController) -> Void) {
    let _ = (context.sharedContext.resolveUrl(context: context, peerId: nil, url: url, skipUrlAuth: true)
    |> take(1)
    |> deliverOnMainQueue).start(next: { [weak navigationController] resolvedUrl in
        guard let navigationController else {
            return
        }
        context.sharedContext.openResolvedUrl(
            resolvedUrl,
            context: context,
            urlContext: .generic,
            navigationController: navigationController,
            forceExternal: false,
            forceUpdate: false,
            openPeer: { [weak navigationController] peer, _ in
                guard let navigationController else {
                    return
                }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(
                    navigationController: navigationController,
                    context: context,
                    chatLocation: .peer(peer),
                    keepStack: .always
                ))
            },
            sendFile: nil,
            sendSticker: nil,
            sendEmoji: nil,
            requestMessageActionUrlAuth: nil,
            joinVoiceChat: nil,
            present: { controller, _ in
                present(controller)
            },
            dismissInput: {},
            contentContext: nil,
            progress: nil,
            completion: nil
        )
    })
}

func ggPresentToast(context: AccountContext, text: String, present: (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present(UndoOverlayController(
        presentationData: presentationData,
        content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
        elevatedLayout: false,
        action: { _ in
            return false
        }
    ))
}

/// "13.0 (12345)" from the main bundle. Not translated: digits only.
func ggAppVersionString() -> String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? ""
    let build = info?["CFBundleVersion"] as? String ?? ""
    if build.isEmpty {
        return version
    }
    return "\(version) (\(build))"
}
