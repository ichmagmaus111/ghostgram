import Foundation
import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import SwiftSignalKit
import TelegramVoip
import AccountContext
import GGCore
import GGCallCameraHooks
import GGCallsMediaHooks

/// The library of the virtual camera: files in `Application Support/ghostgram/virtual-camera/`,
/// metadata in the settings registry (`GGVirtualCameraSettings.items`).
enum GGVirtualCameraLibrary {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ghostgram/virtual-camera", isDirectory: true)
    }

    static func url(for item: GGVirtualCameraItem) -> URL {
        return GGVirtualCameraLibrary.directory.appendingPathComponent(GGMaskStore.safeComponent(item.fileName))
    }

    /// Any thread (a picker's file callback, whose file is deleted when the callback returns):
    /// copies the file into the library now, registers it on the main thread.
    static func importFile(at source: URL, title: String, completion: @escaping (GGVirtualCameraItem?) -> Void) {
        let id = UUID().uuidString.lowercased()
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension.lowercased()
        let item = GGVirtualCameraItem(id: id, title: title, fileName: id + "." + ext, kind: GGVirtualCameraLibrary.kind(forExtension: ext), createdAt: Date().timeIntervalSince1970)
        var copied = false
        do {
            try FileManager.default.createDirectory(at: GGVirtualCameraLibrary.directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: GGVirtualCameraLibrary.url(for: item))
            copied = true
        } catch {
            copied = false
        }
        DispatchQueue.main.async {
            guard copied else {
                completion(nil)
                return
            }
            GGVirtualCameraSettings.items.set(GGVirtualCameraSettings.items.value + [item])
            completion(item)
        }
    }

    static func rename(id: String, title: String) {
        GGVirtualCameraSettings.items.set(GGVirtualCameraSettings.items.value.map { item in
            var item = item
            if item.id == id {
                item.title = title
            }
            return item
        })
    }

    static func remove(id: String) {
        guard let item = GGVirtualCameraSettings.items.value.first(where: { $0.id == id }) else {
            return
        }
        try? FileManager.default.removeItem(at: GGVirtualCameraLibrary.url(for: item))
        GGVirtualCameraSettings.items.set(GGVirtualCameraSettings.items.value.filter { $0.id != id })
        if GGVirtualCameraSettings.selected.value == id {
            GGVirtualCameraSettings.selected.set("")
        }
    }

    /// Launch: moves the old app's camera media (`Documents/ggcall/camera/`) here, off the launch
    /// thread. Every file is moved by name (the settings migration carries the list over with the
    /// same names); a file that can not be moved stays and is retried on the next launch.
    static func migrateLegacyFilesIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }
            let legacy = documents.appendingPathComponent("ggcall/camera", isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return
            }
            try? fileManager.createDirectory(at: GGVirtualCameraLibrary.directory, withIntermediateDirectories: true)
            var keptAny = false
            for url in urls {
                let target = GGVirtualCameraLibrary.directory.appendingPathComponent(GGMaskStore.safeComponent(url.lastPathComponent))
                // Already here (an earlier, interrupted move): the old copy is a duplicate.
                if fileManager.fileExists(atPath: target.path) {
                    continue
                }
                if (try? fileManager.moveItem(at: url, to: target)) == nil {
                    keptAny = true
                }
            }
            if !keptAny {
                try? fileManager.removeItem(at: legacy)
            }
        }
    }

    static func kind(forExtension ext: String) -> GGVirtualCameraItem.Kind {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v", "qt":
            return .video
        case "gif":
            return .gif
        default:
            return .image
        }
    }

    /// A small preview of an item (off the main thread).
    static func thumbnail(_ item: GGVirtualCameraItem) -> Signal<UIImage?, NoError> {
        return Signal { subscriber in
            let url = GGVirtualCameraLibrary.url(for: item)
            var image: UIImage?
            switch item.kind {
            case .image, .gif:
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary) {
                    image = UIImage(cgImage: cgImage)
                }
            case .video:
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240.0, height: 240.0)
                if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    image = UIImage(cgImage: cgImage)
                }
            }
            subscriber.putNext(image)
            subscriber.putCompletion()
            return EmptyDisposable
        } |> runOn(Queue.concurrentDefaultQueue())
    }
}

