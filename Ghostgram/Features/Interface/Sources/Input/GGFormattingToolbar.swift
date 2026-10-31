import Foundation
import ChatTextInputPanelNode
import AttachmentTextInputPanelNode
import AsyncDisplayKit
import UIKit
import ObjectiveC
import Display
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import ChatInputTextNode
import TextFieldComponent
import ChatTextInputActionButtonsNode
import ComponentFlow
import GlassBackgroundComponent
import GGCore

private var ggFormattingToolbarKey: UInt8 = 0

/// SG-F11: one formatting toolbar for every composer (chat, attachment caption, story reply,
/// gift message). A button formats through the composer it belongs to (the toolbar is that
/// composer's subview), with the composer's own format code — never through the responder chain:
/// the text views answer `formatAttributes*:` only while the legacy Format submenu is open, so an
/// action sent to the first responder was lost. Nothing selected → the word before the caret.
///
/// In the chat it is part of the input panel, UNDER the text field — between the field and the
/// keyboard, as in Swiftgram (owner, 2026-10-27; above the field it covered the last messages and
/// jumped while the keyboard animated). The other composers (attachment and media caption, story
/// reply, gift message) get it right above their field, as a subview of the composer over its top
/// edge, so it moves with the composer (`GGFormattingToolbarRequest`).
final class GGFormattingToolbar: UIView {
    private enum Format {
        case bold
        case italic
        case underline
        case strikethrough
        case monospace
        case spoiler
        case quote
        case link
    }

    private struct Action {
        let format: Format
        let symbol: String
    }

    private static let actions: [Action] = [
        Action(format: .bold, symbol: "bold"),
        Action(format: .italic, symbol: "italic"),
        Action(format: .underline, symbol: "underline"),
        Action(format: .strikethrough, symbol: "strikethrough"),
        Action(format: .monospace, symbol: "chevron.left.forwardslash.chevron.right"),
        Action(format: .spoiler, symbol: "eye.slash"),
        Action(format: .quote, symbol: "text.quote"),
        Action(format: .link, symbol: "link")
    ]

    /// The buttons' symbols in order (the «Панели» preview draws the same toolbar).
    static var symbolNames: [String] {
        return GGFormattingToolbar.actions.map { $0.symbol }
    }

    static let height: CGFloat = 40.0
    /// Gap between the text field and the toolbar, and under the toolbar (chat panel).
    private static let spacing: CGFloat = 6.0

    /// The same glass as the composer's text field.
    private let backgroundView: GlassBackgroundView
    private let buttonsContainer: UIView
    private var buttons: [UIButton] = []
    private var currentTheme: PresentationTheme?
    /// False in secret chats: quotes and spoilers are not offered there (Telegram's Format menu).
    private var allowsQuoteAndSpoiler = true

