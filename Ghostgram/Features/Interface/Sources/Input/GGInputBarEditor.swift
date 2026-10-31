import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatTextInputPanelNode
import GGCore
import GGHooks

/// The geometry the panel shows while the editor's handle is being dragged. Main thread only:
/// the panel asks for its geometry in `updateLayout`, which runs on the main thread.
enum GGInputBarEditorDraft {
    static var current: GGInputBarGeometry?
}

/// «Редактор поля ввода»: edits the geometry on the REAL chat input panel. The editor opens the
/// user's «Избранное» and lays handles over the panel; dragging changes a draft (the panel
/// re-lays out from it, nothing is stored), releasing writes the setting once.
///
/// The handles live in a controller presented on the window's root level: Telegram's window
/// hit-tests only its own containers, so a view added to the window directly never got a touch —
/// neither the handles nor «Готово» worked (owner, 2026-10-28: «не даёт редактировать»).
final class GGInputBarEditor {
    private static var current: GGInputBarEditor?

    private let context: AccountContext
    private weak var chatController: ChatController?
    private let overlay: GGInputBarEditorOverlay
    private var editorController: GGInputBarEditorController?
    private var panel: ChatTextInputPanelNode?

    private init(context: AccountContext) {
        self.context = context
        self.overlay = GGInputBarEditorOverlay(presentationData: context.sharedContext.currentPresentationData.with { $0 })
    }

    static func register() {
        GGInputPanelHooks.didLayout.register({ layout in
            guard let editor = GGInputBarEditor.current, let panel = layout.panel as? ChatTextInputPanelNode else {
                return
            }
            if let chatController = editor.chatController, chatController.isNodeLoaded, panel.view.isDescendant(of: chatController.view) {
                editor.panel = panel
                editor.overlay.updateHandles(panel: panel)
            }
        })
        // Leaving the chat (back, another screen on top) ends editing: the handles belong to its panel.
        GGChatScreenHooks.lifecycle.register({ event, screen in
            guard case .willDisappear = event, let editor = GGInputBarEditor.current, let controller = screen.controller, controller === editor.chatController else {
                return
            }
            editor.finish()
        })
    }

    /// Opens «Избранное» and starts editing on top of it.
    static func start(context: AccountContext, navigationController: NavigationController?) {
        guard let navigationController else {
            return
        }
        GGInputBarEditor.current?.finish()
        let editor = GGInputBarEditor(context: context)
        GGInputBarEditor.current = editor
        GGInputBarEditorDraft.current = InterfaceSettings.inputBarGeometry.value.clamped
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> deliverOnMainQueue).start(next: { peer in
            guard let peer else {
                editor.finish()
                return
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), completion: { chatController in
                editor.attach(chatController: chatController)
            }))
        })
    }

    private func attach(chatController: ChatController) {
        guard GGInputBarEditor.current === self, let window = self.context.sharedContext.mainWindow else {
            return
        }
        self.chatController = chatController
        let editorController = GGInputBarEditorController(overlay: self.overlay)
        self.editorController = editorController
        window.present(editorController, on: .root)
        self.overlay.changed = { [weak self] geometry, isFinal in
            guard let self else {
                return
            }
            GGInputBarEditorDraft.current = geometry
            if isFinal {
                InterfaceSettings.inputBarGeometry.set(geometry)
            }
            self.chatController?.requestLayout(transition: .immediate)
        }
        self.overlay.reset = { [weak self] in
            GGInputBarEditorDraft.current = .zero
            InterfaceSettings.inputBarGeometry.set(.zero)
            self?.chatController?.requestLayout(transition: .animated(duration: 0.3, curve: .easeInOut))
        }
        self.overlay.done = { [weak self] in
            self?.finish()
        }
        chatController.requestLayout(transition: .immediate)
    }

    private func finish() {
        if GGInputBarEditor.current === self {
            GGInputBarEditor.current = nil
        }
        GGInputBarEditorDraft.current = nil
        self.editorController?.dismiss()
        self.editorController = nil
        self.chatController?.requestLayout(transition: .animated(duration: 0.3, curve: .easeInOut))
    }
}

/// The editor's handles as a window-level controller: transparent, it takes only the touches of
/// the top bar and the handles (`GGInputBarEditorOverlay.hitTest`), the chat stays usable.
private final class GGInputBarEditorController: ViewController {
    private let overlay: GGInputBarEditorOverlay

    init(overlay: GGInputBarEditorOverlay) {
        self.overlay = overlay
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        let overlay = self.overlay
        self.displayNode = ASDisplayNode(viewBlock: {
            return overlay
        })
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.overlay.topInset = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
    }
}

/// Handles over the panel: the field's top edge (height), its sides (margins), the bottom lift,
/// and the three buttons. One pan per handle; ticks only change the draft.
private final class GGInputBarEditorOverlay: UIView {
    private enum Handle: Int, CaseIterable {
        case height
        case left
        case right
        case lift
        case attach
        case accessory
        case send
    }

    var changed: ((GGInputBarGeometry, Bool) -> Void)?
    var reset: (() -> Void)?
    var done: (() -> Void)?

    private let presentationData: PresentationData
    private let topBar = UIView()
    private let hintLabel = UILabel()
    private let resetButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private var handleViews: [Handle: UIView] = [:]
    private var startGeometry: GGInputBarGeometry = .zero
    /// The status bar / island area the top bar starts under (from the controller's layout).
    var topInset: CGFloat = 0.0 {
        didSet {
            if self.topInset != oldValue {
                self.setNeedsLayout()
            }
        }
    }

