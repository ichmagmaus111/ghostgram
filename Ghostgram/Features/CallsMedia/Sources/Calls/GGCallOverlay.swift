import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramVoip
import AccountContext
import GGCallsMediaHooks
import GGCallAudio
import GGCore

/// The overlay above a call screen: the column of feature buttons (soundboard here, masks and the
/// virtual camera from W3-2 through `GGCallsMediaHooks.overlayItems`), the panel of the selected
/// button, the stats panel, the «● REC» chip of a recorded call and the «Silent mute» chip (muted
/// here while the other side still sees the microphone on). Created once per screen; the stats tick
/// only while the panel is on screen and the app is in the foreground.
final class GGCallOverlayHost: GGCallScreenOverlay {
    let view: UIView

    private let screen: GGCallScreen
    private let items: [GGCallOverlayItem]
    private var buttons: [String: GGCallOverlayButton] = [:]
    private var selectedItemId: String?
    private var panelView: UIView?
    private var statsPanel: GGCallStatsPanel?
    private let recordingChip = GGCallStatusChip(dotColor: UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0))
    private var isRecording = false
    private let silentMuteChip = GGCallStatusChip(dotColor: UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0))
    private var isSilentlyMuted = false
    private var lastState: GGCallScreenState?
    private var lastLayout: (size: CGSize, insets: UIEdgeInsets)?
    private let recordingDisposable = MetaDisposable()
    private let foregroundDisposable = MetaDisposable()
    private let mutedDisposable = MetaDisposable()

    init(screen: GGCallScreen, items: [GGCallOverlayItem]) {
        self.screen = screen
        self.view = GGPassThroughView()
        self.items = items

        for item in self.items {
            let button = GGCallOverlayButton(icon: item.icon)
            button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = item.id
            button.isHidden = true
            self.buttons[item.id] = button
            self.view.addSubview(button)
        }

        self.recordingChip.isHidden = true
        self.view.addSubview(self.recordingChip)
        self.silentMuteChip.isHidden = true
        self.view.addSubview(self.silentMuteChip)

        if GGCallsMediaSettings.statsOverlay.value && screen.call != nil {
            let panel = GGCallStatsPanel()
            self.statsPanel = panel
            self.view.addSubview(panel)
            self.foregroundDisposable.set((screen.context.sharedContext.applicationBindings.applicationInForeground
            |> deliverOnMainQueue).start(next: { [weak panel] inForeground in
                panel?.setActive(inForeground)
            }))
        }

        if let call = screen.call {
            self.recordingDisposable.set((GGCallRecordingCoordinator.shared.isRecording(callId: call.internalId)
            |> deliverOnMainQueue).start(next: { [weak self] isRecording in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.isRecording = isRecording
                strongSelf.relayout()
            }))
            // The setting is read once per screen, like the mute itself (applied when the call starts
            // and on every toggle of the button).
            if GGCallsMediaSettings.silentMute.value {
                self.mutedDisposable.set((call.isMuted
                |> deliverOnMainQueue).start(next: { [weak self] isMuted in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.isSilentlyMuted = isMuted
                    strongSelf.relayout()
                }))
            }
        }
    }

    deinit {
        self.recordingDisposable.dispose()
        self.foregroundDisposable.dispose()
        self.mutedDisposable.dispose()
    }

    func screenWillClose() {
        for item in self.items {
            item.screenWillClose()
        }
        self.statsPanel?.setActive(false)
    }

    func update(size: CGSize, insets: UIEdgeInsets, state: GGCallScreenState, transition: ContainedViewLayoutTransition) {
        self.lastLayout = (size, insets)
        self.lastState = state
        self.relayout()
    }

    private func relayout() {
        guard let (size, insets) = self.lastLayout, let state = self.lastState else {
            return
        }
        let visible = !state.isTerminated
        self.view.isHidden = !visible

        // Column: top-right, under the top controls of the call screen.
        let buttonSize: CGFloat = 40.0
        let x = size.width - insets.right - 16.0 - buttonSize
        var y = insets.top + 64.0
        var lastButtonFrame: CGRect?
        for item in self.items {
            guard let button = self.buttons[item.id] else {
                continue
            }
            let isVisible = visible && item.isVisible(state: state)
            button.isHidden = !isVisible
            if !isVisible {
                if self.selectedItemId == item.id {
                    self.closePanel()
                }
                continue
            }
            let frame = CGRect(x: x, y: y, width: buttonSize, height: buttonSize)
            button.frame = frame
            button.isSelected = self.selectedItemId == item.id
            lastButtonFrame = frame
            y += buttonSize + 8.0
        }

        if let panelView = self.panelView {
            let panelY = (lastButtonFrame?.maxY ?? (insets.top + 64.0)) + 10.0
            panelView.frame = CGRect(x: insets.left + 16.0, y: panelY, width: size.width - insets.left - insets.right - 32.0, height: 84.0)
        }

        // «● REC» and «● Silent mute» in a row above the column, right-aligned with it, so they never
        // cover the call's own controls.
        var chipMaxX = x + buttonSize
        for (chip, isShown, text) in [(self.recordingChip, self.isRecording, GGStrings.Calls.Overlay.recording), (self.silentMuteChip, self.isSilentlyMuted, GGStrings.Calls.Overlay.silentMute)] {
            chip.isHidden = !(visible && isShown)
            if chip.isHidden {
                continue
            }
            let chipSize = chip.measure(text: text)
            chip.frame = CGRect(x: chipMaxX - chipSize.width, y: insets.top + 64.0 - chipSize.height - 8.0, width: chipSize.width, height: chipSize.height)
            chipMaxX -= chipSize.width + 6.0
        }

        if let statsPanel = self.statsPanel {
            statsPanel.isHidden = !visible
            statsPanel.update(state: state)
            statsPanel.layoutIn(bounds: CGRect(origin: CGPoint(), size: size), insets: insets)
        }
    }

    @objc private func buttonPressed(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier, let item = self.items.first(where: { $0.id == id }) else {
            return
        }
        if self.selectedItemId == id {
            self.closePanel()
            self.relayout()
            return
        }
        self.closePanel()
        if let panel = item.makePanel() {
            self.selectedItemId = id
            self.panelView = panel
            panel.alpha = 0.0
            self.view.addSubview(panel)
            UIView.animate(withDuration: 0.2, animations: {
                panel.alpha = 1.0
            })
        } else {
            item.buttonTapped()
        }
        self.relayout()
    }

    private func closePanel() {
        self.selectedItemId = nil
        if let panel = self.panelView {
            self.panelView = nil
            UIView.animate(withDuration: 0.2, animations: {
                panel.alpha = 0.0
            }, completion: { _ in
                panel.removeFromSuperview()
            })
        }
    }
}

