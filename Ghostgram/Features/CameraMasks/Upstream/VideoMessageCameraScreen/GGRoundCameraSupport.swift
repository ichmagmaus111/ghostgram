// Compiled INTO VideoMessageCameraScreen (filegroup //Ghostgram/Features/CameraMasks:VideoMessageCameraScreenSources).
// The video part of Ghostgram's round-video settings for the camera screen: rear camera at start,
// start zoom / remembered zoom / zoom slider, 3-2-1 countdown, the camera flip animation, the masks
// extension (frame processor, live preview, panel), audio post-processing of the clips, microphone
// mode. The screen keeps one instance per presentation and calls it from short `// GHOST:` lines.
// With every setting at its default and masks off, every call is a no-op.

import Foundation
import UIKit
import AVFoundation
import Display
import SwiftSignalKit
import Camera
import TelegramCore
import AccountContext
import TelegramPresentationData
import PresentationDataUtils
import GGCore
import GGCameraPipeline

final class GGRoundCameraSupport {
    let recording: GGRoundVideoRecordingConfig
    private let context: AccountContext
    /// The back camera goes below 1× here: a zoom feature wants the ultra-wide lens, the phone has it and
    /// the camera is CameraNeo (the legacy camera has the plain lens only). Such a session records
    /// with one camera: in the dual-camera session the back camera is the plain lens too, and 0.5× was
    /// cut to 1× while the slider said 0.5× (owner, build 189). Off after a fall back to the legacy
    /// camera (`cameraDidFallBackToLegacy`).
    private var usesUltraWideCamera: Bool
    private let accountId: GGAccountID
    private var cameraExtension: GGRoundVideoCameraExtension?

    private weak var camera: CameraProtocol?
    private weak var containerView: UIView?
    private weak var previewContentView: UIView?

    private var zoomSlider: GGRoundZoomSliderView?
    private var zoomMultiplier: Double = 1.0
    private var pinchStartMultiplier: Double = 1.0

    private var countdownLabel: UILabel?
    private var countdownTimer: SwiftSignalKit.Timer?
    private var countdownValue = 0
    private var countdownCompletion: (() -> Void)?

    private var isFlipping = false
    /// When the flip started on the tap: the camera's own report of the switch (a moment or, with
    /// the legacy camera, half a second later) plays no second one.
    private var tapFlipTimestamp: Double?
    /// The release of the snapshot over the preview while the camera switches.
    private let flipSnapshotDisposable = MetaDisposable()
    private var lastLayout: GGRoundVideoCameraLayout?
    /// The camera the last layout showed; a change is a flip.
    private var isFrontCamera: Bool?

    private let audioDisposables = DisposableSet()
    /// At least one clip went out with processed audio: the raw live upload must not be used.
    private(set) var hasProcessedAudio = false

    private struct PendingClip {
        let path: String
        let completion: (String?, Bool) -> Void
    }
    /// Clips waiting for the audio processing, in recording order (main thread).
    private var waitingClips: [PendingClip] = []
    private var isProcessingClip = false
    /// Clips handed to `processClip` and not given back yet.
    private(set) var pendingClipCount = 0
    /// Fires on the main thread after a clip was given back (added or refused).
    private let clipsSettled = ValuePipe<Void>()

    init(context: AccountContext, usesModernCamera: Bool, present: @escaping (UIViewController) -> Void) {
        self.context = context
        // The server's size limit first: the recording settings are capped by it.
        GGRoundVideoServerLimits.update(encoding: context.getAppConfigValue("round_video_encoding") as? [String: Any])
        let accountId = context.account.id.gg
        self.accountId = accountId
        self.recording = GGRoundVideoConfig.recording()
        self.usesUltraWideCamera = self.recording.usesUltraWideCamera && usesModernCamera
        self.cameraExtension = GGCameraHooks.makeRoundVideoCameraExtension(context: GGRoundVideoCameraContext(accountId: accountId, present: present))
    }

    deinit {
        self.invalidate()
    }

    // MARK: Camera pipeline

    /// Telegram's Metal camera (`NeoCameraImpl`) failed to start a recording in this run of the app
    /// (main thread). Report of build 196: on some phones the round camera opened with no picture
    /// and closed at once, whatever the settings; the old client recorded round videos with the
    /// legacy camera there. The screen then goes on with the legacy camera, and so do the next ones.
    private static var modernCameraFailed = false

