import Foundation
import UIKit
import AVFoundation
import CoreMedia
import SwiftSignalKit
import Display
import ComponentFlow
import EdgeEffect
import GGAppearanceSettings

/// Low Power Mode and Reduce Motion as one signal, from one observer for the whole app. The power
/// notification is posted on an arbitrary thread: observed with `queue: nil`, forwarded to main.
enum GGSystemState {
    private static let promise = ValuePromise<Bool>(ignoreRepeated: true)
    private static var observers: [NSObjectProtocol] = []

    /// `true` while decorative motion should stop (Low Power Mode or Reduce Motion).
    static var reducesMotion: Signal<Bool, NoError> {
        if GGSystemState.observers.isEmpty {
            GGSystemState.promise.set(GGSystemState.current)
            let update: (Notification) -> Void = { _ in
                Queue.mainQueue().async {
                    GGSystemState.promise.set(GGSystemState.current)
                }
            }
            GGSystemState.observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil, using: update))
            GGSystemState.observers.append(NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: nil, using: update))
        }
        return GGSystemState.promise.get()
    }

    static var current: Bool {
        return ProcessInfo.processInfo.isLowPowerModeEnabled || UIAccessibility.isReduceMotionEnabled
    }
}

/// A muted looping video (the converted animated background of the chat and of the own profile header).
///
/// Drawn by our own reader, not by `AVPlayer`: `AVAssetReader` hands the compressed frames to an
/// `AVSampleBufferDisplayLayer` that shows them on its own clock. `AVPlayer.play()` activates the app's
/// audio session even for a muted file without an audio track, and Telegram's session at rest is not
/// "mix with others": build 199 stopped SoundCloud the moment the Settings tab with a video banner
/// appeared. Nothing here touches audio. Plays only while it is in a window and the app is not in the
/// background.
final class GGLoopingVideoView: UIView {
    private static let liveViews = NSHashTable<GGLoopingVideoView>.weakObjects()
    private static var backgroundObserver: NSObjectProtocol?

    /// Called from `GGLifecycleHooks.applicationDidBecomeActive`: the clocks stopped for the background
    /// run again, and a layer whose decoder the system tore down there starts over.
    static func resumeAll() {
        for view in GGLoopingVideoView.liveViews.allObjects {
            view.updatePlayback()
        }
    }

    /// The clocks stop in the background: a clock left running would make the reader race through every
    /// frame it "missed" on return.
    private static func observeBackgroundIfNeeded() {
        if GGLoopingVideoView.backgroundObserver != nil {
            return
        }
        GGLoopingVideoView.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { _ in
            Queue.mainQueue().async {
                for view in GGLoopingVideoView.liveViews.allObjects {
                    view.updatePlayback()
                }
            }
        })
    }

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var feeder: GGLoopingVideoFeeder?
    private var timebase: CMTimebase?
    private var currentURL: URL?
    private var currentVersion: Int = 0
    /// The file that plays: `currentURL` when it exists.
    private var playableURL: URL?
    /// The track's orientation (`preferredTransform` without its translation): the layer, unlike
    /// `AVPlayerLayer`, shows frames as they are stored.
    private var contentTransform: CGAffineTransform = .identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.displayLayer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(self.displayLayer)
        GGLoopingVideoView.liveViews.add(self)
        GGLoopingVideoView.observeBackgroundIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.feeder?.stop()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = self.bounds
        let transform = self.contentTransform
        // A quarter turn: the layer gets the bounds rotated back, aspect-fills them, and is turned.
        let swapsAxes = abs(transform.b) > abs(transform.a)
        self.displayLayer.setAffineTransform(.identity)
        self.displayLayer.bounds = CGRect(origin: CGPoint(), size: swapsAxes ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        self.displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        self.displayLayer.setAffineTransform(transform)
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.updatePlayback()
    }

    /// Loads `url` if it is new (`version` changes on every new pick); nil stops and releases the reader.
    func setVideo(url: URL?, version: Int) {
        if url == self.currentURL && version == self.currentVersion {
            return
        }
        self.currentURL = url
        self.currentVersion = version
        self.stopFeeder()
        self.displayLayer.flushAndRemoveImage()
        self.contentTransform = .identity
        self.setNeedsLayout()
        if let url, FileManager.default.fileExists(atPath: url.path) {
            self.playableURL = url
        } else {
            self.playableURL = nil
        }
        self.updatePlayback()
    }

    private func updatePlayback() {
        let shouldPlay = self.window != nil && UIApplication.shared.applicationState != .background
        if shouldPlay && self.playableURL != nil {
            if self.feeder == nil || self.displayLayer.status == .failed || self.displayLayer.requiresFlushToResumeDecoding {
                self.startFeeder()
            }
        }
        if let timebase = self.timebase {
            CMTimebaseSetRate(timebase, rate: shouldPlay ? 1.0 : 0.0)
        }
    }

    private func stopFeeder() {
        self.feeder?.stop()
        self.feeder = nil
        if let timebase = self.timebase {
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
    }

    /// From the first frame, on a new clock; also how a layer that failed (decoder lost in the
    /// background) starts over.
    private func startFeeder() {
        self.stopFeeder()
        self.displayLayer.flush()
        guard let url = self.playableURL else {
            return
        }
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        guard let timebase else {
            return
        }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0.0)
        self.displayLayer.controlTimebase = timebase
        self.timebase = timebase
        let feeder = GGLoopingVideoFeeder(url: url, layer: self.displayLayer, timebase: timebase)
        self.feeder = feeder
        feeder.start(prepared: { [weak self, weak feeder] transform in
            guard let self, let feeder, self.feeder === feeder else {
                return
            }
            if self.contentTransform != transform {
                self.contentTransform = transform
                self.setNeedsLayout()
            }
        })
    }
}

