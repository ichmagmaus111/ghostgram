// Compiled into TelegramUI (filegroup //Ghostgram/GGHooks:TelegramUIHookSources): launch of
// Ghostgram in the app and the call-site helpers of the UI points that need TelegramUI's
// internal types (ChatControllerImpl, ChatControllerNode). No feature logic here.

import Foundation
import UIKit
import ObjectiveC
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import ChatInterfaceState
import ChatPresentationInterfaceState
import SettingsUI
import UIKitRuntimeUtils
import GGCore
import GGHooks
import GGSettingsUI
import GGFeatures

// MARK: - Launch and lifecycle (FOUNDATION_SPEC §2)

private var ggApplicationLaunched = false

/// GHOST hook target: AppDelegate, as soon as the App Group path is known and before the
/// AccountManager and the accounts exist.
func ggApplicationDidLaunch(appGroupPath: String) {
    assert(Thread.isMainThread)
    if ggApplicationLaunched {
        return
    }
    ggApplicationLaunched = true
    GGCore.bootstrap(GGCoreEnvironment(appGroupPath: appGroupPath, process: .app))
    // Screens GGSettingsUI can not link itself (it sits below SettingsUI).
    GGSettingsUIEnvironment.shared.makeTelegramLanguageController = { context in
        return LocalizationListController(context: context)
    }
    // `ghostgram://settings` / `gg://settings` open the Ghostgram menu (features may claim other links).
    GGLifecycleHooks.openURL.register({ url, context, navigationController in
        guard let scheme = url.scheme?.lowercased(), scheme == "ghostgram" || scheme == "gg" else {
            return false
        }
        if url.host?.lowercased() == "settings" {
            navigationController.pushViewController(ggMakeSettingsController(context: context))
            return true
        }
        return false
    }, order: 1000)
    // A double tap that edits a message (GGMessageGestureHooks) reaches the chat's input panel.
    GGMessageGestureHooks.editMessage = { chatNode, messageId in
        guard let chatNode = chatNode as? ChatControllerNode, let interfaceInteraction = chatNode.interfaceInteraction else {
            return false
        }
        interfaceInteraction.setupEditMessage(messageId, { _ in })
        return true
    }
    // «В начало чата» of the quick buttons: the first message, not the newest one (performScrollToTop).
    GGChatScreenHooks.scrollToStartOfHistory = { controller in
        (controller as? ChatControllerImpl)?.scrollToStartOfHistory()
    }
    GGFeatures.registerAll()
    GGCore.runGlobalMigrations()
    GGHookRegistry.freeze()
}

func ggApplicationDidBecomeActive() {
    GGForegroundTaskScheduler.shared.applicationDidBecomeActive()
    GGLifecycleHooks.notifyDidBecomeActive()
}

func ggApplicationWillResignActive() {
    GGForegroundTaskScheduler.shared.applicationWillResignActive()
    GGSettingsStore.shared.flush()
    GGLifecycleHooks.notifyWillResignActive()
}

func ggApplicationDidEnterBackground() {
    GGForegroundTaskScheduler.shared.applicationWillResignActive()
    GGSettingsStore.shared.flush()
    GGLifecycleHooks.notifyDidEnterBackground()
}

/// GHOST hook target: SharedAccountContext, whenever the app's PresentationData strings change.
func ggTelegramLanguageDidChange(_ presentationData: PresentationData) {
    // A custom language pack has its own code; its base language decides then (not English).
    GGLocalization.shared.setTelegramLanguageCode(presentationData.strings.primaryComponent.languageCode, baseCode: presentationData.strings.baseLanguageCode)
}

// MARK: - Chat screen

func ggChatScreen(_ controller: ChatControllerImpl) -> GGChatScreen {
    var isPreview = false
    if case .standard(.previewing) = controller.presentationInterfaceState.mode {
        isPreview = true
    }
    return GGChatScreen(context: controller.context, chatLocation: controller.chatLocation, controller: controller, isPreview: isPreview)
}

private var ggChatOverlaysKey: UInt8 = 0

private final class GGChatOverlaysBox: NSObject {
    let overlays: [GGChatOverlay]

    init(overlays: [GGChatOverlay]) {
        self.overlays = overlays
    }
}