/// Frames of one library item: a still image or the frames of a GIF as BGRA pixel buffers (decoded
/// and uploaded once, not re-wrapped every frame), a video decoded as it plays. A GIF whose frames
/// would not fit `preloadBudgetBytes` is decoded frame by frame as it plays, into a small pool of
/// buffers: 120 frames of 1080 px kept at once were half a gigabyte next to the call.
private final class GGVirtualCameraMedia {
    /// All frames of a GIF are kept decoded only up to this size.
    static let preloadBudgetBytes = 64 * 1024 * 1024

    private var frames: [(buffer: CVPixelBuffer, delay: Double)] = []
    private var totalDuration: Double = 0.0
    /// A GIF decoded as it plays: its source, the delay of every frame, the frame shown now.
    private var streamSource: CGImageSource?
    private var streamDelays: [Double] = []
    private var streamPool: CVPixelBufferPool?
    private var streamIndex = -1
    private var streamBuffer: CVPixelBuffer?
    private let videoUrl: URL?
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var videoStart: Double = 0.0
    private var lastVideoBuffer: CVPixelBuffer?
    private var nextVideoTime: Double = 0.0
    private var videoTransform: CGAffineTransform = .identity
    private let loops: Bool
    private let start = CACurrentMediaTime()

    init?(item: GGVirtualCameraItem, loops: Bool) {
        self.loops = loops
        let url = GGVirtualCameraLibrary.url(for: item)
        switch item.kind {
        case .image, .gif:
            self.videoUrl = nil
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let count = max(1, min(120, CGImageSourceGetCount(source)))
            guard let first = GGVirtualCameraMedia.decodeFrame(source, index: 0) else {
                return nil
            }
            let frameBytes = (first.width - first.width % 4) * (first.height - first.height % 4) * 4
            if count > 1 && frameBytes * count > GGVirtualCameraMedia.preloadBudgetBytes {
                guard let pool = GGVirtualCameraMedia.makePool(width: first.width - first.width % 4, height: first.height - first.height % 4), let buffer = GGVirtualCameraMedia.pixelBuffer(from: first, pool: pool) else {
                    return nil
                }
                self.streamSource = source
                self.streamPool = pool
                self.streamDelays = (0 ..< count).map { GGVirtualCameraMedia.frameDelay(source, index: $0) }
                self.totalDuration = self.streamDelays.reduce(0.0, +)
                self.streamIndex = 0
                self.streamBuffer = buffer
            } else {
                for index in 0 ..< count {
                    guard let cgImage = index == 0 ? first : GGVirtualCameraMedia.decodeFrame(source, index: index), let buffer = GGVirtualCameraMedia.pixelBuffer(from: cgImage, pool: nil) else {
                        continue
                    }
                    let delay = GGVirtualCameraMedia.frameDelay(source, index: index)
                    self.frames.append((buffer, delay))
                    self.totalDuration += delay
                }
                if self.frames.isEmpty {
                    return nil
                }
            }
        case .video:
            self.videoUrl = url
            if !self.openReader() {
                return nil
            }
        }
    }