/// Reads one video track over and over and feeds its compressed frames to the layer. Each pass is a new
/// `AVAssetReader`, its frames shifted by the length of the passes before it. State lives on `queue`;
/// `stop()` is called on main and nothing reaches the layer after it returns. The request for frames
/// is installed and removed on `queue` only: a view that restarts stops the old feeder before it
/// starts the new one, so the old removal always runs before the new installation.
private final class GGLoopingVideoFeeder {
    private static let queue = DispatchQueue(label: "org.ghostgram.appearance.loopingVideo", qos: .userInitiated)

    private let url: URL
    private let layer: AVSampleBufferDisplayLayer
    private let timebase: CMTimebase

    private let stopLock = NSLock()
    private var isStopped = false

    // `queue` only
    private var asset: AVURLAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var passOffset: CMTime = .zero
    private var passEnd: CMTime = .zero
    private var passSamples = 0
    private var hasSetClock = false

    init(url: URL, layer: AVSampleBufferDisplayLayer, timebase: CMTimebase) {
        self.url = url
        self.layer = layer
        self.timebase = timebase
    }

    /// Main thread. `prepared` gets the track's orientation, on main.
    func start(prepared: @escaping (CGAffineTransform) -> Void) {
        GGLoopingVideoFeeder.queue.async { [self] in
            if self.stopped {
                return
            }
            let asset = AVURLAsset(url: self.url)
            guard let track = asset.tracks(withMediaType: .video).first else {
                return
            }
            self.asset = asset
            self.track = track
            let preferred = track.preferredTransform
            let transform = CGAffineTransform(a: preferred.a, b: preferred.b, c: preferred.c, d: preferred.d, tx: 0.0, ty: 0.0)
            DispatchQueue.main.async {
                prepared(transform)
            }
            guard self.openPass() else {
                return
            }
            self.layer.requestMediaDataWhenReady(on: GGLoopingVideoFeeder.queue, using: { [weak self] in
                self?.feed()
            })
        }
    }

    /// Main thread.
    func stop() {
        self.stopLock.lock()
        self.isStopped = true
        self.stopLock.unlock()
        GGLoopingVideoFeeder.queue.async {
            self.layer.stopRequestingMediaData()
            self.reader?.cancelReading()
            self.reader = nil
            self.output = nil
            self.track = nil
            self.asset = nil
        }
    }

    private var stopped: Bool {
        self.stopLock.lock()
        defer {
            self.stopLock.unlock()
        }
        return self.isStopped
    }