/// GHOST hook target: ChatControllerNode.init, after the wallpaper and the history are added.
func ggInstallChatOverlays(_ node: ChatControllerNode, context: AccountContext, chatLocation: ChatLocation, controller: ChatControllerImpl?) {
    if GGChatScreenHooks.overlays.isEmpty {
        return
    }
    var isPreview = false
    if let controller, case .standard(.previewing) = controller.presentationInterfaceState.mode {
        isPreview = true
    }
    let overlays = GGChatScreenHooks.makeOverlays(GGChatScreen(context: context, chatLocation: chatLocation, controller: controller, isPreview: isPreview))
    if overlays.isEmpty {
        return
    }
    for overlay in overlays {
        switch overlay.placement {
        case .aboveWallpaper:
            node.backgroundNode.supernode?.insertSubnode(overlay.node, aboveSubnode: node.backgroundNode)
        case .aboveHistory:
            node.historyNodeContainer.supernode?.insertSubnode(overlay.node, aboveSubnode: node.historyNodeContainer)
        }
    }
    objc_setAssociatedObject(node, &ggChatOverlaysKey, GGChatOverlaysBox(overlays: overlays), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// GHOST hook target: ChatControllerNode.containerLayoutUpdated, next to the wallpaper frame.
func ggLayoutChatOverlays(_ node: ChatControllerNode, bounds: CGRect, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
    guard let box = objc_getAssociatedObject(node, &ggChatOverlaysKey) as? GGChatOverlaysBox else {
        return
    }
    for overlay in box.overlays {
        transition.updateFrame(node: overlay.node, frame: bounds)
        overlay.updateLayout(bounds: bounds, insets: insets, transition: transition)
    }
}

private var ggChatChromeCaptureKey: UInt8 = 0

/// GHOST hook target: ChatControllerNode.containerLayoutUpdated, after upstream's own capture
/// protection. Hides the chat's chrome (header, input panel, the panels over it, navigation buttons,
/// overlays above the history) from screenshots and recordings while a feature asks for it
/// (GGChatScreenHooks.hidesChromeFromCapture). The layers are only touched when the answer changes.
func ggUpdateChatChromeCaptureProtection(_ node: ChatControllerNode) {
    if GGChatScreenHooks.hidesChromeFromCapture.isEmpty {
        return
    }
    let hides = GGChatScreenHooks.hidesChromeFromCapture(context: node.context, chatLocation: node.chatLocation)
    let applied = (objc_getAssociatedObject(node, &ggChatChromeCaptureKey) as? NSNumber)?.boolValue ?? false
    if hides == applied {
        return
    }
    objc_setAssociatedObject(node, &ggChatChromeCaptureKey, NSNumber(value: hides), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    var layers: [CALayer] = [node.inputPanelContainerNode.layer, node.inputContextPanelContainer.layer, node.navigateButtons.layer]
    if let navigationBar = node.navigationBar {
        layers.append(navigationBar.layer)
    }
    if let box = objc_getAssociatedObject(node, &ggChatOverlaysKey) as? GGChatOverlaysBox {
        for overlay in box.overlays where overlay.placement == .aboveHistory {
            layers.append(overlay.node.layer)
        }
    }
    for layer in layers {
        setLayerDisableScreenshots(layer, hides)
    }
}

/// GHOST hook target: ChatControllerNode.shouldAnimateMessageTransition — no send animation while the
/// chrome is hidden from capture (the animation carries the typed text through unprotected layers).
func ggChatChromeHiddenFromCapture(_ node: ChatControllerNode) -> Bool {
    return (objc_getAssociatedObject(node, &ggChatChromeCaptureKey) as? NSNumber)?.boolValue ?? false
}

/// GHOST hook target: ChatControllerNode.sendCurrentMessage. `true` = a feature took over the send.
func ggInterceptSendCurrentMessage(_ node: ChatControllerNode, proceed: @escaping () -> Void) -> Bool {
    if GGChatScreenHooks.willSendText.isEmpty {
        return false
    }
    guard let textInputPanelNode = node.textInputPanelNode else {
        return false
    }
    return GGChatScreenHooks.interceptSend(owner: node, request: GGComposedTextRequest(
        context: node.context,
        chatLocation: node.chatLocation,
        state: textInputPanelNode.inputTextState,
        replace: { [weak node] state in
            node?.interfaceInteraction?.updateTextInputStateAndMode({ _, mode in
                return (state, mode)
            })
        }
    ), proceed: proceed)
}

/// GHOST hook target: ChatMessageDisplaySendMessageOptions — features' items at the end of the
/// Send button's menu (GGChatScreenHooks.sendMenuItems).
func ggSendMenuItems(_ selfController: ChatControllerImpl) -> [ContextMenuItem] {
    guard let peerId = selfController.chatLocation.peerId else {
        return []
    }
    return GGChatScreenHooks.sendMenuItems(GGSendMenuContext(
        context: selfController.context,
        peerId: peerId,
        predictedLanguage: selfController.contentData?.state.translationState?.fromLang,
        inputText: selfController.presentationInterfaceState.interfaceState.effectiveInputState.inputText,
        replaceInput: { [weak selfController] text in
            selfController?.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                return state.updatedInterfaceState { interfaceState in
                    return interfaceState.withUpdatedComposeInputState(ChatTextInputState(inputText: text))
                }
            })
        },
        dismiss: { [weak selfController] in
            selfController?.sendMessageActionsController?.dismiss()
        },
        present: { [weak selfController] controller in
            selfController?.present(controller, in: .window(.root))
        }
    ))
}

/// GHOST hook target: OpenChatMessage — a downloaded document a feature may open itself
/// (GGChatScreenHooks.openDocument). nil when the file is not downloaded or has no name.
func ggOpenDocumentRequest(_ params: OpenChatMessageParams, file: TelegramMediaFile) -> GGOpenDocumentRequest? {
    guard let fileName = file.fileName, let path = params.context.account.postbox.mediaBox.completedResourcePath(file.resource) else {
        return nil
    }
    return GGOpenDocumentRequest(context: params.context, fileName: fileName, path: path, controller: params.navigationController?.topViewController as? ViewController)
}

// MARK: - Message decoration redraws

private var ggHistoryRedrawKey: UInt8 = 0

private final class GGHistoryRedrawSubscription {
    let disposable: Disposable

    init(disposable: Disposable) {
        self.disposable = disposable
    }

    deinit {
        self.disposable.dispose()
    }
}

/// GHOST hook target: ChatHistoryListNodeImpl.init. Re-lays out the bubbles a feature asked for
/// with GGMessageDecorationHooks.redraw(messageIds:), and every visible bubble after a settings
/// change (a chat under the settings screen must not keep stale decorations until its history
/// updates). The subscriptions live as long as the node.
func ggObserveMessageDecorationRedraws(_ node: ChatHistoryListNodeImpl) {
    if !GGMessageDecorationHooks.needsRedraws {
        return
    }
    let disposables = DisposableSet()
    disposables.add((GGMessageDecorationHooks.redrawRequests
    |> deliverOnMainQueue).start(next: { [weak node] messageIds in
        guard let node else {
            return
        }
        for messageId in messageIds {
            node.requestMessageUpdate(messageId)
        }
    }))
    // The first value is the current revision (the node was just created): skip it. Bursts of
    // changes (a slider, an import, `redrawAll()`) re-lay out once, 0.3 s after the last one.
    let pendingRedraw = MetaDisposable()
    disposables.add(pendingRedraw)
    let scheduleRedrawOfVisibleMessages: () -> Void = { [weak node] in
        pendingRedraw.set((Signal<Void, NoError>.single(Void())
        |> delay(0.3, queue: Queue.mainQueue())).start(next: { _ in
            guard let node else {
                return
            }
            var messageIds: [EngineMessage.Id] = []
            node.forEachVisibleMessageItemNode { itemNode in
                if let item = itemNode.item {
                    messageIds.append(item.message.id)
                }
            }
            for messageId in messageIds {
                node.requestMessageUpdate(messageId)
            }
        }))
    }
    var isFirstRevision = true
    disposables.add((GGMessageDecorationHooks.settingsRevisions
    |> deliverOnMainQueue).start(next: { _ in
        if isFirstRevision {
            isFirstRevision = false
            return
        }
        scheduleRedrawOfVisibleMessages()
    }))
    disposables.add((GGMessageDecorationHooks.redrawAllRequests
    |> deliverOnMainQueue).start(next: { _ in
        scheduleRedrawOfVisibleMessages()
    }))
    objc_setAssociatedObject(node, &ggHistoryRedrawKey, GGHistoryRedrawSubscription(disposable: disposables), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}
