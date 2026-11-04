import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ComponentFlow
import GlassBackgroundComponent
import ChatTextInputActionButtonsNode
import GGCore
import GGFeaturesShared
import GGSettingsUI

/// «Расположение и размер» of the quick buttons: a full chat preview (`GGFullChatPreviewNode` — the
/// user's wallpaper and theme, real bubbles, the chat's header and input bar at the chat's own
/// measures) with the buttons on it. A button is dragged where it should stand; width and height
/// are two sliders in a glass card above the input bar, which folds away to free the bottom of the
/// chat. The old client did this inside a real chat; here no chat is opened.
///
/// A drop writes the positions of every shown button (none of them moves when another one appears
/// or is switched off later), a released slider writes the size; open chats follow at once
/// (`GGQuickButtonsOverlay` observes the settings).
final class GGQuickButtonsEditorController: ViewController {
    private let context: AccountContext
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?

    private var editorNode: GGQuickButtonsEditorNode {
        return self.displayNode as! GGQuickButtonsEditorNode
    }

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            let previous = self.presentationData
            if previous.theme === presentationData.theme && previous.strings === presentationData.strings && previous.chatWallpaper == presentationData.chatWallpaper && previous.chatFontSize == presentationData.chatFontSize {
                return
            }
            self.presentationData = presentationData
            self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
            if self.isNodeLoaded {
                self.editorNode.updatePresentationData(presentationData)
            }
        })
    }

    required init(coder aDecoder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        self.presentationDataDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = GGQuickButtonsEditorNode(context: self.context, presentationData: self.presentationData)
        self.editorNode.close = { [weak self] in
            if let navigationController = self?.navigationController as? NavigationController {
                let _ = navigationController.popViewController(animated: true)
            }
        }
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.editorNode.containerLayoutUpdated(layout, transition: transition)
    }
}

private final class GGQuickButtonsEditorNode: ASDisplayNode {
    var close: (() -> Void)?

    private let context: AccountContext
    private var presentationData: PresentationData
    private let chatNode: GGFullChatPreviewNode
    private let canvasView = GGQuickButtonsCanvasView()
    private let panelView = GGQuickButtonsSizePanel()
    private let emptyGlass = GlassBackgroundView()
    private let emptyLabel = UILabel()
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    /// Every button the user did not switch off — also those a given chat would not offer: their
    /// place is set here once for all chats.
    private let actions: [GGQuickAction]
    private var buttons: [String: GGQuickButtonView] = [:]
    private var positions: [String: [Double]]
    private var buttonSize: CGSize
    private var isPanelCollapsed = false

    private var validLayout: ContainerViewLayout?
    private var historyInsets = UIEdgeInsets()
    private var drag: (id: String, startCenter: CGPoint)?