/// Takes touches only inside its subviews; everything else reaches the call screen.
final class GGPassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result === self {
            return nil
        }
        return result
    }
}

/// A round 40 pt button of the column.
final class GGCallOverlayButton: UIButton {
    init(icon: UIImage?) {
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 40.0, height: 40.0))
        self.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        self.layer.cornerRadius = 20.0
        self.tintColor = .white
        self.setImage(icon?.withRenderingMode(.alwaysTemplate), for: .normal)
        self.imageView?.contentMode = .scaleAspectFit
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet {
            self.backgroundColor = self.isSelected ? UIColor(white: 1.0, alpha: 0.3) : UIColor(white: 0.0, alpha: 0.4)
        }
    }
}

/// «● REC» (the call is being recorded on this device) and «● Silent mute» (muted on this device only).
private final class GGCallStatusChip: UIView {
    private let dot = UIView()
    private let label = UILabel()

    init(dotColor: UIColor) {
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        self.layer.cornerRadius = 11.0
        self.dot.backgroundColor = dotColor
        self.dot.layer.cornerRadius = 4.0
        self.label.font = UIFont.systemFont(ofSize: 12.0, weight: .semibold)
        self.label.textColor = .white
        self.addSubview(self.dot)
        self.addSubview(self.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func measure(text: String) -> CGSize {
        if self.label.text != text {
            self.label.text = text
        }
        let labelSize = self.label.sizeThatFits(CGSize(width: 200.0, height: 22.0))
        let size = CGSize(width: 8.0 + 8.0 + 6.0 + labelSize.width + 10.0, height: 22.0)
        self.dot.frame = CGRect(x: 8.0, y: 7.0, width: 8.0, height: 8.0)
        self.label.frame = CGRect(x: 22.0, y: floor((22.0 - labelSize.height) / 2.0), width: labelSize.width, height: labelSize.height)
        return size
    }
}
