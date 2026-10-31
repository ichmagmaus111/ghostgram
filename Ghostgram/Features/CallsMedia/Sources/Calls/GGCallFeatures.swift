import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramVoip
import AccountContext
import GGCallsMediaHooks
import GGCallAudio
import GGHooks
import GGCore

/// Handlers of the call points: silent mute, the rating sheet, Force TCP, the overlay host and its
/// soundboard button; the recording coordinator starts with the first account's UI.
enum GGCallFeatures {
    static func register() {
        GGCallsMediaHooks.silentMute.register({ _ in
            return GGCallsMediaSettings.silentMute.value ? true : nil
        })
        GGCallsMediaHooks.suppressRating.register({
            return GGCallsMediaSettings.disableRating.value
        })
        GGCallsMediaHooks.forceTcp.register({
            return GGCallsMediaSettings.forceTcp.value
        })

        GGCallsMediaHooks.overlayItems.register({ screen in
            guard GGCallsMediaSettings.soundboard.value, let audioDevice = screen.audioDevice else {
                return []
            }
            return [GGSoundboardOverlayItem(context: screen.context, audioDevice: audioDevice)]
        }, order: 300)

        GGCallsMediaHooks.screenOverlay.register({ screen in
            let items = GGCallsMediaHooks.makeOverlayItems(screen)
            let wantsStats = GGCallsMediaSettings.statsOverlay.value && screen.call != nil
            let mayRecord = screen.call != nil && GGCallsMediaSettings.recordingMode.isOn
            let showsSilentMute = screen.call != nil && GGCallsMediaSettings.silentMute.value
            if items.isEmpty && !wantsStats && !mayRecord && !showsSilentMute {
                // Nothing to show: the call screen stays exactly as upstream draws it.
                return nil
            }
            return GGCallOverlayHost(screen: screen, items: items)
        })

        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGCallRecordingCoordinator.shared.start(sharedContext: context.sharedContext)
        })
    }
}

/// The soundboard button: a strip of the library's sounds; a tap plays one into the call, a tap on
/// the playing one stops it.
final class GGSoundboardOverlayItem: GGCallOverlayItem {
    let id = "calls.soundboard"
    let order = 300

    private let context: AccountContext
    private let audioDevice: OngoingCallContext.AudioDevice
    private weak var strip: GGSoundboardStripView?
    private var playingItemId: String?
    private var endTimer: SwiftSignalKit.Timer?
    private let clipDisposable = MetaDisposable()

    init(context: AccountContext, audioDevice: OngoingCallContext.AudioDevice) {
        self.context = context
        self.audioDevice = audioDevice
    }

    deinit {
        self.endTimer?.invalidate()
        self.clipDisposable.dispose()
    }

    var icon: UIImage? {
        return UIImage(systemName: "music.note.list")
    }

    func isVisible(state: GGCallScreenState) -> Bool {
        return GGCallsMediaSettings.soundboard.value && !GGCallSoundLibrary.shared.items.isEmpty
    }

    func makePanel() -> UIView? {
        let strip = GGSoundboardStripView(items: GGCallSoundLibrary.shared.items, selectedId: self.playingItemId, selected: { [weak self] item in
            self?.toggle(item)
        })
        self.strip = strip
        return strip
    }

    func buttonTapped() {
    }

    func screenWillClose() {
        self.stop()
    }

    private func toggle(_ item: GGCallSoundItem) {
        if self.playingItemId == item.id {
            self.stop()
            return
        }
        self.playingItemId = item.id
        self.strip?.setSelected(item.id)
        let effects = self.audioDevice.ggAudioEffects
        self.clipDisposable.set((GGCallSoundLibrary.shared.clip(for: item)
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let strongSelf = self, strongSelf.playingItemId == item.id else {
                return
            }
            guard let data = data else {
                strongSelf.stop()
                GGCallsMediaUI.toast(context: strongSelf.context, text: GGStrings.Calls.Soundboard.cannotPlay)
                return
            }
            effects.playClip(data, sampleRate: GGCallSoundLibrary.clipSampleRate, volume: Float(GGCallsMediaSettings.soundboardVolume.value), duckMicrophone: GGCallsMediaSettings.soundboardDuck.value)
            // One timer for the end of this clip, to clear the chip; nothing polls the audio side.
            strongSelf.endTimer?.invalidate()
            let duration = Double(data.count / 2) / Double(GGCallSoundLibrary.clipSampleRate)
            let timer = SwiftSignalKit.Timer(timeout: duration + 0.1, repeat: false, completion: { [weak self] in
                guard let strongSelf = self, strongSelf.playingItemId == item.id else {
                    return
                }
                strongSelf.playingItemId = nil
                strongSelf.strip?.setSelected(nil)
            }, queue: Queue.mainQueue())
            strongSelf.endTimer = timer
            timer.start()
        }))
    }

    private func stop() {
        self.clipDisposable.set(nil)
        self.endTimer?.invalidate()
        self.endTimer = nil
        if self.playingItemId != nil {
            self.audioDevice.ggAudioEffects.stopClip()
        }
        self.playingItemId = nil
        self.strip?.setSelected(nil)
    }
}

/// Horizontally scrolling chips with the sounds' titles.
private final class GGSoundboardStripView: UIView {
    private let scrollView = UIScrollView()
    private var chips: [(id: String, button: UIButton)] = []
    private let selected: (GGCallSoundItem) -> Void
    private let items: [GGCallSoundItem]

    init(items: [GGCallSoundItem], selectedId: String?, selected: @escaping (GGCallSoundItem) -> Void) {
        self.items = items
        self.selected = selected
        super.init(frame: .zero)
        self.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        self.layer.cornerRadius = 18.0
        self.clipsToBounds = true
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = true
        self.addSubview(self.scrollView)
        for (index, item) in items.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.backgroundColor = UIColor(white: 1.0, alpha: 0.2)
            button.layer.cornerRadius = 10.0
            button.titleLabel?.font = UIFont.systemFont(ofSize: 11.0, weight: .medium)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitle(item.title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.addTarget(self, action: #selector(self.chipPressed(_:)), for: .touchUpInside)
            self.scrollView.addSubview(button)
            self.chips.append((item.id, button))
        }
        self.setSelected(selectedId)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ id: String?) {
        for chip in self.chips {
            chip.button.layer.borderWidth = chip.id == id ? 2.0 : 0.0
            chip.button.layer.borderColor = UIColor.systemBlue.cgColor
        }
    }

    @objc private func chipPressed(_ sender: UIButton) {
        guard sender.tag >= 0 && sender.tag < self.items.count else {
            return
        }
        self.selected(self.items[sender.tag])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.scrollView.frame = self.bounds
        let side = max(0.0, self.bounds.height - 16.0)
        var x: CGFloat = 12.0
        for chip in self.chips {
            chip.button.frame = CGRect(x: x, y: 8.0, width: 92.0, height: side)
            x += 92.0 + 8.0
        }
        self.scrollView.contentSize = CGSize(width: x + 4.0, height: self.bounds.height)
    }
}
