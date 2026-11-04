import Foundation
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import SwiftSignalKit
import GGCore
import GGAppearanceSettings

/// Animated backgrounds of the chat and of the own profile header (gif_wallpapers).
///
/// The old feature decoded every GIF frame at once into full-screen `UIImage`s on the calling thread
/// and played them with `animationImages` (memory ≈ frames × screen, jetsam on long GIFs), stored an
/// absolute file path in the settings and worked around AVPlayer grabbing the audio session.
/// Here a picked GIF is converted ONCE, at import, on a background queue, frame by frame
/// (`CGImageSource` → `AVAssetWriter`, never more than one decoded frame in memory) into a looping
/// H.264 video without an audio track; a picked video is re-exported without its audio. The result
/// lives at a fixed place in the app container; the settings keep only a version number. It is played
/// by `GGLoopingVideoView`'s own reader: `AVPlayer` took the audio session even for such a file.
enum GGAnimatedBackgroundKind {
    case chat
    case profile

    var fileName: String {
        switch self {
        case .chat:
            return "chat-background.mp4"
        case .profile:
            return "profile-background.mp4"
        }
    }

    var versionSetting: GGSetting<Int> {
        switch self {
        case .chat:
            return GGAppearanceSettings.chatBackgroundVersion
        case .profile:
            return GGAppearanceSettings.profileBackgroundVersion
        }
    }

    var enabledSetting: GGSetting<Bool> {
        switch self {
        case .chat:
            return GGAppearanceSettings.chatBackground
        case .profile:
            return GGAppearanceSettings.profileBackground
        }
    }

    var opacitySetting: GGSetting<Double> {
        switch self {
        case .chat:
            return GGAppearanceSettings.chatBackgroundOpacity
        case .profile:
            return GGAppearanceSettings.profileBackgroundOpacity
        }
    }
}

enum GGAnimatedBackgrounds {
    private static let queue = Queue(name: "org.ghostgram.appearance.backgrounds", qos: .utility)

    static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("ghostgram/appearance", isDirectory: true)
    }

    /// The converted file, if there is one.
    static func fileURL(_ kind: GGAnimatedBackgroundKind) -> URL? {
        guard kind.versionSetting.value != 0, let directory = GGAnimatedBackgrounds.directory else {
            return nil
        }
        return directory.appendingPathComponent(kind.fileName)
    }

    /// Converts `sourceURL` (a GIF or a video) into the background of `kind`. The completion runs on
    /// the main queue with `true` on success; the settings are written there.
    static func importFile(at sourceURL: URL, kind: GGAnimatedBackgroundKind, completion: @escaping (Bool) -> Void) {
        GGAnimatedBackgrounds.queue.async {
            guard let directory = GGAnimatedBackgrounds.directory else {
                Queue.mainQueue().async {
                    completion(false)
                }
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = directory.appendingPathComponent("import-\(UInt32.random(in: 0 ... UInt32.max)).mp4")
            let finish: (Bool) -> Void = { success in
                var success = success
                if success {
                    let targetURL = directory.appendingPathComponent(kind.fileName)
                    try? FileManager.default.removeItem(at: targetURL)
                    do {
                        try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
                    } catch {
                        success = false
                    }
                } else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
                Queue.mainQueue().async {
                    if success {
                        kind.versionSetting.set(kind.versionSetting.value &+ 1)
                        kind.enabledSetting.set(true)
                    }
                    completion(success)
                }
            }
            let type = UTType(filenameExtension: sourceURL.pathExtension.lowercased())
            if let type, type.conforms(to: .gif) {
                finish(GGAnimatedBackgrounds.convertGif(sourceURL, to: temporaryURL))
            } else {
                GGAnimatedBackgrounds.exportVideo(sourceURL, to: temporaryURL, completion: finish)
            }
        }
    }

    /// Deletes the background of `kind` and switches it off. Main thread.
    static func remove(_ kind: GGAnimatedBackgroundKind) {
        kind.enabledSetting.set(false)
        kind.versionSetting.set(0)
        GGAnimatedBackgrounds.queue.async {
            if let directory = GGAnimatedBackgrounds.directory {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(kind.fileName))
            }
        }
    }

    // MARK: GIF → video, one frame at a time

    private static let maximumSide: CGFloat = 720.0
    private static let maximumFrames = 900

    private static func convertGif(_ sourceURL: URL, to outputURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return false
        }
        let frameCount = min(CGImageSourceGetCount(source), GGAnimatedBackgrounds.maximumFrames)
        guard frameCount > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0.0
        let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0.0
        if pixelWidth < 1.0 || pixelHeight < 1.0 {
            return false
        }
        let scale = min(1.0, GGAnimatedBackgrounds.maximumSide / CGFloat(max(pixelWidth, pixelHeight)))
        // H.264 wants even dimensions.
        let width = max(2, Int(CGFloat(pixelWidth) * scale) & ~1)
        let height = max(2, Int(CGFloat(pixelHeight) * scale) & ~1)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return false
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else {
            return false
        }
        writer.add(input)
        guard writer.startWriting() else {
            return false
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        var time = CMTime.zero
        var index = 0
        let done = DispatchSemaphore(value: 0)
        var failed = false
        let inputQueue = DispatchQueue(label: "org.ghostgram.appearance.gifFrames")
        input.requestMediaDataWhenReady(on: inputQueue) {
            while input.isReadyForMoreMediaData {
                if index >= frameCount {
                    input.markAsFinished()
                    done.signal()
                    return
                }
                let frameIndex = index
                index += 1
                let delay = GGAnimatedBackgrounds.frameDelay(source: source, index: frameIndex)
                guard let image = CGImageSourceCreateImageAtIndex(source, frameIndex, nil), let pool = adaptor.pixelBufferPool, let buffer = GGAnimatedBackgrounds.pixelBuffer(image, pool: pool, width: width, height: height) else {
                    continue
                }
                if !adaptor.append(buffer, withPresentationTime: time) {
                    failed = true
                    input.markAsFinished()
                    done.signal()
                    return
                }
                time = CMTimeAdd(time, CMTime(seconds: delay, preferredTimescale: timescale))
            }
        }
        done.wait()
        if failed {
            writer.cancelWriting()
            return false
        }
        writer.endSession(atSourceTime: time)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finished.signal()
        }
        finished.wait()
        return writer.status == .completed
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any], let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        var delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? 0.0
        if delay <= 0.0 {
            delay = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
        }
        // Browsers treat delays under 20 ms as 100 ms; so does this.
        return delay < 0.02 ? 0.1 : delay
    }

    private static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var bufferValue: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferValue) == kCVReturnSuccess, let buffer = bufferValue else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0.0, y: 0.0, width: CGFloat(width), height: CGFloat(height)))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0.0, y: 0.0, width: CGFloat(width), height: CGFloat(height)))
        return buffer
    }

    // MARK: Video → video without audio

    private static func exportVideo(_ sourceURL: URL, to outputURL: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(false)
            return
        }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(false)
            return
        }
        do {
            try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
        } catch {
            completion(false)
            return
        }
        compositionTrack.preferredTransform = videoTrack.preferredTransform
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720) else {
            completion(false)
            return
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            completion(session.status == .completed)
        }
    }
}