    init(presentationData: PresentationData) {
        self.presentationData = presentationData
        super.init(frame: CGRect())
        let theme = presentationData.theme

        self.topBar.backgroundColor = theme.rootController.navigationBar.opaqueBackgroundColor
        self.addSubview(self.topBar)
        self.hintLabel.text = GGStrings.Interface.InputEditor.hint
        self.hintLabel.textColor = theme.rootController.navigationBar.primaryTextColor
        self.hintLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.hintLabel.numberOfLines = 2
        self.topBar.addSubview(self.hintLabel)
        self.resetButton.setTitle(GGStrings.Interface.InputEditor.reset, for: .normal)
        self.resetButton.tintColor = theme.list.itemDestructiveColor
        self.resetButton.addTarget(self, action: #selector(self.resetPressed), for: .touchUpInside)
        self.topBar.addSubview(self.resetButton)
        self.doneButton.setTitle(presentationData.strings.Common_Done, for: .normal)
        self.doneButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17.0)
        self.doneButton.tintColor = theme.rootController.navigationBar.accentTextColor
        self.doneButton.addTarget(self, action: #selector(self.donePressed), for: .touchUpInside)
        self.topBar.addSubview(self.doneButton)

        for handle in Handle.allCases {
            let view = UIView()
            view.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.85)
            view.layer.cornerRadius = 6.0
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 1.5
            view.tag = handle.rawValue
            view.isHidden = true
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:))))
            self.addSubview(view)
            self.handleViews[handle] = view
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = max(self.topInset, self.safeAreaInsets.top)
        self.topBar.frame = CGRect(x: 0.0, y: 0.0, width: self.bounds.width, height: top + 56.0)
        let buttonWidth: CGFloat = 90.0
        self.resetButton.frame = CGRect(x: 8.0, y: top, width: buttonWidth, height: 56.0)
        self.doneButton.frame = CGRect(x: self.bounds.width - buttonWidth - 8.0, y: top, width: buttonWidth, height: 56.0)
        self.hintLabel.frame = CGRect(x: buttonWidth + 12.0, y: top, width: max(0.0, self.bounds.width - (buttonWidth + 12.0) * 2.0), height: 56.0)
        self.hintLabel.textAlignment = .center
    }

    /// Only the top bar and the handles take touches; the chat stays usable around them.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result === self {
            return nil
        }
        return result
    }

    func updateHandles(panel: ChatTextInputPanelNode) {
        let field = panel.textInputNodeClippingContainer.convert(panel.textInputNodeClippingContainer.bounds, to: self)
        let attach = panel.attachmentButton.convert(panel.attachmentButton.bounds, to: self)
        let send = panel.sendActionButtons.view.convert(panel.sendActionButtons.view.bounds, to: self)
        let panelFrame = panel.view.convert(panel.view.bounds, to: self)
        let size: CGFloat = 22.0
        func place(_ handle: Handle, center: CGPoint, size: CGSize) {
            guard let view = self.handleViews[handle] else {
                return
            }
            view.isHidden = false
            view.frame = CGRect(x: center.x - size.width * 0.5, y: center.y - size.height * 0.5, width: size.width, height: size.height)
        }
        place(.height, center: CGPoint(x: field.midX, y: field.minY), size: CGSize(width: 44.0, height: 12.0))
        place(.left, center: CGPoint(x: field.minX, y: field.midY), size: CGSize(width: 12.0, height: 28.0))
        place(.right, center: CGPoint(x: field.maxX, y: field.midY), size: CGSize(width: 12.0, height: 28.0))
        place(.lift, center: CGPoint(x: panelFrame.midX, y: panelFrame.maxY - 6.0), size: CGSize(width: 44.0, height: 12.0))
        place(.attach, center: CGPoint(x: attach.midX, y: attach.midY), size: CGSize(width: size, height: size))
        place(.accessory, center: CGPoint(x: field.maxX - 22.0, y: field.maxY - 18.0), size: CGSize(width: size, height: size))
        place(.send, center: CGPoint(x: send.midX, y: send.midY), size: CGSize(width: size, height: size))
    }

    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        guard let handle = recognizer.view.flatMap({ Handle(rawValue: $0.tag) }) else {
            return
        }
        switch recognizer.state {
        case .began:
            self.startGeometry = GGInputBarEditorDraft.current ?? InterfaceSettings.inputBarGeometry.value.clamped
        case .changed, .ended, .cancelled:
            let translation = recognizer.translation(in: self)
            var geometry = self.startGeometry
            switch handle {
            case .height:
                geometry.heightPadding += Double(-translation.y)
            case .left:
                geometry.leftMargin += Double(translation.x)
            case .right:
                geometry.rightMargin += Double(-translation.x)
            case .lift:
                geometry.bottomOffset += Double(-translation.y)
            case .attach:
                geometry.attachX += Double(translation.x)
                geometry.attachY += Double(translation.y)
            case .accessory:
                geometry.accessoryX += Double(translation.x)
                geometry.accessoryY += Double(translation.y)
            case .send:
                geometry.sendX += Double(translation.x)
                geometry.sendY += Double(translation.y)
            }
            geometry = geometry.clamped
            self.changed?(geometry, recognizer.state != .changed)
        default:
            break
        }
    }

    @objc private func resetPressed() {
        self.reset?()
    }

    @objc private func donePressed() {
        self.done?()
    }
}
