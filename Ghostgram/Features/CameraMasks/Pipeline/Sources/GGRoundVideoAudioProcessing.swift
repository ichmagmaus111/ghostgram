import Foundation
import AVFoundation
import SwiftSignalKit
import GGCore

/// Audio post-processing of recorded round videos: volume normalisation, recording without sound
/// and the PCM stages other features plug in (`GGCameraHooks.roundVideoAudioStage`, the voice
/// changer). One streaming pass per clip on its own queue: no whole-clip PCM in memory, no WAV on
/// disk, no export session waited on with a semaphore.
///
/// Failing closed: when the processing protects the voice (no sound, the voice changer, the
/// anonymous mode), a clip that could not be processed is refused, never sent as recorded. Only
/// volume normalisation alone falls back to the untouched clip.
public enum GGRoundVideoAudioProcessor {
    /// Peak target, ≈ −1 dBFS.
    static let targetPeak: Float = 0.891
    /// Max boost, +12 dB.
    static let maximumGain: Float = 4.0
    /// Below this the clip is silence: nothing to normalise.
    static let silenceFloor: Float = 0.001

    private static let queue = DispatchQueue(label: "org.ghostgram.roundVideoAudio", qos: .userInitiated)

    /// Whether `process` would change anything for this account right now.
    public static func isNeeded(accountId: GGAccountID?) -> Bool {
        if GGRoundVideoSettings.muteAudio.value || GGRoundVideoSettings.normalizeAudio.value {
            return true
        }
        return GGCameraHooks.hasActiveAudioStage(accountId: accountId)
    }

    /// Processes every clip (in order) and calls `completion` on the main queue with the paths to
    /// send: processed copies, or the originals of clips that needed nothing (or only lost their
    /// volume normalisation). nil: a clip whose voice had to be hidden could not be processed —
    /// nothing may be sent.
    public static func process(paths: [String], accountId: GGAccountID?, completion: @escaping ([String]?) -> Void) -> Disposable {
        let cancelled = Atomic<Bool>(value: false)
        let normalize = GGRoundVideoSettings.normalizeAudio.value
        let mute = GGRoundVideoSettings.muteAudio.value
        GGRoundVideoAudioProcessor.queue.async {
            GGRoundVideoAudioProcessor.removeStaleFiles()
            var results: [String] = []
            func finish(_ value: [String]?) {
                DispatchQueue.main.async {
                    if !cancelled.with({ $0 }) {
                        completion(value)
                    }
                }
            }
            func next(_ index: Int) {
                if cancelled.with({ $0 }) {
                    return
                }
                if index >= paths.count {
                    finish(results)
                    return
                }
                let path = paths[index]
                let processor = GGRoundVideoClipProcessor(path: path, accountId: accountId, normalize: normalize, mute: mute, queue: GGRoundVideoAudioProcessor.queue, cancelled: cancelled)
                processor.run { result in
                    // The processor must outlive its own asynchronous run.
                    withExtendedLifetime(processor) {}
                    switch result {
                    case .unchanged:
                        results.append(path)
                    case let .processed(outputPath):
                        results.append(outputPath)
                    case .failed:
                        finish(nil)
                        return
                    }
                    next(index + 1)
                }
            }
            next(0)
        }
        return ActionDisposable {
            let _ = cancelled.swap(true)
        }
    }

    static var directory: URL {
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gg-round-audio", isDirectory: true)
    }