    override init(frame: CGRect) {
        self.backgroundView = GlassBackgroundView()
        self.buttonsContainer = UIView()
        super.init(frame: frame)
        self.addSubview(self.backgroundView)
        self.addSubview(self.buttonsContainer)
        for (index, action) in GGFormattingToolbar.actions.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setImage(UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)), for: .normal)
            button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
            self.buttonsContainer.addSubview(button)
            self.buttons.append(button)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func buttonPressed(_ sender: UIButton) {
        guard sender.tag >= 0 && sender.tag < GGFormattingToolbar.actions.count, let host = self.superview else {
            return
        }
        let format = GGFormattingToolbar.actions[sender.tag].format
        if let panel = host.asyncdisplaykit_node as? ChatTextInputPanelNode {
            if !self.allowsQuoteAndSpoiler && (format == .quote || format == .spoiler) {
                return
            }
            GGFormattingToolbar.perform(format, chatPanel: panel)
        } else if let panel = host.asyncdisplaykit_node as? AttachmentTextInputPanelNode {
            GGFormattingToolbar.perform(format, attachmentPanel: panel)
        } else if let field = GGFormattingToolbar.focusedTextField(in: host, depth: 0) {
            GGFormattingToolbar.perform(format, textField: field)
        }
    }

    // MARK: Formatting through the composer

    /// The chat composer: the native editor applies a format through its own engine (as its edit
    /// menu does); the legacy field through the panel's `formatAttributes*`, which edit the
    /// composer state.
    private static func perform(_ format: Format, chatPanel panel: ChatTextInputPanelNode) {
        if let input = panel.richTextInputNode, input.usesNativeRichTextEngine {
            if input.selectedRange.length == 0, let text = input.attributedText?.string, let word = GGFormattingSelection.lastWordRange(in: text as NSString, caret: input.selectedRange.location) {
                input.selectedRange = word
            }
            switch format {
            case .bold:
                input.performFormatAction(.bold)
            case .italic:
                input.performFormatAction(.italic)
            case .underline:
                input.performFormatAction(.underline)
            case .strikethrough:
                input.performFormatAction(.strikethrough)
            case .monospace:
                input.performFormatAction(.monospace)
            case .spoiler:
                input.performFormatAction(.spoiler)
            case .quote:
                input.performFormatAction(.quote)
            case .link:
                panel.interfaceInteraction?.openLinkEditing()
            }
            return
        }
        GGFormattingToolbar.selectLastWordIfIdle(panel.interfaceInteraction)
        switch format {
        case .bold:
            panel.formatAttributesBold(panel)
        case .italic:
            panel.formatAttributesItalic(panel)
        case .underline:
            panel.formatAttributesUnderline(panel)
        case .strikethrough:
            panel.formatAttributesStrikethrough(panel)
        case .monospace:
            panel.formatAttributesMonospace(panel)
        case .spoiler:
            panel.formatAttributesSpoiler(panel)
        case .quote:
            panel.formatAttributesQuote(panel)
        case .link:
            panel.formatAttributesLink(panel)
        }
    }

    /// The attachment / media caption: its `formatAttributes*` (internal to its module, reached
    /// through the Objective-C runtime) edit the caption state the same way.
    private static func perform(_ format: Format, attachmentPanel panel: AttachmentTextInputPanelNode) {
        let selectorName: String
        switch format {
        case .bold:
            selectorName = "formatAttributesBold:"
        case .italic:
            selectorName = "formatAttributesItalic:"
        case .underline:
            selectorName = "formatAttributesUnderline:"
        case .strikethrough:
            selectorName = "formatAttributesStrikethrough:"
        case .monospace:
            selectorName = "formatAttributesMonospace:"
        case .spoiler:
            selectorName = "formatAttributesSpoiler:"
        case .quote:
            selectorName = "formatAttributesQuote:"
        case .link:
            selectorName = "formatAttributesLink:"
        }
        let selector = NSSelectorFromString(selectorName)
        guard panel.responds(to: selector) else {
            return
        }
        GGFormattingToolbar.selectLastWordIfIdle(panel.interfaceInteraction)
        let _ = panel.perform(selector, with: panel)
    }

    /// Story reply and gift message: the field's own Format menu code, with its availability.
    private static func perform(_ format: Format, textField: TextFieldComponent.View) {
        let action: TextFieldComponent.FormatMenuAvailability.Action
        switch format {
        case .bold:
            action = .bold
        case .italic:
            action = .italic
        case .underline:
            action = .underline
        case .strikethrough:
            action = .strikethrough
        case .monospace:
            action = .monospace
        case .spoiler:
            action = .spoiler
        case .quote:
            action = .quote
        case .link:
            action = .link
        }
        if case let .available(actions) = textField.ggFormatMenuAvailability, actions.contains(action) {
            let state = textField.inputState
            if state.selectionRange.isEmpty, let word = GGFormattingSelection.lastWordRange(in: state.inputText.string as NSString, caret: state.selectionRange.lowerBound) {
                textField.updateText(state.inputText, selectionRange: word.location ..< (word.location + word.length))
            }
        }
        textField.ggPerformFormat(action)
    }

    /// The composer state's selection becomes the word before the caret when nothing is selected.
    private static func selectLastWordIfIdle(_ interfaceInteraction: ChatPanelInterfaceInteraction?) {
        interfaceInteraction?.updateTextInputStateAndMode { current, inputMode in
            let selection = current.selectionRange
            guard selection.isEmpty, let word = GGFormattingSelection.lastWordRange(in: current.inputText.string as NSString, caret: selection.lowerBound) else {
                return (current, inputMode)
            }
            return (ChatTextInputState(content: current.content, selectionRange: word.location ..< (word.location + word.length)), inputMode)
        }
    }

    /// The focused field of a story / gift composer (the toolbar's host), at most a few levels down.
    private static func focusedTextField(in view: UIView, depth: Int) -> TextFieldComponent.View? {
        if let field = view as? TextFieldComponent.View, field.hasFirstResponder() {
            return field
        }
        if depth >= 6 {
            return nil
        }
        for subview in view.subviews {
            if subview is GGFormattingToolbar {
                continue
            }
            if let field = GGFormattingToolbar.focusedTextField(in: subview, depth: depth + 1) {
                return field
            }
        }
        return nil
    }

    private func apply(theme: PresentationTheme, width: CGFloat) {
        if self.currentTheme !== theme {
            self.currentTheme = theme
            for button in self.buttons {
                button.tintColor = theme.chat.inputPanel.panelControlColor
            }
        }
        for (index, button) in self.buttons.enumerated() {
            let format = GGFormattingToolbar.actions[index].format
            button.isEnabled = self.allowsQuoteAndSpoiler || (format != .quote && format != .spoiler)
        }
        let inset: CGFloat = 4.0
        let size = CGSize(width: width, height: GGFormattingToolbar.height)
        self.backgroundView.frame = CGRect(origin: CGPoint(), size: size)
        self.backgroundView.update(size: size, cornerRadius: size.height * 0.5, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
        self.buttonsContainer.frame = CGRect(origin: CGPoint(), size: size)
        let buttonWidth = floor((width - inset * 2.0) / CGFloat(self.buttons.count))
        for (index, button) in self.buttons.enumerated() {
            button.frame = CGRect(x: inset + CGFloat(index) * buttonWidth, y: 0.0, width: buttonWidth, height: GGFormattingToolbar.height)
        }
    }

    static func hasToolbar(_ hostView: UIView?) -> Bool {
        guard let hostView else {
            return false
        }
        return objc_getAssociatedObject(hostView, &ggFormattingToolbarKey) != nil
    }

    /// The chat panel: places the toolbar under the text field (inside the panel) and returns the
    /// height it adds to the panel, or removes it and returns 0.
    static func layoutBelow(_ request: GGInputBarAccessoryRequest) -> CGFloat {
        let existing = objc_getAssociatedObject(request.hostView, &ggFormattingToolbarKey) as? GGFormattingToolbar
        guard InterfaceSnapshots.shared.current.formattingToolbar && request.isFocused else {
            if let existing {
                objc_setAssociatedObject(request.hostView, &ggFormattingToolbarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                request.transition.updateAlpha(layer: existing.layer, alpha: 0.0, completion: { [weak existing] _ in
                    existing?.removeFromSuperview()
                })
            }
            return 0.0
        }
        let sideInset: CGFloat = 8.0
        let width = max(0.0, request.contentFrame.width - sideInset * 2.0)
        let frame = CGRect(x: request.contentFrame.minX + sideInset, y: request.contentFrame.maxY + GGFormattingToolbar.spacing, width: width, height: GGFormattingToolbar.height)
        if let existing {
            existing.allowsQuoteAndSpoiler = request.allowsQuoteAndSpoiler
            existing.apply(theme: request.theme, width: width)
            request.transition.updateFrame(view: existing, frame: frame)
        } else {
            // A new toolbar appears where it belongs and fades in; it never flies in from a stale frame.
            let toolbar = GGFormattingToolbar(frame: frame)
            toolbar.allowsQuoteAndSpoiler = request.allowsQuoteAndSpoiler
            toolbar.apply(theme: request.theme, width: width)
            request.hostView.addSubview(toolbar)
            objc_setAssociatedObject(request.hostView, &ggFormattingToolbarKey, toolbar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if request.transition.isAnimated {
                toolbar.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
        return GGFormattingToolbar.spacing + GGFormattingToolbar.height + GGFormattingToolbar.spacing
    }

    /// The toolbar a composer holds over its top edge, if it takes a touch at `point` (in `hostView`).
    static func hitTest(in hostView: UIView, point: CGPoint, event: UIEvent?) -> UIView? {
        guard let toolbar = objc_getAssociatedObject(hostView, &ggFormattingToolbarKey) as? GGFormattingToolbar, toolbar.superview === hostView, !toolbar.isHidden, toolbar.alpha > 0.0 else {
            return nil
        }
        return toolbar.hitTest(hostView.convert(point, to: toolbar), with: event)
    }

    /// Places, shows or removes the toolbar of one composer (a subview of it, over its top edge).
    static func update(_ request: GGFormattingToolbarRequest) {
        let existing = objc_getAssociatedObject(request.hostView, &ggFormattingToolbarKey) as? GGFormattingToolbar
        let isVisible = InterfaceSnapshots.shared.current.formattingToolbar && request.isFocused
        guard isVisible else {
            if let existing {
                objc_setAssociatedObject(request.hostView, &ggFormattingToolbarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                existing.removeFromSuperview()
            }
            return
        }
        let sideInset: CGFloat = 8.0
        let width = max(0.0, request.panelFrame.width - sideInset * 2.0)
        let frame = CGRect(x: request.panelFrame.minX + sideInset, y: request.panelFrame.minY - GGFormattingToolbar.height - 6.0, width: width, height: GGFormattingToolbar.height)
        if let existing {
            existing.apply(theme: request.theme, width: width)
            request.transition.updateFrame(view: existing, frame: frame)
        } else {
            // A new toolbar appears where it belongs; it never flies in from a zero frame.
            let toolbar = GGFormattingToolbar(frame: frame)
            toolbar.apply(theme: request.theme, width: width)
            request.hostView.addSubview(toolbar)
            objc_setAssociatedObject(request.hostView, &ggFormattingToolbarKey, toolbar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let toolbar = objc_getAssociatedObject(request.hostView, &ggFormattingToolbarKey) as? GGFormattingToolbar {
            request.hostView.bringSubviewToFront(toolbar)
        }
    }
}

/// «Анимация при вводе»: a short CA animation of the text field per keystroke (throttled), on
/// `transform` / `opacity` only. The glow is a pre-rendered image layer whose opacity animates —
/// no shadow is rendered per keystroke, and the glass background never moves. Off in Low Power
/// Mode.
struct GGTypingAnimationParameters: Equatable {
    static let presets = ["pulse", "wave", "panelWave", "neon", "shake", "custom"]

    var preset: String
    var intensity: Double
    var speed: Double
    var scale: Double
    var offset: Double
    var glow: Double
}

private var ggTypingAnimationStateKey: UInt8 = 0

private final class GGTypingAnimationState {
    var lastTimestamp: Double = 0.0
    var glowLayer: CALayer?
    var glowSize: CGSize = CGSize()
}

enum GGTypingAnimation {
    static func play(panel: ASDisplayNode) {
        // Throttle first: the snapshot is read only for keystrokes that animate.
        let state: GGTypingAnimationState
        if let current = objc_getAssociatedObject(panel, &ggTypingAnimationStateKey) as? GGTypingAnimationState {
            state = current
        } else {
            guard InterfaceSnapshots.shared.current.typingAnimation != nil else {
                return
            }
            state = GGTypingAnimationState()
            objc_setAssociatedObject(panel, &ggTypingAnimationStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let timestamp = CACurrentMediaTime()
        if timestamp - state.lastTimestamp < 0.12 {
            return
        }
        guard let parameters = InterfaceSnapshots.shared.current.typingAnimation else {
            state.glowLayer?.opacity = 0.0
            return
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return
        }
        let duration = 0.45 - 0.3 * (parameters.speed / 100.0)
        if timestamp - state.lastTimestamp < duration * 0.6 {
            return
        }
        state.lastTimestamp = timestamp

        let target: UIView
        var extra: [UIView] = []
        if let panel = panel as? ChatTextInputPanelNode {
            target = panel.textInputNodeClippingContainer
            if parameters.preset == "panelWave" {
                extra.append(panel.attachmentButton)
            }
        } else {
            target = panel.view
        }
        let amplitude = CGFloat(parameters.intensity / 100.0)
        switch parameters.preset {
        case "pulse":
            GGTypingAnimation.animateScale(target.layer, by: 0.02 + 0.06 * amplitude, duration: duration)
        case "wave", "panelWave":
            for view in [target] + extra {
                GGTypingAnimation.animateTranslation(view.layer, dx: 0.0, dy: -(1.0 + 4.0 * amplitude), duration: duration)
            }
        case "shake":
            GGTypingAnimation.animateShake(target.layer, amplitude: 1.0 + 3.0 * amplitude, duration: duration)
        case "neon":
            GGTypingAnimation.glow(state: state, around: target, color: GGTypingAnimation.accentColor(panel), strength: CGFloat(parameters.glow / 100.0), duration: duration)
        default:
            GGTypingAnimation.animateScale(target.layer, by: 0.04 * CGFloat(parameters.scale / 100.0), duration: duration)
            GGTypingAnimation.animateTranslation(target.layer, dx: 0.0, dy: -4.0 * CGFloat(parameters.offset / 100.0), duration: duration)
            if parameters.glow > 0.0 {
                GGTypingAnimation.glow(state: state, around: target, color: GGTypingAnimation.accentColor(panel), strength: CGFloat(parameters.glow / 100.0), duration: duration)
            }
        }
    }

    private static func accentColor(_ panel: ASDisplayNode) -> UIColor {
        if let panel = panel as? ChatTextInputPanelNode, let theme = panel.context?.sharedContext.currentPresentationData.with({ $0 }).theme {
            return theme.chat.inputPanel.panelControlAccentColor
        }
        return UIColor.systemBlue
    }

    private static func animateScale(_ layer: CALayer, by delta: CGFloat, duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.0 + delta, 1.0]
        animation.keyTimes = [0.0, 0.4, 1.0]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "gg.typing.scale")
    }

    private static func animateTranslation(_ layer: CALayer, dx: CGFloat, dy: CGFloat, duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation")
        animation.values = [NSValue(cgSize: CGSize()), NSValue(cgSize: CGSize(width: dx, height: dy)), NSValue(cgSize: CGSize())]
        animation.keyTimes = [0.0, 0.35, 1.0]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "gg.typing.translation")
    }

    private static func animateShake(_ layer: CALayer, amplitude: CGFloat, duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0.0, -amplitude, amplitude, -amplitude * 0.5, 0.0]
        animation.duration = duration
        layer.add(animation, forKey: "gg.typing.shake")
    }

    /// A blurred rounded rect rendered once per size and color, faded in and out around `view`.
    private static func glow(state: GGTypingAnimationState, around view: UIView, color: UIColor, strength: CGFloat, duration: Double) {
        guard let superview = view.superview else {
            return
        }
        let size = view.bounds.size
        let glowLayer: CALayer
        if let current = state.glowLayer {
            glowLayer = current
        } else {
            glowLayer = CALayer()
            glowLayer.opacity = 0.0
            state.glowLayer = glowLayer
        }
        if glowLayer.superlayer !== superview.layer {
            glowLayer.removeFromSuperlayer()
            superview.layer.insertSublayer(glowLayer, below: view.layer)
        }
        let padding: CGFloat = 12.0
        if state.glowSize != size {
            state.glowSize = size
            glowLayer.contents = generateImage(CGSize(width: size.width + padding * 2.0, height: size.height + padding * 2.0), rotatedContext: { contextSize, context in
                context.clear(CGRect(origin: CGPoint(), size: contextSize))
                context.setShadow(offset: CGSize(), blur: padding * 0.8, color: color.cgColor)
                context.setFillColor(color.withAlphaComponent(0.6).cgColor)
                context.addPath(UIBezierPath(roundedRect: CGRect(x: padding, y: padding, width: size.width, height: size.height), cornerRadius: min(size.height * 0.5, 20.0)).cgPath)
                context.fillPath()
            })?.cgImage
        }
        glowLayer.frame = view.frame.insetBy(dx: -padding, dy: -padding)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.0, Float(0.25 + 0.6 * strength), 0.0]
        animation.keyTimes = [0.0, 0.3, 1.0]
        animation.duration = duration * 1.4
        glowLayer.add(animation, forKey: "gg.typing.glow")
    }
}