    /// Upstream's choice of the Metal camera (experimental setting, `ios_killswitch_disable_neo_round_camera_v2`),
    /// unless it already failed in this run.
    static func usesModernCamera(upstream: Bool) -> Bool {
        return upstream && !GGRoundCameraSupport.modernCameraFailed
    }

    /// The screen switched to the legacy camera after the Metal one failed: zoom below 1× needs the
    /// Metal camera (the legacy one has the plain lens only), the slider is rebuilt from 1×.
    func cameraDidFallBackToLegacy() {
        GGRoundCameraSupport.modernCameraFailed = true
        self.usesUltraWideCamera = false
        self.zoomSlider?.removeFromSuperview()
        self.zoomSlider = nil
        self.zoomMultiplier = 1.0
    }

    // MARK: Start

    /// SG-F4: the camera the screen starts with.
    static var startsWithFrontCamera: Bool {
        return !GGRoundVideoSettings.startWithRearCamera.value
    }

    static func isViewOnceEnabledInitially(available: Bool) -> Bool {
        return available && GGRoundVideoSettings.viewOnceByDefault.value
    }

    /// 60 fps records with one camera: the dual-camera session can not run both at 60. Zoom below 1×
    /// too: the dual-camera session keeps the plain back lens (CameraNeo `makeVideoDevice`).
    var disablesDualCamera: Bool {
        return self.recording.frameRate == 60 || self.usesUltraWideCamera
    }

    var frameProcessor: GGCameraFrameProcessor? {
        return self.cameraExtension?.frameProcessor
    }

    /// The live upload sends the raw file while it is being recorded; when the audio will be
    /// processed the raw voice must not leave the device, so there is no live upload at all.
    var allowsLiveUpload: Bool {
        return !GGRoundVideoAudioProcessor.isNeeded(accountId: self.accountId)
    }

    /// Adds the masks preview (inside the circle, under `belowView`) and the controls.
    func attach(containerView: UIView, previewContentView: UIView, below belowView: UIView) {
        self.containerView = containerView
        self.previewContentView = previewContentView
        if let overlay = self.cameraExtension?.previewOverlayView {
            previewContentView.insertSubview(overlay, belowSubview: belowView)
        }
        if let controls = self.cameraExtension?.controlsView {
            containerView.addSubview(controls)
        }
    }

    func cameraDidStart(_ camera: CameraProtocol) {
        self.camera = camera
        let isFront = GGRoundCameraSupport.startsWithFrontCamera
        self.isFrontCamera = isFront
        if !isFront, self.opensBackCameraAtHalfZoom {
            self.setZoom(0.5)
        } else if let multiplier = GGRoundVideoConfig.startZoomMultiplier() {
            self.setZoom(multiplier)
        } else if !isFront, self.usesUltraWideCamera {
            // The virtual back camera's own factor 1 is the 0.5× lens: the camera and the slider
            // both at 1×.
            self.setZoom(1.0)
        }
    }

    // MARK: Zoom (multiplier of the camera's neutral 1× factor)

    /// «0,5× на задней камере»: the back camera opens with the ultra-wide lens.
    private var opensBackCameraAtHalfZoom: Bool {
        return GGRoundVideoSettings.rearHalfZoom.value && self.usesUltraWideCamera
    }

    /// 0.5× on the back camera when it is the ultra-wide virtual camera, 1× otherwise.
    private var minimumZoom: Double {
        if self.isFrontCamera == false, self.usesUltraWideCamera {
            return GGRoundVideoConfig.minimumZoom
        }
        return 1.0
    }

    private func setZoom(_ multiplier: Double) {
        let clamped = max(self.minimumZoom, min(GGRoundZoomSliderView.maximumZoom, multiplier))
        self.zoomMultiplier = clamped
        self.camera?.setZoomLevel(CGFloat(clamped - 1.0))
        self.zoomSlider?.setMultiplier(clamped)
    }

    /// A flip: the new camera starts at 1× — or at 0.5× on the back when that is asked for. The
    /// camera is told too (not only the slider): the slider said 1× while the back camera showed its
    /// 0.5× lens.
    private func cameraPositionChanged(isFront: Bool) {
        if !isFront, self.opensBackCameraAtHalfZoom {
            self.setZoom(0.5)
        } else {
            self.setZoom(1.0)
        }
    }