    /// Enqueues unless stopped; under the lock, so `stop()` returning means nothing more arrives.
    private func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        self.stopLock.lock()
        defer {
            self.stopLock.unlock()
        }
        if self.isStopped {
            return false
        }
        self.layer.enqueue(sampleBuffer)
        return true
    }

    private func feed() {
        while self.layer.isReadyForMoreMediaData {
            if self.stopped {
                return
            }
            guard let sampleBuffer = self.nextSample() else {
                // A read error or an empty file: the last frame stays on screen.
                if !self.stopped {
                    self.layer.stopRequestingMediaData()
                }
                return
            }
            if !self.enqueue(sampleBuffer) {
                return
            }
        }
    }

    private func openPass() -> Bool {
        guard let asset = self.asset, let track = self.track else {
            return false
        }
        self.reader?.cancelReading()
        self.reader = nil
        self.output = nil
        guard let reader = try? AVAssetReader(asset: asset) else {
            return false
        }
        // No output settings: the frames stay compressed, the layer decodes them.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return false
        }
        reader.add(output)
        guard reader.startReading() else {
            return false
        }
        self.reader = reader
        self.output = output
        self.passEnd = .zero
        self.passSamples = 0
        return true
    }

    private func nextSample() -> CMSampleBuffer? {
        while !self.stopped {
            if let sampleBuffer = self.output?.copyNextSampleBuffer() {
                // A marker without samples or a frame without timing is skipped.
                if CMSampleBufferGetNumSamples(sampleBuffer) == 0 {
                    continue
                }
                if let shifted = self.shifted(sampleBuffer) {
                    return shifted
                }
                continue
            }
            // The pass ended. A pass that gave nothing (or failed) ends playback instead of spinning.
            guard self.reader?.status == .completed, self.passSamples > 0 else {
                return nil
            }
            var length = self.passEnd
            if let duration = self.track?.timeRange.duration, duration.isNumeric, duration > length {
                length = duration
            }
            guard length.isNumeric, length > .zero else {
                return nil
            }
            self.passOffset = self.passOffset + length
            guard self.openPass() else {
                return nil
            }
        }
        return nil
    }

    /// The frame moved by the passes before it; the pass's end is measured on the way.
    private func shifted(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else {
            return nil
        }
        var timing = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        self.passSamples += 1
        var firstPresentation: CMTime?
        for i in 0 ..< timing.count {
            let presentation = timing[i].presentationTimeStamp
            if presentation.isNumeric {
                let end = timing[i].duration.isNumeric ? presentation + timing[i].duration : presentation
                if end > self.passEnd {
                    self.passEnd = end
                }
                timing[i].presentationTimeStamp = presentation + self.passOffset
                if firstPresentation == nil {
                    firstPresentation = timing[i].presentationTimeStamp
                }
            }
            if timing[i].decodeTimeStamp.isNumeric {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + self.passOffset
            }
        }
        if !self.hasSetClock, let firstPresentation {
            self.hasSetClock = true
            // The clock starts at the first frame (an edit list may start the track later than zero).
            CMTimebaseSetTime(self.timebase, time: firstPresentation)
        }
        if self.passOffset == .zero {
            return sampleBuffer
        }
        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result)
        return result
    }
}

/// Snowfall (snowfall + the former New Year wallpaper effect): a `CAEmitterLayer`, drawn by the
/// render server — no per-frame CPU work, no part in theme rebuilds. Stops in Low Power Mode and
/// with Reduce Motion.
///
/// The old Ghostgram's look (Telegram-Android's `SnowflakesEffect`): flakes are born all over the
/// view and drift down for a few seconds. Build 188 spawned them above the top edge only and let
/// them fall at 36 pt a second — the first seconds of snow sat under the glass header, then a
/// dozen flakes a second crossed the screen: «не отображается».
final class GGSnowView: UIView {
    enum Kind {
        /// The chat list header: 18 flakes a second living ~2 s.
        case header
        /// Behind messages: 75 a second for a full screen (by area), living 3–5 s.
        case background
    }

    private let kind: Kind
    private let emitterLayer = CAEmitterLayer()
    private var currentStyle: GGSnowStyle?
    private var currentIntensity: Double = -1.0
    private var areaFactor: CGFloat = 1.0
    private var isPaused = false