    private func openReader() -> Bool {
        guard let url = self.videoUrl else {
            return false
        }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else {
            return false
        }
        // AVAssetReader, not AVPlayer: the call's audio session is left alone.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return false
        }
        reader.add(output)
        guard reader.startReading() else {
            return false
        }
        self.videoTransform = track.preferredTransform
        self.reader = reader
        self.readerOutput = output
        self.videoStart = CACurrentMediaTime()
        self.nextVideoTime = 0.0
        return true
    }

    /// The frame for now (wall-clock paced) and how it must be turned upright.
    func currentFrame() -> (CVPixelBuffer, CGImagePropertyOrientation)? {
        if self.videoUrl != nil {
            return self.currentVideoFrame()
        }
        if self.streamSource != nil {
            return self.currentStreamedFrame()
        }
        if self.frames.count == 1 || self.totalDuration <= 0.0 {
            return (self.frames[0].buffer, .up)
        }
        var t = (CACurrentMediaTime() - self.start).truncatingRemainder(dividingBy: self.totalDuration)
        for frame in self.frames {
            if t < frame.delay {
                return (frame.buffer, .up)
            }
            t -= frame.delay
        }
        return (self.frames[self.frames.count - 1].buffer, .up)
    }

    /// The GIF frame for now, decoded only when the frame changes (a frame that fails keeps the
    /// previous picture).
    private func currentStreamedFrame() -> (CVPixelBuffer, CGImagePropertyOrientation)? {
        guard let source = self.streamSource, self.totalDuration > 0.0 else {
            return self.streamBuffer.map { ($0, .up) }
        }
        var t = (CACurrentMediaTime() - self.start).truncatingRemainder(dividingBy: self.totalDuration)
        var index = self.streamDelays.count - 1
        for (candidate, delay) in self.streamDelays.enumerated() {
            if t < delay {
                index = candidate
                break
            }
            t -= delay
        }
        if index != self.streamIndex {
            self.streamIndex = index
            if let image = GGVirtualCameraMedia.decodeFrame(source, index: index), let buffer = GGVirtualCameraMedia.pixelBuffer(from: image, pool: self.streamPool) {
                self.streamBuffer = buffer
            }
        }
        return self.streamBuffer.map { ($0, .up) }
    }

    private static func decodeFrame(_ source: CGImageSource, index: Int) -> CGImage? {
        return CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1280, kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        var delay = 0.1
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any], let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let value = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, value > 0.0 {
                delay = value
            } else if let value = gif[kCGImagePropertyGIFDelayTime] as? Double, value > 0.0 {
                delay = value
            }
        }
        if delay < 0.02 {
            delay = 0.1
        }
        return delay
    }

    /// A few BGRA buffers of one size, reused frame after frame.
    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        guard width > 0, height > 0 else {
            return nil
        }
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, bufferAttributes as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }

    private func currentVideoFrame() -> (CVPixelBuffer, CGImagePropertyOrientation)? {
        let elapsed = CACurrentMediaTime() - self.videoStart
        var pulls = 0
        while elapsed >= self.nextVideoTime && pulls < 8 {
            pulls += 1
            if let sampleBuffer = self.readerOutput?.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                self.lastVideoBuffer = buffer
                self.nextVideoTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            } else {
                if self.loops {
                    self.reader?.cancelReading()
                    if !self.openReader() {
                        break
                    }
                } else {
                    break
                }
            }
        }
        guard let buffer = self.lastVideoBuffer else {
            return nil
        }
        return (buffer, GGVirtualCameraMedia.orientation(self.videoTransform))
    }

    private static func orientation(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(transform.b, transform.a)
        if abs(angle - .pi / 2.0) < 0.1 {
            return .right
        } else if abs(angle + .pi / 2.0) < 0.1 {
            return .left
        } else if abs(abs(angle) - .pi) < 0.1 {
            return .down
        }
        return .up
    }

    /// `pool`: a buffer of the pool's size (the picture is drawn into it); nil: a new buffer of the
    /// picture's own size.
    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
                return nil
            }
        } else {
            let width = image.width - image.width % 4
            let height = image.height - image.height % 4
            guard width > 0, height > 0 else {
                return nil
            }
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess else {
                return nil
            }
        }
        guard let buffer else {
            return nil
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// A black 640×360 frame (sent while the item loads, so the real camera never shows).
    static let blackFrame: CVPixelBuffer? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640.0, height: 360.0), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0.0, y: 0.0, width: 640.0, height: 360.0))
        }
        return image.cgImage.flatMap { GGVirtualCameraMedia.pixelBuffer(from: $0, pool: nil) }
    }()
}

/// Feeds a custom call capturer from the library at 30 fps while the call keeps the capturer.
/// The device camera is never started for it. The pump stops when the capturer goes away. Once the
/// call stopped sending its own video (`GGCameraCallsMonitor`), a capturer made before that idles:
/// no decoding, the last frame again once a second (a capturer the call keeps after the camera was
/// turned off, e.g. a 1:1 call moved into a conference, decoded a video 30 times a second for the
/// rest of the call).
final class GGVirtualCameraFeeder {
    private static let lock = NSLock()
    private static var feeders: [ObjectIdentifier: GGVirtualCameraFeeder] = [:]
    /// nil: unknown (the calls are not watched) — never idle then.
    private static var isLocalVideoSending: Bool?
    /// Grows each time the calls stop sending their own video.
    private static var localVideoStopEpoch = 0

