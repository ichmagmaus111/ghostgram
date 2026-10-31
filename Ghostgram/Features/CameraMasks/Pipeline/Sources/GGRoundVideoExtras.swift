import Foundation
import AVFoundation
import Photos
import GGCore

/// «Send this video as a round video», chosen in the attachment picker for particular gallery
/// assets. Kept in memory per asset (never a global one-shot flag in UserDefaults): the outgoing
/// transformer consumes exactly the marked assets, other chats and later sends are unaffected.
public final class GGRoundVideoImport {
    public static let shared = GGRoundVideoImport()

    private let lock = NSLock()
    private var marks: [String: Double] = [:]
    /// A mark the send never picked up (picker closed) expires.
    private let lifetime: Double = 10.0 * 60.0

    public func mark(assetIdentifiers: [String]) {
        let now = CFAbsoluteTimeGetCurrent()
        self.lock.lock()
        self.marks = self.marks.filter { now - $0.value < self.lifetime }
        for identifier in assetIdentifiers {
            self.marks[identifier] = now
        }
        self.lock.unlock()
    }

    /// True once per marked asset.
    public func consume(assetIdentifier: String) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let timestamp = self.marks.removeValue(forKey: assetIdentifier) else {
            return false
        }
        return now - timestamp < self.lifetime
    }

    public var hasMarks: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return !self.marks.isEmpty
    }
}

/// «Save a copy to the gallery»: the sent clips (after audio processing), trimmed, as one video.
/// Runs in the background and never delays sending; a refusal of photo access is silent.
public enum GGRoundVideoGallerySaver {
    private static let queue = DispatchQueue(label: "org.ghostgram.roundVideoGallery", qos: .utility)

    public static func saveIfEnabled(paths: [String], trimRange: ClosedRange<Double>?) {
        guard GGRoundVideoSettings.saveCopyToGallery.value, !paths.isEmpty else {
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            GGRoundVideoGallerySaver.save(paths: paths, trimRange: trimRange)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    GGRoundVideoGallerySaver.save(paths: paths, trimRange: trimRange)
                }
            }
        default:
            break
        }
    }

    private static func save(paths: [String], trimRange: ClosedRange<Double>?) {
        GGRoundVideoGallerySaver.queue.async {
            let fileManager = FileManager.default
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gg-round-gallery", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let outputUrl = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

            if paths.count == 1 && trimRange == nil {
                // One untrimmed take: a copy of the file, the sending path may still read the original.
                do {
                    try fileManager.copyItem(at: URL(fileURLWithPath: paths[0]), to: outputUrl)
                } catch {
                    return
                }
                GGRoundVideoGallerySaver.addToLibrary(outputUrl)
                return
            }

            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return
            }
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var cursor = CMTime.zero
            for path in paths {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                let range = CMTimeRange(start: .zero, duration: asset.duration)
                if let sourceVideo = asset.tracks(withMediaType: .video).first {
                    try? videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
                    videoTrack.preferredTransform = sourceVideo.preferredTransform
                }
                if let audioTrack, let sourceAudio = asset.tracks(withMediaType: .audio).first {
                    try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                }
                cursor = cursor + asset.duration
            }
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                return
            }
            export.outputURL = outputUrl
            export.outputFileType = .mp4
            if let trimRange {
                export.timeRange = CMTimeRange(start: CMTime(seconds: trimRange.lowerBound, preferredTimescale: 600), end: CMTime(seconds: trimRange.upperBound, preferredTimescale: 600))
            }
            export.exportAsynchronously {
                if export.status == .completed {
                    GGRoundVideoGallerySaver.addToLibrary(outputUrl)
                } else {
                    try? FileManager.default.removeItem(at: outputUrl)
                }
            }
        }
    }

    private static func addToLibrary(_ url: URL) {
        PHPhotoLibrary.shared().performChanges({
            let _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }, completionHandler: { _, _ in
            try? FileManager.default.removeItem(at: url)
        })
    }
}