    /// Only this feature's own directory is swept, and only files older than a day.
    private static func removeStaleFiles() {
        let fileManager = FileManager.default
        let directory = GGRoundVideoAudioProcessor.directory
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let threshold = Date().addingTimeInterval(-24.0 * 60.0 * 60.0)
        for url in urls {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < threshold {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    static func gain(forPeak peak: Float) -> Float {
        if peak <= GGRoundVideoAudioProcessor.silenceFloor {
            return 1.0
        }
        let gain = min(GGRoundVideoAudioProcessor.maximumGain, GGRoundVideoAudioProcessor.targetPeak / peak)
        if gain >= 0.98 && gain <= 1.02 {
            return 1.0
        }
        return gain
    }
}

/// What became of one clip.
private enum GGRoundVideoClipResult {
    /// Nothing to change, or only the normalisation was lost: send the clip as recorded.
    case unchanged
    case processed(String)
    /// The voice had to be hidden and could not be: the clip must not be sent.
    case failed
}

/// One clip: optional measuring pass (peak after the stages), then one writing pass that copies the
/// video samples as they are and re-encodes the processed audio to AAC.
private final class GGRoundVideoClipProcessor {
    private let path: String
    private let accountId: GGAccountID?
    private let normalize: Bool
    private let mute: Bool
    private let queue: DispatchQueue
    private let cancelled: Atomic<Bool>

    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    init(path: String, accountId: GGAccountID?, normalize: Bool, mute: Bool, queue: DispatchQueue, cancelled: Atomic<Bool>) {
        self.path = path
        self.accountId = accountId
        self.normalize = normalize
        self.mute = mute
        self.queue = queue
        self.cancelled = cancelled
    }

    private static func pcmSettings() -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    func run(completion: @escaping (GGRoundVideoClipResult) -> Void) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: self.path))
        let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
        let audioTrack = self.mute ? nil : asset.tracks(withMediaType: .audio).first
        var format: GGRoundVideoAudioFormat?
        if let audioTrack, let description = audioTrack.formatDescriptions.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description as! CMAudioFormatDescription) {
            format = GGRoundVideoAudioFormat(sampleRate: basic.pointee.mSampleRate, channelCount: Int(basic.pointee.mChannelsPerFrame), accountId: self.accountId)
        }
        // Asked once: whether a stage wants this clip decides what a failure means.
        let wantsStages = format.map { !GGCameraHooks.makeAudioStages(format: $0).isEmpty } ?? (!self.mute && hasAudio && GGCameraHooks.hasActiveAudioStage(accountId: self.accountId))
        // The voice must not leave the device unprocessed: no sound, or a stage (voice changer).
        let protectsVoice = hasAudio && (self.mute || wantsStages)
        let failure: GGRoundVideoClipResult = protectsVoice ? .failed : .unchanged
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(failure)
            return
        }
        if !self.mute && (audioTrack == nil || format == nil) {
            // Nothing to process: no audio track (or one whose format can not be read).
            completion(failure)
            return
        }
        var gain: Float = 1.0
        if let audioTrack, let format, self.normalize {
            guard let peak = self.measurePeak(asset: asset, track: audioTrack, format: format) else {
                completion(failure)
                return
            }
            gain = GGRoundVideoAudioProcessor.gain(forPeak: peak)
        }
        let stages = format.map { GGCameraHooks.makeAudioStages(format: $0) } ?? []
        if !self.mute && gain == 1.0 && stages.isEmpty {
            completion(wantsStages ? .failed : .unchanged)
            return
        }
        self.write(asset: asset, videoTrack: videoTrack, audioTrack: audioTrack, format: format, stages: stages, gain: gain, failure: failure, completion: completion)
    }

    /// Streams the audio once through fresh stages and returns the peak; nil on failure.
    private func measurePeak(asset: AVAsset, track: AVAssetTrack, format: GGRoundVideoAudioFormat) -> Float? {
        guard let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: GGRoundVideoClipProcessor.pcmSettings())
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return nil
        }
        reader.add(output)
        guard reader.startReading() else {
            return nil
        }
        let stages = GGCameraHooks.makeAudioStages(format: format)
        var peak: Float = 0.0
        var unreadable = false
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if self.cancelled.with({ $0 }) {
                reader.cancelReading()
                return nil
            }
            let processed = GGRoundVideoClipProcessor.withSamples(sampleBuffer, channelCount: format.channelCount) { samples, frameCount in
                for stage in stages {
                    stage.process(samples, frameCount: frameCount)
                }
                let count = frameCount * format.channelCount
                for i in 0 ..< count {
                    let value = abs(samples[i])
                    if value > peak {
                        peak = value
                    }
                }
            }
            if !processed {
                unreadable = true
            }
        }
        if reader.status == .failed || unreadable || stages.contains(where: { $0.hasFailed }) {
            return nil
        }
        return peak
    }

    private func write(asset: AVAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?, format: GGRoundVideoAudioFormat?, stages: [GGRoundVideoAudioStage], gain: Float, failure: GGRoundVideoClipResult, completion: @escaping (GGRoundVideoClipResult) -> Void) {
        let fileManager = FileManager.default
        let directory = GGRoundVideoAudioProcessor.directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputUrl = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

        guard let reader = try? AVAssetReader(asset: asset), let writer = try? AVAssetWriter(outputURL: outputUrl, fileType: .mp4) else {
            completion(failure)
            return
        }
        self.reader = reader
        self.writer = writer

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            completion(failure)
            return
        }
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoTrack.formatDescriptions.first.map { $0 as! CMFormatDescription })
        videoInput.transform = videoTrack.preferredTransform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            completion(failure)
            return
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack, let format {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: GGRoundVideoClipProcessor.pcmSettings())
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else {
                completion(failure)
                return
            }
            reader.add(output)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 64000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                completion(failure)
                return
            }
            writer.add(input)
            audioOutput = output
            audioInput = input
        }

        guard reader.startReading(), writer.startWriting() else {
            reader.cancelReading()
            completion(failure)
            return
        }
        // The session starts at the first picture: the clip's own timeline, whatever its origin.
        guard let firstVideoSample = videoOutput.copyNextSampleBuffer() else {
            reader.cancelReading()
            writer.cancelWriting()
            completion(failure)
            return
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstVideoSample))
        var pendingVideoSample: CMSampleBuffer? = firstVideoSample

        let group = DispatchGroup()
        let failed = Atomic<Bool>(value: false)

        group.enter()
        let videoDone = Atomic<Bool>(value: false)
        videoInput.requestMediaDataWhenReady(on: self.queue) { [weak self] in
            guard let self else {
                return
            }
            while videoInput.isReadyForMoreMediaData {
                if self.cancelled.with({ $0 }) || failed.with({ $0 }) {
                    if !videoDone.swap(true) {
                        videoInput.markAsFinished()
                        group.leave()
                    }
                    return
                }
                let nextSample: CMSampleBuffer?
                if let pending = pendingVideoSample {
                    pendingVideoSample = nil
                    nextSample = pending
                } else {
                    nextSample = videoOutput.copyNextSampleBuffer()
                }
                if let sampleBuffer = nextSample {
                    if !videoInput.append(sampleBuffer) {
                        let _ = failed.swap(true)
                    }
                } else {
                    if !videoDone.swap(true) {
                        videoInput.markAsFinished()
                        group.leave()
                    }
                    return
                }
            }
        }

        if let audioOutput, let audioInput, let format {
            group.enter()
            let audioDone = Atomic<Bool>(value: false)
            audioInput.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                guard let self else {
                    return
                }
                while audioInput.isReadyForMoreMediaData {
                    if self.cancelled.with({ $0 }) || failed.with({ $0 }) {
                        if !audioDone.swap(true) {
                            audioInput.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                    if let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                        let processed = GGRoundVideoClipProcessor.withSamples(sampleBuffer, channelCount: format.channelCount) { samples, frameCount in
                            for stage in stages {
                                stage.process(samples, frameCount: frameCount)
                            }
                            if gain != 1.0 {
                                let count = frameCount * format.channelCount
                                for i in 0 ..< count {
                                    samples[i] = max(-1.0, min(1.0, samples[i] * gain))
                                }
                            }
                        }
                        // A block the stages never saw would carry the real voice.
                        if !processed || stages.contains(where: { $0.hasFailed }) {
                            let _ = failed.swap(true)
                        } else if !audioInput.append(sampleBuffer) {
                            let _ = failed.swap(true)
                        }
                    } else {
                        if !audioDone.swap(true) {
                            audioInput.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                }
            }
        }

        group.notify(queue: self.queue) { [weak self] in
            guard let self else {
                return
            }
            if self.cancelled.with({ $0 }) || failed.with({ $0 }) || reader.status == .failed {
                reader.cancelReading()
                writer.cancelWriting()
                try? fileManager.removeItem(at: outputUrl)
                completion(failure)
                return
            }
            writer.finishWriting {
                self.queue.async {
                    if writer.status == .completed {
                        completion(.processed(outputUrl.path))
                    } else {
                        try? fileManager.removeItem(at: outputUrl)
                        completion(failure)
                    }
                    self.reader = nil
                    self.writer = nil
                }
            }
        }
    }

    /// Gives interleaved Float32 samples of a PCM buffer, processed in place. A buffer in several
    /// pieces is processed through a copy written back. false: the samples could not be reached and
    /// stay as they were.
    private static func withSamples(_ sampleBuffer: CMSampleBuffer, channelCount: Int, _ body: (UnsafeMutablePointer<Float>, Int) -> Void) -> Bool {
        guard channelCount > 0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return false
        }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = totalLength / MemoryLayout<Float>.size
        let frameCount = sampleCount / channelCount
        if frameCount <= 0 {
            // No samples in it: nothing to change.
            return true
        }
        var lengthAtOffset = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        if CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr, let dataPointer, lengthAtOffset >= totalLength {
            dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                body(samples, frameCount)
            }
            return true
        }
        let byteCount = sampleCount * MemoryLayout<Float>.size
        let copy = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer {
            copy.deallocate()
        }
        guard CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: copy) == kCMBlockBufferNoErr else {
            return false
        }
        body(copy, frameCount)
        return CMBlockBufferReplaceDataBytes(with: copy, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount) == kCMBlockBufferNoErr
    }
}