    init(frame: CGRect, kind: Kind) {
        self.kind = kind
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.emitterLayer.emitterShape = .rectangle
        self.emitterLayer.emitterMode = .volume
        self.emitterLayer.renderMode = .unordered
        self.emitterLayer.seed = UInt32.random(in: 0 ... UInt32.max)
        // Nothing is born until the view is in a window (`willMove(toWindow:)`).
        self.emitterLayer.birthRate = 0.0
        self.layer.addSublayer(self.emitterLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(style: GGSnowStyle, intensity: Double, isPaused: Bool) {
        self.isPaused = isPaused
        if style != self.currentStyle || intensity != self.currentIntensity {
            self.currentStyle = style
            self.currentIntensity = intensity
            self.rebuildCells()
        }
        self.updateBirthRate(isInWindow: self.window != nil)
        self.isHidden = isPaused
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        self.updateBirthRate(isInWindow: newWindow != nil)
    }

    /// The layer's birth rate multiplies every cell's: 0 off screen or paused (the live flakes
    /// finish their life), 1 otherwise.
    private func updateBirthRate(isInWindow: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.emitterLayer.birthRate = (isInWindow && !self.isPaused) ? 1.0 : 0.0
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.emitterLayer.frame = self.bounds
        self.emitterLayer.emitterPosition = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        self.emitterLayer.emitterSize = self.bounds.size
        CATransaction.commit()

        let screen = UIScreen.main.bounds.size
        let areaFactor: CGFloat
        switch self.kind {
        case .header:
            areaFactor = 1.0
        case .background:
            areaFactor = max(0.12, min(1.0, (self.bounds.width * self.bounds.height) / max(1.0, screen.width * screen.height)))
        }
        if abs(self.areaFactor - areaFactor) > 0.01 {
            self.areaFactor = areaFactor
            self.rebuildCells()
        }
    }

    private func rebuildCells() {
        guard let style = self.currentStyle else {
            return
        }
        let intensity = Float(max(0.0, min(1.0, self.currentIntensity)))
        let totalBirthRate: Float
        let lifetime: (mean: Float, range: Float)
        switch self.kind {
        case .header:
            totalBirthRate = 18.0 * intensity
            lifetime = (2.05, 0.05)
        case .background:
            totalBirthRate = 75.0 * Float(self.areaFactor) * intensity
            lifetime = (4.0, 1.0)
        }
        var cells: [CAEmitterCell] = []
        switch style {
        case .snow:
            // Android's two dots: half 2.5 pt, half 1 pt, white.
            for diameter in [2.5, 1.0] as [CGFloat] {
                let cell = self.makeCell(image: GGSnowView.dotImage(diameter: diameter), birthRate: totalBirthRate * 0.5, lifetime: lifetime)
                cell.color = UIColor(white: 1.0, alpha: 0.9).cgColor
                cells.append(cell)
            }
        case .lightning:
            // Fewer and bigger: a bolt is a glyph, not a dot.
            let cell = self.makeCell(image: GGSnowView.boltImage(), birthRate: totalBirthRate * 0.25, lifetime: lifetime)
            cell.color = UIColor(rgb: 0xffd84a, alpha: 0.95).cgColor
            cell.scale = 1.0
            cell.scaleRange = 0.35
            cell.spinRange = 0.2
            cells.append(cell)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.emitterLayer.emitterCells = cells
        CATransaction.commit()
    }

    private func makeCell(image: UIImage?, birthRate: Float, lifetime: (mean: Float, range: Float)) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image?.cgImage
        // The images are drawn at the screen scale: without this a flake is three times larger.
        cell.contentsScale = image?.scale ?? UIScreen.main.scale
        cell.birthRate = birthRate
        cell.lifetime = lifetime.mean
        cell.lifetimeRange = lifetime.range
        // 40–48 pt a second, mostly downwards (π/2 points down here), ±20° of drift.
        cell.velocity = 44.0
        cell.velocityRange = 4.0
        cell.emissionLongitude = .pi / 2.0
        cell.emissionRange = .pi / 9.0 * 2.0
        // A linear fade-out over the life.
        cell.alphaSpeed = -1.0 / lifetime.mean
        return cell
    }

    private static var dots: [CGFloat: UIImage] = [:]
    private static var bolt: UIImage?

    private static func dotImage(diameter: CGFloat) -> UIImage? {
        if let image = GGSnowView.dots[diameter] {
            return image
        }
        let canvas = ceil(diameter) + 2.0
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: (canvas - diameter) * 0.5, y: (canvas - diameter) * 0.5, width: diameter, height: diameter))
        }
        GGSnowView.dots[diameter] = image
        return image
    }

    /// A CAEmitterCell needs a CGImage, and an SF Symbol has none (`cgImage` is nil for a symbol
    /// image): the bolt is rasterized once.
    private static func boltImage() -> UIImage? {
        if let image = GGSnowView.bolt {
            return image
        }
        let side: CGFloat = 14.0
        guard let symbol = UIImage(systemName: "bolt.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .bold))?.withTintColor(.white, renderingMode: .alwaysOriginal) else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let symbolSize = symbol.size
            symbol.draw(in: CGRect(x: (side - symbolSize.width) * 0.5, y: (side - symbolSize.height) * 0.5, width: symbolSize.width, height: symbolSize.height))
        }
        GGSnowView.bolt = image
        return image
    }
}