    /// `GGCameraCallsMonitor`, main thread.
    static func setLocalVideoSending(_ value: Bool?) {
        GGVirtualCameraFeeder.lock.lock()
        if GGVirtualCameraFeeder.isLocalVideoSending != false && value == false {
            GGVirtualCameraFeeder.localVideoStopEpoch += 1
        }
        GGVirtualCameraFeeder.isLocalVideoSending = value
        GGVirtualCameraFeeder.lock.unlock()
    }

    /// A substitute capturer is alive (the call screen's strip: a switch to the real camera needs a
    /// new capturer).
    static var hasLiveCapturer: Bool {
        GGVirtualCameraFeeder.lock.lock()
        defer {
            GGVirtualCameraFeeder.lock.unlock()
        }
        return GGVirtualCameraFeeder.feeders.values.contains(where: { $0.capturer != nil })
    }

    private static func currentLocalVideoState() -> (isSending: Bool?, stopEpoch: Int) {
        GGVirtualCameraFeeder.lock.lock()
        defer {
            GGVirtualCameraFeeder.lock.unlock()
        }
        return (GGVirtualCameraFeeder.isLocalVideoSending, GGVirtualCameraFeeder.localVideoStopEpoch)
    }

    private weak var capturer: OngoingCallVideoCapturer?
    private let capturerId: ObjectIdentifier
    private let queue = DispatchQueue(label: "org.ghostgram.virtualCamera", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var media: GGVirtualCameraMedia?
    private var mediaItemId: String?
    private var isLoading = false
    private var inFlight = false
    private var formatDescription: CMVideoFormatDescription?
    private var settingsDisposable: Disposable?
    /// The stop epoch when this capturer was made: a later stop idles it, an earlier one does not
    /// (the camera preview before the video is turned on again needs real frames).
    private let creationStopEpoch: Int
    private var lastFrame: (CVPixelBuffer, CGImagePropertyOrientation)?
    private var lastIdleFrameTime: Double = 0.0

    /// The `GGCallCameraHooks.cameraCapturer` handler: a fed capturer while a library item is chosen.
    static func makeCapturer() -> OngoingCallVideoCapturer? {
        guard GGVirtualCameraSettings.selectedItem != nil else {
            return nil
        }
        let capturer = OngoingCallVideoCapturer(isCustom: true)
        let feeder = GGVirtualCameraFeeder(capturer: capturer)
        GGVirtualCameraFeeder.lock.lock()
        GGVirtualCameraFeeder.feeders[ObjectIdentifier(capturer)] = feeder
        GGVirtualCameraFeeder.lock.unlock()
        feeder.start()
        return capturer
    }

    /// The `GGCallCameraHooks.cameraSwitch` handler: our capturer has no device to switch, and
    /// switching must not start the real camera behind the substitute.
    static func switchCamera(capturer: OngoingCallVideoCapturer, isFront: Bool) -> Bool {
        GGVirtualCameraFeeder.lock.lock()
        let isOurs = GGVirtualCameraFeeder.feeders[ObjectIdentifier(capturer)] != nil
        GGVirtualCameraFeeder.lock.unlock()
        return isOurs
    }

    private init(capturer: OngoingCallVideoCapturer) {
        self.capturer = capturer
        self.capturerId = ObjectIdentifier(capturer)
        self.creationStopEpoch = GGVirtualCameraFeeder.currentLocalVideoState().stopEpoch
    }

    private func start() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
        // The item can change during the call (the strip in the call screen).
        self.settingsDisposable = (combineLatest(GGVirtualCameraSettings.selected.signal, GGVirtualCameraSettings.loop.signal) |> deliverOn(Queue(queue: self.queue))).start(next: { [weak self] _, _ in
            self?.media = nil
            self?.mediaItemId = nil
        })
    }

    private func stop() {
        self.timer?.cancel()
        self.timer = nil
        self.settingsDisposable?.dispose()
        GGVirtualCameraFeeder.lock.lock()
        GGVirtualCameraFeeder.feeders[self.capturerId] = nil
        GGVirtualCameraFeeder.lock.unlock()
    }