    /// `true` = the pinch is handled here (zoom is remembered: no snap back to 1×).
    func handlePinch(_ recognizer: UIPinchGestureRecognizer) -> Bool {
        guard GGRoundVideoSettings.rememberZoom.value else {
            return false
        }
        switch recognizer.state {
        case .began:
            self.pinchStartMultiplier = self.zoomMultiplier
        case .changed:
            self.setZoom(self.pinchStartMultiplier * Double(recognizer.scale))
        case .ended, .cancelled:
            GGRoundVideoConfig.noteZoom(self.zoomMultiplier)
        default:
            break
        }
        return true
    }

    /// The upstream pinch snapped the camera back to 1×: that is the zoom the user left it at.
    func didResetZoom() {
        self.zoomMultiplier = 1.0
        self.zoomSlider?.setMultiplier(1.0)
        GGRoundVideoConfig.noteZoom(1.0)
    }

    // MARK: Countdown

    var isCountingDown: Bool {
        return self.countdownTimer != nil
    }

    /// `true` = a 3-2-1 countdown started and `start` runs when it ends.
    func startRecordingAfterCountdown(_ start: @escaping () -> Void) -> Bool {
        guard GGRoundVideoSettings.countdown.value, let previewContentView = self.previewContentView else {
            return false
        }
        let label = UILabel()
        label.font = Font.with(size: 96.0, design: .round, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.35
        label.layer.shadowRadius = 12.0
        label.layer.shadowOffset = .zero
        label.isUserInteractionEnabled = false
        label.frame = previewContentView.bounds
        previewContentView.addSubview(label)
        self.countdownLabel = label
        self.countdownCompletion = start
        self.countdownValue = 3
        self.showCountdownValue()
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
            self?.countdownTick()
        }, queue: Queue.mainQueue())
        self.countdownTimer = timer
        timer.start()
        return true
    }

    private func showCountdownValue() {
        guard let label = self.countdownLabel else {
            return
        }
        label.text = "\(self.countdownValue)"
        label.alpha = 0.0
        label.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        UIView.animate(withDuration: 0.15, animations: {
            label.alpha = 1.0
        })
        UIView.animate(withDuration: 0.3, animations: {
            label.transform = .identity
        })
    }

    private func countdownTick() {
        self.countdownValue -= 1
        if self.countdownValue > 0 {
            self.showCountdownValue()
            return
        }
        let completion = self.countdownCompletion
        self.cancelCountdown()
        completion?()
    }

    /// Cancels a running countdown; `true` if there was one.
    @discardableResult
    func cancelCountdown() -> Bool {
        guard let timer = self.countdownTimer else {
            return false
        }
        timer.invalidate()
        self.countdownTimer = nil
        self.countdownCompletion = nil
        if let label = self.countdownLabel {
            self.countdownLabel = nil
            UIView.animate(withDuration: 0.2, animations: {
                label.alpha = 0.0
            }, completion: { _ in
                label.removeFromSuperview()
            })
        }
        return true
    }

    // MARK: Camera flip

    /// The flip button was tapped (before the camera is asked to switch): the circle turns at once,
    /// as in the old client. Waiting for the camera to report the new position read as lag.
    func cameraWillFlip() {
        guard let contentView = self.previewContentView, let containerView = contentView.superview else {
            return
        }
        if self.animateFlip(containerView: containerView, contentView: contentView) {
            self.tapFlipTimestamp = CACurrentMediaTime()
        }
    }

    /// Upstream covers the preview of a single-camera session (60 fps, 0.5×, a phone without two
    /// cameras at once) with a snapshot of the last frame for a fixed second while it switches. With
    /// the flip the circle turned over to the old camera's frozen frame and the new one came a second
    /// later (owner, build 197). With the flip on the snapshot goes when the camera says the switch is
    /// done: its mode change back to `.none` (CameraNeo 0.2 s after the session commit, the legacy
    /// camera 0.5 s after the restart) or the preview running again after the legacy restart. The
    /// second stays the ceiling; `release` runs once. Off = upstream's fixed second.
    func holdPositionChangeSnapshot(camera: CameraProtocol?, previewView: CameraSimplePreviewView, release: @escaping () -> Void) {
        let disposable = DisposableSet()
        self.flipSnapshotDisposable.set(disposable)
        var released = false
        let releaseOnce: () -> Void = {
            if released {
                return
            }
            released = true
            disposable.dispose()
            release()
        }
        Queue.mainQueue().after(1.0, releaseOnce)
        guard GGRoundVideoSettings.flipAnimation.value, let camera else {
            return
        }
        var sawPositionChange = false
        disposable.add((camera.modeChange
        |> filter { mode -> Bool in
            if mode == .position {
                sawPositionChange = true
                return false
            }
            return mode == .none && sawPositionChange
        }
        |> take(1)
        |> deliverOnMainQueue).startStrict(next: { _ in
            releaseOnce()
        }))
        var sawStopped = false
        disposable.add((previewView.isPreviewing
        |> filter { isPreviewing -> Bool in
            if !isPreviewing {
                sawStopped = true
                return false
            }
            return sawStopped
        }
        |> take(1)
        |> delay(0.1, queue: Queue.mainQueue()) // the first frames of the restarted session
        ).startStrict(next: { _ in
            releaseOnce()
        }))
    }

    /// A 3D flip of the circle while the camera switches (the frame changes when it is edge-on).
    /// `false` = not played (setting off, or a flip is running).
    @discardableResult
    func animateFlip(containerView: UIView, contentView: UIView) -> Bool {
        guard GGRoundVideoSettings.flipAnimation.value, !self.isFlipping else {
            return false
        }
        self.isFlipping = true
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / (8.0 * max(1.0, containerView.bounds.height))
        containerView.layer.sublayerTransform = perspective
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.y")
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        for i in 0 ... 60 {
            let t = Double(i) / 60.0
            let p = 1.0 - pow(1.0 - t, 5.0)
            let angle = (p < 0.5 ? p : p - 1.0) * Double.pi
            values.append(NSNumber(value: angle))
            keyTimes.append(NSNumber(value: t))
        }
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = 0.58
        animation.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak containerView] in
            containerView?.layer.sublayerTransform = CATransform3DIdentity
            self?.isFlipping = false
        }
        contentView.layer.add(animation, forKey: "ggFlip")
        CATransaction.commit()
        return true
    }

    // MARK: Layout

    func update(layout: GGRoundVideoCameraLayout, animated: Bool) {
        self.lastLayout = layout
        if let isFront = self.isFrontCamera, isFront != layout.isFrontCamera {
            self.isFrontCamera = layout.isFrontCamera
            self.cameraPositionChanged(isFront: layout.isFrontCamera)
            // A real switch of the camera, in the single- and the dual-camera session alike (the
            // first position the camera reports is not a switch). Already turned on the tap: no
            // second flip.
            if let timestamp = self.tapFlipTimestamp, CACurrentMediaTime() - timestamp < 1.5 {
                self.tapFlipTimestamp = nil
            } else if let contentView = self.previewContentView, let containerView = contentView.superview {
                self.animateFlip(containerView: containerView, contentView: contentView)
            }
        } else if self.isFrontCamera == nil {
            self.isFrontCamera = layout.isFrontCamera
        }
        self.cameraExtension?.update(layout: layout, animated: animated)
        if let controls = self.cameraExtension?.controlsView, let containerView = self.containerView, controls.superview === containerView {
            containerView.bringSubviewToFront(controls)
        }
        if let label = self.countdownLabel, let previewContentView = self.previewContentView {
            label.frame = previewContentView.bounds
            previewContentView.bringSubviewToFront(label)
        }
        self.updateZoomSlider(layout: layout, animated: animated)
    }

    private func updateZoomSlider(layout: GGRoundVideoCameraLayout, animated: Bool) {
        guard GGRoundVideoSettings.zoomSlider.value, let containerView = self.containerView else {
            return
        }
        let slider: GGRoundZoomSliderView
        if let current = self.zoomSlider {
            slider = current
        } else {
            slider = GGRoundZoomSliderView(minimumZoom: self.usesUltraWideCamera ? GGRoundVideoConfig.minimumZoom : 1.0)
            slider.alpha = 0.0
            slider.zoomChanged = { [weak self] multiplier in
                self?.setZoom(multiplier)
            }
            slider.zoomEnded = { multiplier in
                GGRoundVideoConfig.noteZoom(multiplier)
            }
            slider.setMultiplier(self.zoomMultiplier)
            containerView.addSubview(slider)
            self.zoomSlider = slider
        }
        var width = layout.previewFrame.width - 40.0
        if let occupied = self.cameraExtension?.occupiedFrame, occupied.minY < layout.previewFrame.maxY + 60.0, occupied.maxY > layout.previewFrame.maxY {
            width = min(width, 2.0 * (occupied.minX - 8.0 - layout.previewFrame.midX))
        }
        let frame = CGRect(x: layout.previewFrame.midX - width / 2.0, y: layout.previewFrame.maxY + 12.0, width: width, height: GGRoundZoomSliderView.height)
        let fits = width >= 120.0 && frame.maxY <= layout.containerSize.height - 60.0
        let isVisible = fits && !layout.isFrontCamera && !layout.isShowingResult
        slider.frame = frame
        slider.isUserInteractionEnabled = isVisible
        containerView.bringSubviewToFront(slider)
        if animated {
            UIView.animate(withDuration: 0.2, animations: {
                slider.alpha = isVisible ? 1.0 : 0.0
            })
        } else {
            slider.alpha = isVisible ? 1.0 : 0.0
        }
    }

    // MARK: Audio

    /// Post-processes a finished clip (normalisation, no sound, the voice changer) before the screen
    /// adds it. Main thread. Clips come back one by one, in the order they were given.
    /// `completion(path, isLate)`: `path` nil = the processing that hides the voice failed and the
    /// clip must not be sent (`presentAudioFailure`); `isLate` = it comes back after this call
    /// returned, when the camera may already be recording the next clip.
    func processClip(path: String, completion: @escaping (String?, Bool) -> Void) {
        guard self.pendingClipCount != 0 || GGRoundVideoAudioProcessor.isNeeded(accountId: self.accountId) else {
            completion(path, false)
            self.clipsSettled.putNext(Void())
            return
        }
        self.pendingClipCount += 1
        self.waitingClips.append(PendingClip(path: path, completion: completion))
        self.processNextClip()
    }

    private func processNextClip() {
        if self.isProcessingClip || self.waitingClips.isEmpty {
            return
        }
        let clip = self.waitingClips.removeFirst()
        self.isProcessingClip = true
        self.audioDisposables.add(GGRoundVideoAudioProcessor.process(paths: [clip.path], accountId: self.accountId, completion: { [weak self] paths in
            guard let self else {
                return
            }
            self.isProcessingClip = false
            self.pendingClipCount -= 1
            var result: String?
            if let paths {
                let path = paths.first ?? clip.path
                if path != clip.path {
                    self.hasProcessedAudio = true
                }
                result = path
            }
            clip.completion(result, true)
            self.clipsSettled.putNext(Void())
            self.processNextClip()
        }))
    }

    /// `currentResults` of the screen while clips go through the audio processing: the results once
    /// every clip has been given back, and also the one the camera is still finishing
    /// (`waitsForNextClip`, the screen's «waiting for the next result»). nil: no processing in this
    /// session — the screen's own path, where a clip is added the moment it is recorded.
    func settledResults<T>(results: @escaping () -> [T], waitsForNextClip: Bool) -> Signal<[T], NoError>? {
        if self.pendingClipCount == 0 && !GGRoundVideoAudioProcessor.isNeeded(accountId: self.accountId) {
            return nil
        }
        let expectedCount = results().count + self.pendingClipCount + (waitsForNextClip ? 1 : 0)
        let clipsSettled = self.clipsSettled
        return Signal<[T], NoError> { [weak self] subscriber in
            let isSettled: () -> Bool = {
                guard let self else {
                    return true
                }
                return self.pendingClipCount == 0 && results().count >= expectedCount
            }
            if isSettled() {
                subscriber.putNext(results())
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let disposable = MetaDisposable()
            disposable.set(clipsSettled.signal().start(next: { _ in
                if isSettled() {
                    subscriber.putNext(results())
                    subscriber.putCompletion()
                    disposable.dispose()
                }
            }))
            return disposable
        }
        |> runOn(Queue.mainQueue())
    }

    /// The clip was refused (`processClip` gave nil back): tells the user nothing was sent.
    func presentAudioFailure(on controller: ViewController) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        controller.present(textAlertController(context: self.context, title: nil, text: GGStrings.CameraMasks.Round.audioFailed, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
    }

    /// `AVAudioSession` mode for the microphone setting; the default leaves Telegram's session.
    static func applyMicrophoneMode() {
        let mode = GGRoundVideoMicrophoneMode(rawValue: GGRoundVideoSettings.microphoneMode.value) ?? .standard
        switch mode {
        case .standard:
            break
        case .videoRecording:
            try? AVAudioSession.sharedInstance().setMode(.videoRecording)
        case .voiceChat:
            try? AVAudioSession.sharedInstance().setMode(.voiceChat)
        }
    }

    // MARK: Send

    static var sendsAsRegularVideo: Bool {
        return GGRoundVideoSettings.sendAsRegularVideo.value
    }

    static func saveCopyToGallery(paths: [String], trimRange: Range<Double>?) {
        GGRoundVideoGallerySaver.saveIfEnabled(paths: paths, trimRange: trimRange.map { $0.lowerBound ... $0.upperBound })
    }

    /// The screen is closing: the zoom slider and the masks controls fade with the rest of it. They
    /// were left at full opacity, so for as long as the screen was still on its way out they stayed
    /// over the chat on their own (owner's video, build 199).
    func animateOut(duration: Double) {
        var views: [UIView] = []
        if let slider = self.zoomSlider {
            views.append(slider)
        }
        if let controls = self.cameraExtension?.controlsView {
            views.append(controls)
        }
        for view in views {
            view.isUserInteractionEnabled = false
            view.layer.animateAlpha(from: CGFloat(view.layer.presentation()?.opacity ?? Float(view.alpha)), to: 0.0, duration: duration, removeOnCompletion: false)
        }
    }

    func invalidate() {
        self.cancelCountdown()
        self.flipSnapshotDisposable.dispose()
        self.audioDisposables.dispose()
        self.cameraExtension?.invalidate()
        self.cameraExtension = nil
    }
}

/// Zoom slider under the circle (back camera): logarithmic between 0.5× (the ultra-wide lens, when
/// the camera has it) or 1× and 5×.
final class GGRoundZoomSliderView: UIView {
    static let maximumZoom: Double = GGRoundVideoConfig.maximumZoom
    static let height: CGFloat = 36.0

    var zoomChanged: ((Double) -> Void)?
    var zoomEnded: ((Double) -> Void)?

    private let minimumZoom: Double
    private let slider = UISlider()
    private let minimumLabel = UILabel()
    private let maximumLabel = UILabel()

    init(minimumZoom: Double) {
        self.minimumZoom = max(0.1, min(1.0, minimumZoom))
        super.init(frame: CGRect())
        self.slider.minimumValue = 0.0
        self.slider.maximumValue = 1.0
        self.slider.minimumTrackTintColor = .white
        self.slider.maximumTrackTintColor = UIColor(white: 1.0, alpha: 0.3)
        self.slider.thumbTintColor = .white
        self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.editingEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        for label in [self.minimumLabel, self.maximumLabel] {
            label.font = Font.medium(12.0)
            label.textColor = UIColor(white: 1.0, alpha: 0.8)
            label.textAlignment = .center
            self.addSubview(label)
        }
        self.minimumLabel.text = GGRoundZoomSliderView.zoomText(self.minimumZoom)
        self.maximumLabel.text = GGRoundZoomSliderView.zoomText(GGRoundZoomSliderView.maximumZoom)
        self.addSubview(self.slider)
    }

    /// «0,5×», «1×», «5×» with the locale's decimal separator.
    private static func zoomText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return (formatter.string(from: NSNumber(value: value)) ?? "\(value)") + "×"
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelWidth: CGFloat = 32.0
        self.minimumLabel.frame = CGRect(x: 0.0, y: 0.0, width: labelWidth, height: self.bounds.height)
        self.maximumLabel.frame = CGRect(x: self.bounds.width - labelWidth, y: 0.0, width: labelWidth, height: self.bounds.height)
        self.slider.frame = CGRect(x: labelWidth + 4.0, y: 0.0, width: max(0.0, self.bounds.width - (labelWidth + 4.0) * 2.0), height: self.bounds.height)
    }

    func setMultiplier(_ multiplier: Double) {
        if self.slider.isTracking {
            return
        }
        let range = log(GGRoundZoomSliderView.maximumZoom / self.minimumZoom)
        let position = log(max(self.minimumZoom, multiplier) / self.minimumZoom) / range
        self.slider.value = Float(max(0.0, min(1.0, position)))
    }

    private var multiplier: Double {
        return self.minimumZoom * pow(GGRoundZoomSliderView.maximumZoom / self.minimumZoom, Double(self.slider.value))
    }

    @objc private func valueChanged() {
        self.zoomChanged?(self.multiplier)
    }

    @objc private func editingEnded() {
        self.zoomEnded?(self.multiplier)
    }
}