/// The screen-edge bands of the chat and the chat list (chat_blur_gradient): a variable blur band
/// and a color gradient band at one edge, each with its own size and strength. Both are upstream
/// primitives (EdgeEffect); this view only places and paints them.
final class GGEdgeBandView: UIView {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge
    private var blurView: VariableBlurView?
    private var blurRadius: CGFloat = 0.0
    private let tintView = EdgeEffectView()
    private let gradientView = EdgeEffectView()

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: CGRect())
        self.isUserInteractionEnabled = false
        self.addSubview(self.tintView)
        self.addSubview(self.gradientView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    struct Band: Equatable {
        var color: UIColor
        var size: CGFloat
        var intensity: CGFloat
    }

    /// `inset` = the bar at that edge (navigation bar, input panel); bands extend `size` beyond it.
    func update(width: CGFloat, inset: CGFloat, blur: Band?, gradient: Band?) {
        let height = inset + max(blur?.size ?? 0.0, gradient?.size ?? 0.0)
        let frameHeight = max(1.0, height)
        let edgeEffectEdge: EdgeEffectView.Edge = self.edge == .top ? .top : .bottom

        if let blur, blur.intensity > 0.0 {
            let radius = 1.0 + 19.0 * blur.intensity
            if self.blurView == nil || self.blurRadius != radius {
                self.blurView?.removeFromSuperview()
                let blurView = VariableBlurView(maxBlurRadius: radius)
                self.insertSubview(blurView, at: 0)
                self.blurView = blurView
                self.blurRadius = radius
            }
            if let blurView = self.blurView {
                let blurHeight = inset + blur.size
                blurView.frame = CGRect(x: 0.0, y: self.edge == .top ? 0.0 : frameHeight - blurHeight, width: width, height: blurHeight)
                blurView.update(size: blurView.frame.size, constantHeight: max(1.0, inset), isInverted: self.edge == .bottom, gradient: EdgeEffectView.generateEdgeGradientData(baseHeight: max(1.0, blur.size)), transition: .immediate)
            }
            self.tintView.isHidden = false
            let tintHeight = inset + blur.size
            self.tintView.frame = CGRect(x: 0.0, y: self.edge == .top ? 0.0 : frameHeight - tintHeight, width: width, height: tintHeight)
            self.tintView.update(content: blur.color, blur: false, alpha: 0.35 * blur.intensity, rect: self.tintView.frame, edge: edgeEffectEdge, edgeSize: max(1.0, blur.size), transition: .immediate)
        } else {
            self.blurView?.removeFromSuperview()
            self.blurView = nil
            self.tintView.isHidden = true
        }

        if let gradient, gradient.intensity > 0.0 {
            self.gradientView.isHidden = false
            let gradientHeight = inset + gradient.size
            self.gradientView.frame = CGRect(x: 0.0, y: self.edge == .top ? 0.0 : frameHeight - gradientHeight, width: width, height: gradientHeight)
            self.gradientView.update(content: gradient.color, blur: false, alpha: gradient.intensity, rect: self.gradientView.frame, edge: edgeEffectEdge, edgeSize: max(1.0, gradient.size), transition: .immediate)
        } else {
            self.gradientView.isHidden = true
        }
    }
}