    private func tick() {
        guard let capturer = self.capturer else {
            self.stop()
            return
        }
        if self.inFlight {
            return
        }
        let localVideo = GGVirtualCameraFeeder.currentLocalVideoState()
        if localVideo.isSending == false && localVideo.stopEpoch > self.creationStopEpoch {
            // The call stopped sending this video: nothing is decoded, the last frame once a second
            // (a capturer that is asked for video again picks up at once).
            let now = CACurrentMediaTime()
            if now - self.lastIdleFrameTime < 1.0 {
                return
            }
            self.lastIdleFrameTime = now
            guard let buffer = self.lastFrame?.0 ?? GGVirtualCameraMedia.blackFrame, let sampleBuffer = self.sampleBuffer(buffer) else {
                return
            }
            self.inject(sampleBuffer, rotation: self.lastFrame?.1 ?? .up, capturer: capturer)
            return
        }
        let item = GGVirtualCameraSettings.selectedItem
        if item?.id != self.mediaItemId, !self.isLoading {
            self.media = nil
            self.mediaItemId = item?.id
            if let item {
                self.isLoading = true
                let loops = GGVirtualCameraSettings.loop.value
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let media = GGVirtualCameraMedia(item: item, loops: loops)
                    self?.queue.async {
                        guard let self else {
                            return
                        }
                        self.isLoading = false
                        if self.mediaItemId == item.id {
                            self.media = media
                        }
                    }
                }
            }
        }
        let frame = self.media?.currentFrame()
        if let frame {
            self.lastFrame = frame
        }
        guard let buffer = frame?.0 ?? GGVirtualCameraMedia.blackFrame else {
            return
        }
        guard let sampleBuffer = self.sampleBuffer(buffer) else {
            return
        }
        self.inject(sampleBuffer, rotation: frame?.1 ?? .up, capturer: capturer)
    }

    private func inject(_ sampleBuffer: CMSampleBuffer, rotation: CGImagePropertyOrientation, capturer: OngoingCallVideoCapturer) {
        self.inFlight = true
        capturer.injectSampleBuffer(sampleBuffer, rotation: rotation, completion: { [weak self] in
            self?.queue.async {
                self?.inFlight = false
            }
        })
    }

    private func sampleBuffer(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        if let current = self.formatDescription, CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: buffer) {
        } else {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description)
            self.formatDescription = description
        }
        guard let formatDescription = self.formatDescription else {
            return nil
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }
}

/// The «Instead of the camera» button of the call screen's column: the strip of library items.
/// The kind of capturer is fixed when the call's camera starts, so a choice that switches between the
/// real camera and a substitute restarts the call's camera the way its own button does
/// (`disableVideo` → `requestVideo`, which asks `GGCallCameraHooks.cameraCapturer` again); a choice
/// between two library items needs nothing (the feeder follows the setting).
final class GGVirtualCameraOverlayItem: GGCallOverlayItem {
    private var panel: GGVirtualCameraStrip?
    private weak var call: PresentationCall?
    private weak var groupCall: PresentationGroupCall?
    private var hasLocalVideo = false
    private let restartDisposable = MetaDisposable()

    init(call: PresentationCall?, groupCall: PresentationGroupCall?) {
        self.call = call
        self.groupCall = groupCall
    }

    deinit {
        self.restartDisposable.dispose()
    }

    var id: String {
        return "cameraMasks.virtualCamera"
    }

    var order: Int {
        return 200
    }

    var icon: UIImage? {
        return UIImage(systemName: "photo.on.rectangle")
    }

    func isVisible(state: GGCallScreenState) -> Bool {
        self.hasLocalVideo = state.hasLocalVideo && !state.isTerminated
        return self.hasLocalVideo && GGVirtualCameraSettings.enabled.value
    }

    func makePanel() -> UIView? {
        let panel = GGVirtualCameraStrip()
        panel.frame = CGRect(x: 0.0, y: 0.0, width: 320.0, height: GGMaskChipsPanel.height)
        panel.selectionChanged = { [weak self] in
            self?.applySelectionToRunningCamera()
        }
        self.panel = panel
        return panel
    }