    init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.presentationData = presentationData
        self.chatNode = GGFullChatPreviewNode(context: context)
        let hidden = Set(InterfaceSettings.bindButtonsHidden.value)
        self.actions = GGQuickActions.all.filter { !hidden.contains($0.id) }
        self.positions = InterfaceSettings.bindButtonsPositions.value
        self.buttonSize = GGQuickButtonsLayout.size()
        super.init()
        self.addSubnode(self.chatNode)
        self.chatNode.backPressed = { [weak self] in
            self?.close?()
        }
    }

    override func didLoad() {
        super.didLoad()

        self.view.addSubview(self.canvasView)
        for action in self.actions {
            let button = GGQuickButtonView(actionId: action.id)
            // Dragging a button sideways must not start the swipe back.
            button.disablesInteractiveTransitionGestureRecognizer = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
            pan.maximumNumberOfTouches = 1
            button.addGestureRecognizer(pan)
            self.canvasView.addSubview(button)
            self.buttons[action.id] = button
        }

        self.emptyGlass.isUserInteractionEnabled = false
        self.emptyGlass.isHidden = !self.actions.isEmpty
        self.view.addSubview(self.emptyGlass)
        self.emptyLabel.numberOfLines = 0
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.isHidden = !self.actions.isEmpty
        self.view.addSubview(self.emptyLabel)

        self.panelView.disablesInteractiveTransitionGestureRecognizer = true
        self.panelView.sizeChanged = { [weak self] size, isFinal in
            self?.sizeChanged(size, isFinal: isFinal)
        }
        self.panelView.resetPressed = { [weak self] in
            self?.reset()
        }
        self.panelView.collapsePressed = { [weak self] in
            guard let self else {
                return
            }
            self.isPanelCollapsed = !self.isPanelCollapsed
            self.layoutPanel(transition: .animated(duration: 0.3, curve: .spring))
        }
        self.view.addSubview(self.panelView)

        self.updateAppearance()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.updateAppearance()
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .immediate)
        }
    }

    private func updateAppearance() {
        let theme = self.presentationData.theme
        let actionContext = GGQuickActionContext(account: self.context.account, peerId: self.context.account.peerId, chatController: nil, accountContext: self.context)
        for action in self.actions {
            self.buttons[action.id]?.update(action: action, isOn: action.isOn?(actionContext) ?? false, theme: theme)
        }
        self.emptyLabel.attributedText = NSAttributedString(string: GGStrings.Interface.Binds.editorEmpty, font: Font.regular(15.0), textColor: theme.rootController.navigationBar.primaryTextColor)
        self.panelView.update(theme: theme, size: self.buttonSize)
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout
        let size = layout.size
        let geometry = ggInputBarGeometry()
        let statusBarHeight = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        self.historyInsets = self.chatNode.update(
            presentationData: self.presentationData,
            content: GGMiniChatContent.fullSample(header: GGMiniChatContent.sampleHeader()),
            accountPeer: nil,
            size: size,
            safeInsets: UIEdgeInsets(top: layout.safeInsets.top, left: layout.safeInsets.left, bottom: layout.intrinsicInsets.bottom, right: layout.safeInsets.right),
            statusBarHeight: statusBarHeight,
            inputBar: GGFullChatInputBar(leftMargin: geometry.leftMargin, rightMargin: geometry.rightMargin, lift: geometry.bottomOffset, extraHeight: geometry.heightPadding)
        )
        transition.updateFrame(node: self.chatNode, frame: CGRect(origin: CGPoint(), size: size))
        self.canvasView.frame = CGRect(origin: CGPoint(), size: size)
        self.layoutButtons(transition: transition)
        self.layoutPanel(transition: transition)

        if !self.emptyLabel.isHidden {
            let area = GGQuickButtonsLayout.area(bounds: size, insets: self.historyInsets)
            let textWidth = min(300.0, area.width - 40.0)
            let textSize = self.emptyLabel.sizeThatFits(CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
            let cardFrame = CGRect(x: floorToScreenPixels(area.midX - (textSize.width + 32.0) * 0.5), y: floorToScreenPixels(area.midY - (textSize.height + 24.0) * 0.5), width: textSize.width + 32.0, height: textSize.height + 24.0)
            self.emptyGlass.frame = cardFrame
            self.emptyGlass.update(size: cardFrame.size, cornerRadius: 20.0, isDark: self.presentationData.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
            self.emptyLabel.frame = CGRect(origin: CGPoint(x: cardFrame.minX + 16.0, y: cardFrame.minY + 12.0), size: textSize)
        }
    }

    private func layoutButtons(transition: ContainedViewLayoutTransition) {
        guard let layout = self.validLayout else {
            return
        }
        let frames = GGQuickButtonsLayout.frames(ids: self.actions.map { $0.id }, positions: self.positions, size: self.buttonSize, bounds: layout.size, insets: self.historyInsets)
        for action in self.actions {
            guard let button = self.buttons[action.id], let frame = frames[action.id] else {
                continue
            }
            // The button under the finger follows the finger only.
            if let drag = self.drag, drag.id == action.id {
                continue
            }
            transition.updateFrame(view: button, frame: frame)
        }
    }

    private func layoutPanel(transition: ContainedViewLayoutTransition) {
        guard let layout = self.validLayout else {
            return
        }
        let sideInset = max(layout.safeInsets.left, layout.safeInsets.right) + 10.0
        let width = min(420.0, layout.size.width - sideInset * 2.0)
        let height = GGQuickButtonsSizePanel.height(isCollapsed: self.isPanelCollapsed)
        let frame = CGRect(x: floorToScreenPixels((layout.size.width - width) * 0.5), y: layout.size.height - self.historyInsets.bottom - 8.0 - height, width: width, height: height)
        self.panelView.setCollapsed(self.isPanelCollapsed, transition: transition)
        transition.updateFrame(view: self.panelView, frame: frame)
        self.panelView.layoutContent(size: frame.size, transition: transition)
    }

    // MARK: Dragging

    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        guard let button = recognizer.view as? GGQuickButtonView, let layout = self.validLayout else {
            return
        }
        let area = GGQuickButtonsLayout.area(bounds: layout.size, insets: self.historyInsets)
        let size = self.buttonSize
        switch recognizer.state {
        case .began:
            self.drag = (button.actionId, button.center)
            self.canvasView.bringSubviewToFront(button)
            self.feedback.impactOccurred()
            UIView.animate(withDuration: 0.15, animations: {
                button.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            })
            self.setPanelDimmed(true)
        case .changed:
            guard let drag = self.drag, drag.id == button.actionId else {
                return
            }
            let translation = recognizer.translation(in: self.canvasView)
            var center = GGQuickButtonsLayout.clampedCenter(CGPoint(x: drag.startCenter.x + translation.x, y: drag.startCenter.y + translation.y), area: area, size: size)
            // Sticks to the right column (where the buttons stand by default) and to the left one.
            let rightX = area.maxX - size.width * 0.5 - GGQuickButtonsLayout.columnInset
            let leftX = area.minX + size.width * 0.5 + GGQuickButtonsLayout.columnInset
            if abs(center.x - rightX) < 10.0 {
                center.x = rightX
            } else if abs(center.x - leftX) < 10.0 {
                center.x = leftX
            }
            button.center = center
        case .ended, .cancelled, .failed:
            guard let drag = self.drag, drag.id == button.actionId else {
                return
            }
            self.drag = nil
            let dropFrame = CGRect(x: button.center.x - size.width * 0.5, y: button.center.y - size.height * 0.5, width: size.width, height: size.height)
            // Two buttons never stand on each other (the chat would move one of them apart,
            // `GGQuickButtonsLayout.separate`): such a drop goes back where it started.
            let overlaps = self.buttons.values.contains(where: { $0 !== button && $0.frame.insetBy(dx: -1.0, dy: -1.0).intersects(dropFrame) })
            let finalCenter = overlaps || recognizer.state != .ended ? drag.startCenter : button.center
            UIView.animate(withDuration: 0.25, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
                button.transform = .identity
                button.center = finalCenter
            })
            self.setPanelDimmed(false)
            if finalCenter != drag.startCenter {
                self.commitPositions(area: area)
            }
        default:
            break
        }
    }

    /// The card gives way while a button is carried, so the bottom of the chat can be used too.
    private func setPanelDimmed(_ isDimmed: Bool) {
        self.panelView.isUserInteractionEnabled = !isDimmed
        UIView.animate(withDuration: 0.2, animations: {
            self.panelView.alpha = isDimmed ? 0.25 : 1.0
        })
    }

    /// Stores where every shown button stands now; entries of buttons not shown here are kept.
    private func commitPositions(area: CGRect) {
        var positions = InterfaceSettings.bindButtonsPositions.value
        for action in self.actions {
            guard let button = self.buttons[action.id] else {
                continue
            }
            let point = GGQuickButtonsLayout.normalized(center: button.center, area: area, size: self.buttonSize)
            positions[action.id] = [(Double(point.x) * 10000.0).rounded() / 10000.0, (Double(point.y) * 10000.0).rounded() / 10000.0]
        }
        self.positions = positions
        InterfaceSettings.bindButtonsPositions.set(positions)
    }

    // MARK: Size

    private func sizeChanged(_ size: CGSize, isFinal: Bool) {
        if size != self.buttonSize {
            self.buttonSize = size
            self.layoutButtons(transition: .immediate)
        }
        if isFinal {
            InterfaceSettings.bindButtonsWidth.set(Double(size.width))
            InterfaceSettings.bindButtonsHeight.set(Double(size.height))
        }
    }

    private func reset() {
        self.positions = [:]
        self.buttonSize = GGQuickButtonsLayout.size(width: GGQuickButtonsLayout.defaultSide, height: GGQuickButtonsLayout.defaultSide)
        InterfaceSettings.bindButtonsPositions.reset()
        InterfaceSettings.bindButtonsWidth.reset()
        InterfaceSettings.bindButtonsHeight.reset()
        self.panelView.update(theme: self.presentationData.theme, size: self.buttonSize)
        self.layoutButtons(transition: .animated(duration: 0.3, curve: .spring))
    }
}

