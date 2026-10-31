// Compiled into ChatTextInputActionButtonsNode (filegroup
// //Ghostgram/Features/Interface:ChatTextInputActionButtonsNodePointSources). Owner: W2-5.
// The lowest module of the composers W2-5 owns: the chat panel (ChatTextInputPanelNode) and the
// story / gift composer (MessageInputPanelComponent) both depend on it.

import Foundation
import UIKit
import Display
import TelegramPresentationData
import GGCore

/// Geometry of the chat input panel («Редактор поля ввода»): applied once per `updateLayout` of
/// the panel from this one value. `.zero` = Telegram's layout.
public struct GGInputBarLayoutGeometry: Equatable {
    /// Extra height of the text field.
    public var heightPadding: CGFloat
    /// Insets of the text field from the panel's edges (the buttons move with them).
    public var leftMargin: CGFloat
    public var rightMargin: CGFloat
    /// Lift of the whole panel above the bottom edge.
    public var bottomOffset: CGFloat
    /// Free offsets of the attachment, accessory (emoji / stickers) and send / record buttons.
    public var attachOffset: CGPoint
    public var accessoryOffset: CGPoint
    public var sendOffset: CGPoint

    public init(heightPadding: CGFloat, leftMargin: CGFloat, rightMargin: CGFloat, bottomOffset: CGFloat, attachOffset: CGPoint, accessoryOffset: CGPoint, sendOffset: CGPoint) {
        self.heightPadding = heightPadding
        self.leftMargin = leftMargin
        self.rightMargin = rightMargin
        self.bottomOffset = bottomOffset
        self.attachOffset = attachOffset
        self.accessoryOffset = accessoryOffset
        self.sendOffset = sendOffset
    }

    public static let zero = GGInputBarLayoutGeometry(heightPadding: 0.0, leftMargin: 0.0, rightMargin: 0.0, bottomOffset: 0.0, attachOffset: CGPoint(), accessoryOffset: CGPoint(), sendOffset: CGPoint())
}

/// What the formatting toolbar needs from a composer after its layout (main thread).
///
/// The toolbar is a subview of the composer's own view, right above its top edge: the composer's
/// parent sets the composer's frame only after the composer's layout, so a toolbar placed by that
/// frame in the parent was one layout behind — over the field when it grew, high above it when it
/// shrank, under the keyboard while it came up (owner, build 189). The composer passes the touches
/// over its top edge to it (`ggFormattingToolbarHitTest`, `GGInputPanelHooks.overlayHitTest`).
public struct GGFormattingToolbarRequest {
    /// The composer's own view; the toolbar becomes its subview.
    public let hostView: UIView
    /// The composer's content in `hostView`'s coordinates; the toolbar sits right above it.
    public let panelFrame: CGRect
    /// The composer's text input is the first responder.
    public let isFocused: Bool
    public let theme: PresentationTheme
    public let transition: ContainedViewLayoutTransition

    public init(hostView: UIView, panelFrame: CGRect, isFocused: Bool, theme: PresentationTheme, transition: ContainedViewLayoutTransition) {
        self.hostView = hostView
        self.panelFrame = panelFrame
        self.isFocused = isFocused
        self.theme = theme
        self.transition = transition
    }
}

/// What a toolbar placed UNDER the chat composer's text field needs, during the panel's layout
/// (main thread). The toolbar becomes part of the panel: it sits between the text field and the
/// keyboard, and the panel grows by the height the handler returns.
public struct GGInputBarAccessoryRequest {
    /// The panel's own view; the toolbar is its subview, so it moves with the panel.
    public let hostView: UIView
    /// The laid-out text field row in `hostView` (side insets applied); the toolbar goes below it.
    public let contentFrame: CGRect
    /// The text input is the first responder and the panel shows the text field.
    public let isFocused: Bool
    public let theme: PresentationTheme
    public let transition: ContainedViewLayoutTransition
    /// Quotes and spoilers may be applied (false in secret chats, as Telegram's own Format menu).
    public let allowsQuoteAndSpoiler: Bool

    public init(hostView: UIView, contentFrame: CGRect, isFocused: Bool, theme: PresentationTheme, transition: ContainedViewLayoutTransition, allowsQuoteAndSpoiler: Bool = true) {
        self.hostView = hostView
        self.contentFrame = contentFrame
        self.isFocused = isFocused
        self.theme = theme
        self.transition = transition
        self.allowsQuoteAndSpoiler = allowsQuoteAndSpoiler
    }
}

public enum GGInputBarHooks {
    /// Provider of the panel geometry (first registered wins). Asked once per panel layout:
    /// answer from a snapshot.
    public static let geometry = GGHookPoint<() -> GGInputBarLayoutGeometry>("inputBar.geometry")

    /// Observers that place the formatting toolbar (SG-F11) — one implementation for every
    /// composer. Every composer calls this after its layout.
    public static let formattingToolbar = GGHookPoint<(GGFormattingToolbarRequest) -> Void>("inputBar.formattingToolbar")

    /// Handlers that place a toolbar under the chat composer's text field (SG-F11) and return the
    /// height it takes (0 = none). Asked on every layout of the chat panel; the largest answer wins.
    public static let bottomAccessory = GGHookPoint<(GGInputBarAccessoryRequest) -> CGFloat>("inputBar.bottomAccessory")

    /// Policy: the view of the formatting toolbar a composer's view (`hostView`) holds over its top edge
    /// that takes a touch at `point` (in `hostView`), nil = none. Asked first by the composer's hitTest.
    public static let toolbarHitTest = GGHookPoint<(UIView, CGPoint, UIEvent?) -> UIView?>("inputBar.toolbarHitTest")
}

public func ggInputBarBottomAccessoryHeight(_ request: @autoclosure () -> GGInputBarAccessoryRequest) -> CGFloat {
    if GGInputBarHooks.bottomAccessory.isEmpty {
        return 0.0
    }
    let value = request()
    var height: CGFloat = 0.0
    for handler in GGInputBarHooks.bottomAccessory.handlers {
        height = max(height, handler(value))
    }
    return height
}

public func ggInputBarGeometry() -> GGInputBarLayoutGeometry {
    if GGInputBarHooks.geometry.isEmpty {
        return .zero
    }
    return GGInputBarHooks.geometry.handlers[0]()
}

public func ggFormattingToolbarHitTest(_ hostView: UIView, point: CGPoint, event: UIEvent?) -> UIView? {
    for handler in GGInputBarHooks.toolbarHitTest.handlers {
        if let result = handler(hostView, point, event) {
            return result
        }
    }
    return nil
}

public func ggUpdateFormattingToolbar(_ request: @autoclosure () -> GGFormattingToolbarRequest) {
    if GGInputBarHooks.formattingToolbar.isEmpty {
        return
    }
    let value = request()
    for handler in GGInputBarHooks.formattingToolbar.handlers {
        handler(value)
    }
}
