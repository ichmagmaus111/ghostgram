import Foundation
import AVFoundation
import SwiftSignalKit
import GGCore

/// The soundboard's sounds: files in the container, metadata (`GGCallSoundItem`) in the settings
/// registry — one source of truth each. Decoded clips (mono Int16, 48 kHz, at most 60 s) are cached
/// in memory with a size limit, least recently used out first.
final class GGCallSoundLibrary {
    static let shared = GGCallSoundLibrary()

    static let clipSampleRate: Int32 = 48000
    static let maximumClipDuration: Double = 60.0
    /// ≈ 4 clips of a minute; a clip is 5.8 MB at most.
    static let cacheLimitBytes = 24 * 1024 * 1024

    private let queue = Queue(name: "org.ghostgram.soundboard")
    private var cache: [(id: String, data: Data)] = []
    private var cacheBytes = 0

    private init() {
    }

    /// `<appGroup>/ghostgram/calls/sounds`, created on demand.
    static var directory: String? {
        guard let appGroupPath = GGCore.environment?.appGroupPath else {
            return nil
        }
        return appGroupPath + "/ghostgram/calls/sounds"
    }

    /// Where the old Ghostgram kept its sounds; migrated items still point there.
    static var legacyDirectory: String? {
        guard let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
            return nil
        }
        return documents + "/ggcall/soundboard"
    }

    static func url(for item: GGCallSoundItem) -> URL? {
        let directory = item.isLegacy ? GGCallSoundLibrary.legacyDirectory : GGCallSoundLibrary.directory
        guard let directory = directory else {
            return nil
        }
        return URL(fileURLWithPath: directory).appendingPathComponent(item.fileName)
    }

    /// Items whose files exist (an item whose file is gone is not offered).
    var items: [GGCallSoundItem] {
        return GGCallsMediaSettings.soundboardItems.value.filter { item in
            guard let url = GGCallSoundLibrary.url(for: item) else {
                return false
            }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    // MARK: Import / delete

    /// Copies an audio file (or the audio track of a video) into the library. Off the main thread;
    /// `completion` on the main thread with the new item, or nil if the file has no usable audio.
    func importFile(at sourceURL: URL, suggestedTitle: String?, completion: @escaping (GGCallSoundItem?) -> Void) {
        self.queue.async {
            guard let directory = GGCallSoundLibrary.directory else {
                Queue.mainQueue().async {
                    completion(nil)
                }
                return
            }
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let title = (suggestedTitle?.isEmpty == false ? suggestedTitle : nil) ?? sourceURL.deletingPathExtension().lastPathComponent
            let asset = AVURLAsset(url: sourceURL)
            let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "3g2", "mkv", "webm", "avi"]
            if videoExtensions.contains(sourceURL.pathExtension.lowercased()) {
                // Only the audio track is kept.
                let destination = URL(fileURLWithPath: directory).appendingPathComponent(id + ".m4a")
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    Queue.mainQueue().async {
                        completion(nil)
                    }
                    return
                }
                export.outputURL = destination
                export.outputFileType = .m4a
                export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: GGCallSoundLibrary.maximumClipDuration, preferredTimescale: 600))
                export.exportAsynchronously {
                    let success = export.status == .completed
                    Queue.mainQueue().async {
                        if success {
                            completion(GGCallSoundLibrary.add(GGCallSoundItem(id: id, title: title, fileName: id + ".m4a", isLegacy: false, createdAt: Date().timeIntervalSince1970)))
                        } else {
                            try? FileManager.default.removeItem(at: destination)
                            completion(nil)
                        }
                    }
                }
                return
            }
            let pathExtension = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension.lowercased()
            let fileName = id + "." + pathExtension
            let destination = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch {
                Queue.mainQueue().async {
                    completion(nil)
                }
                return
            }
            // Make sure it is audio we can decode before it shows up in the list.
            guard GGCallSoundLibrary.decode(url: destination) != nil else {
                try? FileManager.default.removeItem(at: destination)
                Queue.mainQueue().async {
                    completion(nil)
                }
                return
            }
            Queue.mainQueue().async {
                completion(GGCallSoundLibrary.add(GGCallSoundItem(id: id, title: title, fileName: fileName, isLegacy: false, createdAt: Date().timeIntervalSince1970)))
            }
        }
    }

    private static func add(_ item: GGCallSoundItem) -> GGCallSoundItem {
        var items = GGCallsMediaSettings.soundboardItems.value
        items.append(item)
        GGCallsMediaSettings.soundboardItems.set(items)
        return item
    }

    /// Main thread.
    func delete(_ item: GGCallSoundItem) {
        var items = GGCallsMediaSettings.soundboardItems.value
        items.removeAll(where: { $0.id == item.id })
        GGCallsMediaSettings.soundboardItems.set(items)
        let url = GGCallSoundLibrary.url(for: item)
        self.queue.async {
            if let index = self.cache.firstIndex(where: { $0.id == item.id }) {
                self.cacheBytes -= self.cache[index].data.count
                self.cache.remove(at: index)
            }
            if let url = url {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Main thread.
    func rename(_ item: GGCallSoundItem, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }
        var items = GGCallsMediaSettings.soundboardItems.value
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].title = trimmed
            GGCallsMediaSettings.soundboardItems.set(items)
        }
    }

    // MARK: Decoding

    /// The clip's samples (mono Int16 at 48 kHz), from the cache or decoded off the main thread.
    func clip(for item: GGCallSoundItem) -> Signal<Data?, NoError> {
        return Signal { subscriber in
            self.queue.async {
                if let index = self.cache.firstIndex(where: { $0.id == item.id }) {
                    let entry = self.cache.remove(at: index)
                    self.cache.insert(entry, at: 0)
                    subscriber.putNext(entry.data)
                    subscriber.putCompletion()
                    return
                }
                guard let url = GGCallSoundLibrary.url(for: item), let data = GGCallSoundLibrary.decode(url: url) else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                self.cache.insert((item.id, data), at: 0)
                self.cacheBytes += data.count
                while self.cacheBytes > GGCallSoundLibrary.cacheLimitBytes, self.cache.count > 1 {
                    let removed = self.cache.removeLast()
                    self.cacheBytes -= removed.data.count
                }
                subscriber.putNext(data)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    private static func decode(url: URL) -> Data? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(GGCallSoundLibrary.clipSampleRate), channels: 1, interleaved: true), let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            return nil
        }
        let maximumFrames = AVAudioFrameCount(Double(GGCallSoundLibrary.clipSampleRate) * GGCallSoundLibrary.maximumClipDuration)
        let chunkFrames: AVAudioFrameCount = 8192
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            return nil
        }
        var result = Data()
        var isDone = false
        while !isDone && AVAudioFrameCount(result.count / 2) < maximumFrames {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkFrames) else {
                return nil
            }
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: { _, outStatus in
                do {
                    try file.read(into: inputBuffer, frameCount: chunkFrames)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            })
            if status == .error || error != nil {
                return result.isEmpty ? nil : result
            }
            if outputBuffer.frameLength > 0, let channel = outputBuffer.int16ChannelData?[0] {
                result.append(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            }
            if status == .endOfStream {
                isDone = true
            }
        }
        let limitBytes = Int(maximumFrames) * 2
        if result.count > limitBytes {
            result = result.prefix(limitBytes)
        }
        return result.isEmpty ? nil : result
    }
}