/// Holds the buttons over the whole chat; touches between them reach the chat (its back pill).
private final class GGQuickButtonsCanvasView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result === self {
            return nil
        }
        return result
    }
}

/// The glass card above the input bar: «Размер кнопок» with «Сбросить» and a fold button, the hint,
/// and the width / height sliders. Folded, only its title row stays.
private final class GGQuickButtonsSizePanel: UIView {
    private static let rowHeight: CGFloat = 44.0
    private static let hintHeight: CGFloat = 18.0
    private static let sliderRowHeight: CGFloat = 40.0
    private static let bottomPadding: CGFloat = 8.0

    static func height(isCollapsed: Bool) -> CGFloat {
        if isCollapsed {
            return GGQuickButtonsSizePanel.rowHeight
        }
        return GGQuickButtonsSizePanel.rowHeight + GGQuickButtonsSizePanel.hintHeight + GGQuickButtonsSizePanel.sliderRowHeight * 2.0 + GGQuickButtonsSizePanel.bottomPadding
    }

    var sizeChanged: ((CGSize, Bool) -> Void)?
    var resetPressed: (() -> Void)?
    var collapsePressed: (() -> Void)?

    private let glass = GlassBackgroundView()
    private let titleLabel = UILabel()
    private let resetButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let widthLabel = UILabel()
    private let heightLabel = UILabel()
    private let widthSlider = UISlider()
    private let heightSlider = UISlider()
    private let widthValueLabel = UILabel()
    private let heightValueLabel = UILabel()
    private var isCollapsed = false
    private var theme: PresentationTheme?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.glass.isUserInteractionEnabled = false
        self.addSubview(self.glass)
        self.titleLabel.textAlignment = .center
        self.addSubview(self.titleLabel)
        self.resetButton.addTarget(self, action: #selector(self.resetButtonPressed), for: .touchUpInside)
        self.addSubview(self.resetButton)
        self.collapseButton.addTarget(self, action: #selector(self.collapseButtonPressed), for: .touchUpInside)
        self.addSubview(self.collapseButton)
        self.hintLabel.textAlignment = .center
        self.addSubview(self.hintLabel)
        for slider in [self.widthSlider, self.heightSlider] {
            slider.minimumValue = Float(GGQuickButtonsLayout.sideRange.lowerBound)
            slider.maximumValue = Float(GGQuickButtonsLayout.sideRange.upperBound)
            slider.addTarget(self, action: #selector(self.sliderChanged), for: .valueChanged)
            slider.addTarget(self, action: #selector(self.sliderReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            self.addSubview(slider)
        }
        for label in [self.widthLabel, self.heightLabel, self.widthValueLabel, self.heightValueLabel] {
            self.addSubview(label)
        }
        self.widthValueLabel.textAlignment = .right
        self.heightValueLabel.textAlignment = .right
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func update(theme: PresentationTheme, size: CGSize) {
        self.theme = theme
        let navigationBar = theme.rootController.navigationBar
        self.titleLabel.attributedText = NSAttributedString(string: GGStrings.Interface.Binds.sizeHeader, font: Font.semibold(15.0), textColor: navigationBar.primaryTextColor)
        self.resetButton.setAttributedTitle(NSAttributedString(string: GGStrings.Interface.Binds.reset, font: Font.regular(15.0), textColor: navigationBar.accentTextColor), for: .normal)
        self.collapseButton.tintColor = navigationBar.secondaryTextColor
        self.updateCollapseIcon()
        self.hintLabel.attributedText = NSAttributedString(string: GGStrings.Interface.Binds.editorHint, font: Font.regular(13.0), textColor: navigationBar.secondaryTextColor)
        self.widthLabel.attributedText = NSAttributedString(string: GGStrings.Interface.Binds.width, font: Font.regular(15.0), textColor: navigationBar.primaryTextColor)
        self.heightLabel.attributedText = NSAttributedString(string: GGStrings.Interface.Binds.height, font: Font.regular(15.0), textColor: navigationBar.primaryTextColor)
        for slider in [self.widthSlider, self.heightSlider] {
            slider.minimumTrackTintColor = theme.list.itemAccentColor
        }
        self.widthSlider.value = Float(size.width)
        self.heightSlider.value = Float(size.height)
        self.updateValueLabels(size: size)
        self.setNeedsLayout()
    }

    private func updateValueLabels(size: CGSize) {
        let color = self.theme?.rootController.navigationBar.secondaryTextColor ?? .gray
        let font = Font.with(size: 15.0, traits: [.monospacedNumbers])
        self.widthValueLabel.attributedText = NSAttributedString(string: "\(Int(size.width))", font: font, textColor: color)
        self.heightValueLabel.attributedText = NSAttributedString(string: "\(Int(size.height))", font: font, textColor: color)
    }

    private func updateCollapseIcon() {
        let name = self.isCollapsed ? "chevron.up" : "chevron.down"
        self.collapseButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)), for: .normal)
    }

    func setCollapsed(_ isCollapsed: Bool, transition: ContainedViewLayoutTransition) {
        if self.isCollapsed == isCollapsed {
            return
        }
        self.isCollapsed = isCollapsed
        self.updateCollapseIcon()
        for view in [self.hintLabel, self.widthLabel, self.heightLabel, self.widthSlider, self.heightSlider, self.widthValueLabel, self.heightValueLabel] as [UIView] {
            transition.updateAlpha(layer: view.layer, alpha: isCollapsed ? 0.0 : 1.0)
            view.isUserInteractionEnabled = !isCollapsed
        }
    }

    func layoutContent(size: CGSize, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(view: self.glass, frame: CGRect(origin: CGPoint(), size: size))
        self.glass.update(size: size, cornerRadius: self.isCollapsed ? size.height * 0.5 : 24.0, isDark: self.theme?.overallDarkAppearance ?? false, tintColor: .init(kind: .panel), isInteractive: false, transition: ComponentTransition(transition))

        let rowHeight = GGQuickButtonsSizePanel.rowHeight
        let resetWidth = ceil(self.resetButton.sizeThatFits(CGSize(width: 200.0, height: rowHeight)).width)
        transition.updateFrame(view: self.resetButton, frame: CGRect(x: 16.0, y: 0.0, width: resetWidth, height: rowHeight))
        transition.updateFrame(view: self.collapseButton, frame: CGRect(x: size.width - 4.0 - rowHeight, y: 0.0, width: rowHeight, height: rowHeight))
        let titleInset = max(16.0 + resetWidth, 4.0 + rowHeight) + 6.0
        transition.updateFrame(view: self.titleLabel, frame: CGRect(x: titleInset, y: 0.0, width: max(0.0, size.width - titleInset * 2.0), height: rowHeight))

        // Folded, the rest stays laid out under the title row (it fades out there).
        let hintY = rowHeight - 6.0
        transition.updateFrame(view: self.hintLabel, frame: CGRect(x: 16.0, y: hintY, width: max(0.0, size.width - 32.0), height: GGQuickButtonsSizePanel.hintHeight))
        let labelWidth: CGFloat = 76.0
        let valueWidth: CGFloat = 32.0
        let rows: [(UILabel, UISlider, UILabel)] = [(self.widthLabel, self.widthSlider, self.widthValueLabel), (self.heightLabel, self.heightSlider, self.heightValueLabel)]
        for (index, row) in rows.enumerated() {
            let y = hintY + GGQuickButtonsSizePanel.hintHeight + 6.0 + CGFloat(index) * GGQuickButtonsSizePanel.sliderRowHeight
            transition.updateFrame(view: row.0, frame: CGRect(x: 16.0, y: y, width: labelWidth, height: GGQuickButtonsSizePanel.sliderRowHeight))
            transition.updateFrame(view: row.2, frame: CGRect(x: size.width - 16.0 - valueWidth, y: y, width: valueWidth, height: GGQuickButtonsSizePanel.sliderRowHeight))
            let sliderX = 16.0 + labelWidth + 8.0
            transition.updateFrame(view: row.1, frame: CGRect(x: sliderX, y: y, width: max(40.0, size.width - 16.0 - valueWidth - 8.0 - sliderX), height: GGQuickButtonsSizePanel.sliderRowHeight))
        }
    }

    private var currentSize: CGSize {
        return CGSize(width: GGQuickButtonsLayout.clampedSide(Double(self.widthSlider.value)), height: GGQuickButtonsLayout.clampedSide(Double(self.heightSlider.value)))
    }

    @objc private func sliderChanged() {
        let size = self.currentSize
        self.updateValueLabels(size: size)
        self.sizeChanged?(size, false)
    }

    @objc private func sliderReleased() {
        let size = self.currentSize
        self.widthSlider.value = Float(size.width)
        self.heightSlider.value = Float(size.height)
        self.sizeChanged?(size, true)
    }

    @objc private func resetButtonPressed() {
        self.resetPressed?()
    }

    @objc private func collapseButtonPressed() {
        self.collapsePressed?()
    }
}
