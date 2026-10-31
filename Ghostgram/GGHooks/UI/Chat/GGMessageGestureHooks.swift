// Multi-tap gestures on a message bubble: double tap (instead of the quick reaction) and triple
// tap. One point for every feature that reacts to them (double tap → edit, triple tap → delete).
// Call site: ChatMessageBubbleItemNode (the double-tap branches of its tap recognizer; a triple-tap
// recognizer is added to a bubble only when the point has handlers). While a feature wants triple
// taps (`wantsTripleTap`), the double tap waits for the triple-tap recognizer to fail.

import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import AsyncDisplayKit
import Display
import Postbox
import TelegramCore
import AccountContext
import GGCore

public struct GGMessageTapRequest {
    public let message: Message
    public let context: AccountContext
    /// 2 or 3.
    public let tapCount: Int
    /// The chat screen's node (`ChatControllerInteraction.chatControllerNode()`), for actions.
    public weak var chatNode: ASDisplayNode?

    public init(message: Message, context: AccountContext, tapCount: Int, chatNode: ASDisplayNode?) {
        self.message = message
        self.context = context
        self.tapCount = tapCount
        self.chatNode = chatNode
    }

    /// Starts editing the message in the chat's input panel. `false` when the chat can not.
    public func startEditing() -> Bool {
        guard let chatNode = self.chatNode, let editMessage = GGMessageGestureHooks.editMessage else {
            return false
        }
        return editMessage(chatNode, self.message.id)
    }
}

public enum GGMessageGestureHooks {
    /// Policy: `true` = handled, the bubble does nothing else (no quick reaction). Main thread.
    public static let tap = GGHookPoint<(GGMessageTapRequest) -> Bool>("messageGesture.tap")

    /// Policy (any `true`): a feature acts on a triple tap on this message right now. While one does,
    /// the bubble's double tap (the quick reaction, a feature's double tap) waits until no third tap
    /// came — otherwise the second tap of a triple tap already sent the reaction. Main thread; answer
    /// from a snapshot.
    public static let wantsTripleTap = GGHookPoint<(Message) -> Bool>("messageGesture.wantsTripleTap")

    /// Set once by the app (TelegramUI launch): starts editing a message on a chat screen node.
    public static var editMessage: ((ASDisplayNode, EngineMessage.Id) -> Bool)?

    /// `true` = a feature handled the tap.
    public static func handleTap(message: Message, context: AccountContext, tapCount: Int, chatNode: ASDisplayNode?) -> Bool {
        if GGMessageGestureHooks.tap.isEmpty {
            return false
        }
        let request = GGMessageTapRequest(message: message, context: context, tapCount: tapCount, chatNode: chatNode)
        for handler in GGMessageGestureHooks.tap.handlers {
            if handler(request) {
                return true
            }
        }
        return false
    }

    public static func isTripleTapWanted(message: Message) -> Bool {
        if GGMessageGestureHooks.wantsTripleTap.isEmpty {
            return false
        }
        for handler in GGMessageGestureHooks.wantsTripleTap.handlers {
            if handler(message) {
                return true
            }
        }
        return false
    }

    /// A triple-tap recognizer for a bubble, or nil when no feature handles taps (then a bubble
    /// gets no extra recognizer at all). It recognizes alongside the bubble's own tap recognizer.
    /// `action` returns `true` when a feature took the triple tap: then the bubble's own recognizer,
    /// waiting to report the third tap as a single tap (opening media and the like), is cancelled.
    public static func makeTripleTapRecognizer(_ action: @escaping () -> Bool) -> UITapGestureRecognizer? {
        if GGMessageGestureHooks.tap.isEmpty {
            return nil
        }
        return GGMessageTripleTapRecognizer(action: action)
    }

    /// Holds a bubble's double tap back until its triple-tap recognizer (on `view`) is done: `action`
    /// runs once that recognizer failed — no third tap came — and never when it recognized. `false`
    /// when `view` has no such recognizer (the caller then acts at once). Main thread.
    public static func deferDoubleTap(on view: UIView, _ action: @escaping () -> Void) -> Bool {
        guard let recognizer = view.gestureRecognizers?.first(where: { $0 is GGMessageTripleTapRecognizer }) as? GGMessageTripleTapRecognizer else {
            return false
        }
        recognizer.deferDoubleTap(action)
        return true
    }
}

private final class GGMessageTripleTapRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    /// UIKit's tap recognizer fails about 0.35 s after a tap with no next one; this is the backstop
    /// for a recognizer that never resets (its view left the screen).
    private static let pendingTimeout: Double = 0.8

    private let action: () -> Bool
    private var pendingDoubleTap: (() -> Void)?
    private var pendingTimer: Foundation.Timer?

    init(action: @escaping () -> Bool) {
        self.action = action
        super.init(target: nil, action: nil)
        self.addTarget(self, action: #selector(self.recognized))
        self.numberOfTapsRequired = 3
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
        self.delegate = self
    }

    func deferDoubleTap(_ action: @escaping () -> Void) {
        self.pendingTimer?.invalidate()
        self.pendingDoubleTap = action
        let timer = Foundation.Timer(timeInterval: GGMessageTripleTapRecognizer.pendingTimeout, repeats: false, block: { [weak self] _ in
            self?.runPendingDoubleTap()
        })
        self.pendingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The double tap that waited for this recognizer, now that no third tap came.
    private func runPendingDoubleTap() {
        self.pendingTimer?.invalidate()
        self.pendingTimer = nil
        guard let action = self.pendingDoubleTap else {
            return
        }
        self.pendingDoubleTap = nil
        action()
    }

    @objc private func recognized() {
        guard self.state == .ended else {
            return
        }
        // The third tap came: the double tap that waited for it is dropped.
        self.pendingTimer?.invalidate()
        self.pendingTimer = nil
        self.pendingDoubleTap = nil
        if self.action() {
            // The third tap is not also a single tap of the bubble.
            for recognizer in self.view?.gestureRecognizers ?? [] {
                if let recognizer = recognizer as? TapLongTapOrDoubleTapGestureRecognizer, recognizer.state == .began {
                    recognizer.cancel()
                }
            }
        }
    }

    override func reset() {
        super.reset()
        // Failed (no third tap) or done: a double tap still waiting runs now, off the gesture pass.
        if self.pendingDoubleTap != nil {
            DispatchQueue.main.async { [weak self] in
                self?.runPendingDoubleTap()
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