    private func applySelectionToRunningCamera() {
        let wantsSubstitute = GGVirtualCameraSettings.selectedItem != nil
        guard self.hasLocalVideo, wantsSubstitute != GGVirtualCameraFeeder.hasLiveCapturer else {
            return
        }
        if let groupCall = self.groupCall {
            groupCall.disableVideo()
            groupCall.requestVideo()
        } else if let call = self.call {
            call.disableVideo()
            // The 1:1 call reports the camera off asynchronously; the screen rebuilds its own preview
            // from the new capturer only after it saw the video stop.
            let stopped: Signal<PresentationCallState?, NoError> = call.state
            |> filter { state in
                return GGVirtualCameraOverlayItem.isVideoOff(state)
            }
            |> map { state -> PresentationCallState? in
                return state
            }
            |> take(1)
            |> timeout(1.5, queue: Queue.mainQueue(), alternate: .single(nil))
            self.restartDisposable.set((stopped
            |> deliverOnMainQueue).start(next: { [weak call] state in
                guard let call else {
                    return
                }
                if let state, GGVirtualCameraOverlayItem.isEnded(state) {
                    return
                }
                call.requestVideo()
            }))
        }
    }

    private static func isEnded(_ state: PresentationCallState) -> Bool {
        switch state.state {
        case .terminating, .terminated:
            return true
        default:
            return false
        }
    }

    private static func isVideoOff(_ state: PresentationCallState) -> Bool {
        if GGVirtualCameraOverlayItem.isEnded(state) {
            return true
        }
        switch state.videoState {
        case .inactive, .notAvailable:
            return true
        case .active, .paused:
            return false
        }
    }

    func buttonTapped() {
    }

    func screenWillClose() {
        self.panel?.invalidate()
        self.panel = nil
        self.restartDisposable.set(nil)
    }
}

/// Chips of the library items; the selected one has a ring. The choice applies to the running call
/// (`selectionChanged`).
final class GGVirtualCameraStrip: UIView {
    var selectionChanged: (() -> Void)?
    private let scrollView = UIScrollView()
    private var chips: [(id: String, view: UIButton)] = []
    private let disposables = DisposableSet()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        self.layer.cornerRadius = 18.0
        self.clipsToBounds = true
        self.scrollView.showsHorizontalScrollIndicator = false
        self.addSubview(self.scrollView)
        var items: [(id: String, title: String?)] = [("", "✕")]
        for item in GGVirtualCameraSettings.items.value {
            items.append((item.id, nil))
        }
        for entry in items {
            let button = UIButton(type: .custom)
            button.backgroundColor = UIColor(white: 1.0, alpha: 0.15)
            button.clipsToBounds = true
            if let title = entry.title {
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 24.0)
            } else if let item = GGVirtualCameraSettings.items.value.first(where: { $0.id == entry.id }) {
                self.disposables.add((GGVirtualCameraLibrary.thumbnail(item) |> deliverOnMainQueue).start(next: { [weak button] image in
                    button?.setImage(image, for: .normal)
                    button?.imageView?.contentMode = .scaleAspectFill
                }))
            }
            button.addTarget(self, action: #selector(self.chipPressed(_:)), for: .touchUpInside)
            self.scrollView.addSubview(button)
            self.chips.append((entry.id, button))
        }
        self.updateSelection()
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func invalidate() {
        self.disposables.dispose()
    }

    private func updateSelection() {
        let selected = GGVirtualCameraSettings.selected.value
        for chip in self.chips {
            chip.view.layer.borderWidth = chip.id == selected ? 2.0 : 0.0
            chip.view.layer.borderColor = UIColor.systemBlue.cgColor
        }
    }

    @objc private func chipPressed(_ sender: UIButton) {
        guard let chip = self.chips.first(where: { $0.view === sender }) else {
            return
        }
        let previous = GGVirtualCameraSettings.selected.value
        GGVirtualCameraSettings.selected.set(chip.id)
        self.updateSelection()
        if previous != chip.id {
            self.selectionChanged?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.scrollView.frame = self.bounds
        let side = self.bounds.height - 16.0
        var x: CGFloat = 12.0
        for chip in self.chips {
            chip.view.frame = CGRect(x: x, y: 8.0, width: side, height: side)
            chip.view.layer.cornerRadius = 12.0
            x += side + 8.0
        }
        self.scrollView.contentSize = CGSize(width: x + 4.0, height: self.bounds.height)
    }
}
