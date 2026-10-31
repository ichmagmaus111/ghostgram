import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import Metal
import SwiftSignalKit
import TelegramVoip
import LibYuvBinding
import GGCallAudio
import GGCore

/// Writes one call recording file in a single pass: AAC audio (m4a) or H.264 720p video with AAC (mp4).
/// Nothing is re-encoded afterwards. All work runs on the session's serial queue, never on the audio
/// thread (which only fills the ring buffers of `GGCallAudioEffects`) and never on the main thread.
final class GGCallRecorder {
    enum Kind {
        case audio
        case video
    }

    static let videoSize = CGSize(width: 720.0, height: 1280.0)
    static let audioBitRate = 64000
    static let videoBitRate = 1_500_000
    static let videoFrameRate: Double = 24.0

    let kind: Kind
    let url: URL
    private let queue: Queue
    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let videoInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let startHostTime: Double

    private var audioTime: Double = 0.0
    private var audioFormat: CMAudioFormatDescription?
    private var audioFormatRate: Int32 = 0
    private var pendingAudio: [CMSampleBuffer] = []
    private var lastVideoTime: Double = -1.0
    private var isFinishing = false

    /// `queue` must be serial; every call below happens on it.
    init?(url: URL, kind: Kind, queue: Queue) {
        self.kind = kind
        self.url = url
        self.queue = queue
        let fileType: AVFileType = kind == .audio ? .m4a : .mp4
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: fileType) else {
            return nil
        }
        writer.shouldOptimizeForNetworkUse = kind == .video

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: GGCallRecorder.audioBitRate
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            return nil
        }
        writer.add(audioInput)

        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if kind == .video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(GGCallRecorder.videoSize.width),
                AVVideoHeightKey: Int(GGCallRecorder.videoSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: GGCallRecorder.videoBitRate,
                    AVVideoExpectedSourceFrameRateKey: Int(GGCallRecorder.videoFrameRate),
                    AVVideoMaxKeyFrameIntervalKey: Int(GGCallRecorder.videoFrameRate * 2.0),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
                ]
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                return nil
            }
            writer.add(input)
            // The adaptor's pool is the only source of output frames: no buffer is allocated per frame.
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(GGCallRecorder.videoSize.width),
                kCVPixelBufferHeightKey as String: Int(GGCallRecorder.videoSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ])
            videoInput = input
        }
        self.writer = writer
        self.audioInput = audioInput
        self.videoInput = videoInput
        self.adaptor = adaptor

        guard writer.startWriting() else {
            return nil
        }
        writer.startSession(atSourceTime: .zero)
        self.startHostTime = CACurrentMediaTime()
    }

    /// Seconds written so far (audio timeline).
    var duration: Double {
        return self.audioTime
    }

    var pixelBufferPool: CVPixelBufferPool? {
        return self.adaptor?.pixelBufferPool
    }

    // MARK: Audio

    func appendAudio(_ chunk: GGCallAudioRecordingChunk) {
        if self.isFinishing || self.writer.status != .writing {
            return
        }
        let sampleCount = chunk.samples.count / MemoryLayout<Int16>.size
        if sampleCount == 0 || chunk.sampleRate <= 0 {
            return
        }
        if self.audioFormat == nil || self.audioFormatRate != chunk.sampleRate {
            var description = AudioStreamBasicDescription(mSampleRate: Float64(chunk.sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            self.audioFormat = format
            self.audioFormatRate = chunk.sampleRate
        }
        guard let format = self.audioFormat else {
            return
        }
        var blockBuffer: CMBlockBuffer?
        let length = sampleCount * MemoryLayout<Int16>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr, let block = blockBuffer else {
            return
        }
        let copied = chunk.samples.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else {
                return false
            }
            return CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == kCMBlockBufferNoErr
        }
        if !copied {
            return
        }
        var sampleBuffer: CMSampleBuffer?
        let presentationTime = CMTime(seconds: self.audioTime, preferredTimescale: CMTimeScale(chunk.sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: sampleCount, presentationTimeStamp: presentationTime, packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr, let buffer = sampleBuffer else {
            return
        }
        self.audioTime += Double(sampleCount) / Double(chunk.sampleRate)
        self.pendingAudio.append(buffer)
        // Bounded: a stalled encoder drops audio older than ~10 s rather than growing without limit.
        if self.pendingAudio.count > 40 {
            self.pendingAudio.removeFirst(self.pendingAudio.count - 40)
        }
        while let first = self.pendingAudio.first, self.audioInput.isReadyForMoreMediaData {
            if !self.audioInput.append(first) {
                break
            }
            self.pendingAudio.removeFirst()
        }
    }

    // MARK: Video

    /// Whether a frame for `hostTime` would be written (24 fps cap). Checked before compositing so
    /// that skipped frames cost nothing.
    func wantsVideoFrame(at hostTime: Double) -> Bool {
        guard self.kind == .video, !self.isFinishing, self.writer.status == .writing else {
            return false
        }
        let time = hostTime - self.startHostTime
        return self.lastVideoTime < 0.0 || time - self.lastVideoTime >= 1.0 / GGCallRecorder.videoFrameRate
    }

    /// Seconds since the last written frame (the session repeats a frame when video stalls).
    func secondsSinceLastVideoFrame(at hostTime: Double) -> Double {
        if self.lastVideoTime < 0.0 {
            return .greatestFiniteMagnitude
        }
        return hostTime - self.startHostTime - self.lastVideoTime
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: Double) {
        guard let adaptor = self.adaptor, let videoInput = self.videoInput, !self.isFinishing, self.writer.status == .writing else {
            return
        }
        let time = max(0.0, hostTime - self.startHostTime)
        if time <= self.lastVideoTime {
            return
        }
        if !videoInput.isReadyForMoreMediaData {
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) {
            self.lastVideoTime = time
        }
    }

    // MARK: Finish

    func finish(completion: @escaping (Bool) -> Void) {
        if self.isFinishing {
            return
        }
        self.isFinishing = true
        while let first = self.pendingAudio.first, self.audioInput.isReadyForMoreMediaData {
            if !self.audioInput.append(first) {
                break
            }
            self.pendingAudio.removeFirst()
        }
        self.pendingAudio.removeAll()
        guard self.writer.status == .writing else {
            completion(false)
            return
        }
        self.audioInput.markAsFinished()
        self.videoInput?.markAsFinished()
        let writer = self.writer
        let queue = self.queue
        writer.finishWriting {
            queue.async {
                completion(writer.status == .completed)
            }
        }
    }

    func cancel() {
        if self.isFinishing {
            return
        }
        self.isFinishing = true
        self.pendingAudio.removeAll()
        if self.writer.status == .writing {
            self.writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: self.url)
    }
}

/// Draws the call's video into the recorder's pooled frames on the GPU: the remote video fills the
/// frame (aspect fit on black), the own camera is a small inset. Created once per video recording;
/// a frame is composed only when a new remote frame arrives (or, without remote video, a new own one).
final class GGCallVideoCompositor {
    private let ciContext: CIContext
    private let canvas = CGRect(origin: CGPoint(), size: GGCallRecorder.videoSize)
    private var conversionPool: CVPixelBufferPool?
    private var conversionPoolSize: (Int, Int) = (0, 0)
    private let black: CIImage

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        self.black = CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0)).cropped(to: CGRect(origin: CGPoint(), size: GGCallRecorder.videoSize))
    }

    /// The frame as a CIImage in display orientation, or nil for an unsupported buffer.
    func image(_ frame: OngoingGroupCallContext.VideoFrameData) -> CIImage? {
        let pixelBuffer: CVPixelBuffer
        switch frame.buffer {
        case let .native(buffer), let .argb(buffer), let .bgra(buffer):
            pixelBuffer = buffer.pixelBuffer
        case let .nv12(buffer):
            guard let converted = self.convertedBuffer(width: buffer.width, height: buffer.height, fill: { destination in
                return GGCallVideoCompositor.copyNV12(buffer, into: destination)
            }) else {
                return nil
            }
            pixelBuffer = converted
        case let .i420(buffer):
            guard let converted = self.convertedBuffer(width: buffer.width, height: buffer.height, fill: { destination in
                return GGCallVideoCompositor.copyI420(buffer, into: destination)
            }) else {
                return nil
            }
            pixelBuffer = converted
        }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        switch frame.orientation {
        case .rotation0:
            break
        case .rotation90:
            image = image.oriented(.right)
        case .rotation180:
            image = image.oriented(.down)
        case .rotation270:
            image = image.oriented(.left)
        }
        if frame.mirrorHorizontally {
            image = image.oriented(.upMirrored)
        }
        return image
    }

    /// Composes into `output` (a buffer from the recorder's pool).
    func render(main: CIImage?, inset: CIImage?, into output: CVPixelBuffer) {
        var composed = self.black
        if let main = main {
            composed = GGCallVideoCompositor.fit(main, in: self.canvas).composited(over: composed)
        }
        if let inset = inset {
            let insetRect = CGRect(x: self.canvas.width - 16.0 - 180.0, y: self.canvas.height - 16.0 - 320.0, width: 180.0, height: 320.0)
            composed = GGCallVideoCompositor.fit(inset, in: insetRect).composited(over: composed)
        }
        self.ciContext.render(composed, to: output, bounds: self.canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private static func fit(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        if extent.width <= 0.0 || extent.height <= 0.0 {
            return image
        }
        let scale = min(rect.width / extent.width, rect.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let x = rect.minX + (rect.width - scaledWidth) / 2.0
        let y = rect.minY + (rect.height - scaledHeight) / 2.0
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    /// Software-decoded frames (VP8 / VP9) are copied into a pooled NV12 buffer of their size.
    private func convertedBuffer(width: Int, height: Int, fill: (CVPixelBuffer) -> Bool) -> CVPixelBuffer? {
        if width <= 0 || height <= 0 {
            return nil
        }
        if self.conversionPool == nil || self.conversionPoolSize != (width, height) {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ] as CFDictionary, &pool)
            self.conversionPool = pool
            self.conversionPoolSize = (width, height)
        }
        guard let pool = self.conversionPool else {
            return nil
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let pixelBuffer = buffer, fill(pixelBuffer) else {
            return nil
        }
        return pixelBuffer
    }

    private static func copyNV12(_ source: OngoingGroupCallContext.VideoFrameData.NV12Buffer, into destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            return false
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let dstY = CVPixelBufferGetBaseAddressOfPlane(destination, 0), let dstUV = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            return false
        }
        let dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        let dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        let width = source.width
        let height = source.height
        source.y.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return
            }
            for row in 0 ..< height {
                memcpy(dstY.advanced(by: row * dstStrideY), base.advanced(by: row * source.strideY), min(width, dstStrideY))
            }
        }
        source.uv.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return
            }
            for row in 0 ..< (height + 1) / 2 {
                memcpy(dstUV.advanced(by: row * dstStrideUV), base.advanced(by: row * source.strideUV), min(width, dstStrideUV))
            }
        }
        return true
    }

    private static func copyI420(_ source: OngoingGroupCallContext.VideoFrameData.I420Buffer, into destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            return false
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let dstY = CVPixelBufferGetBaseAddressOfPlane(destination, 0), let dstUV = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            return false
        }
        let dstStrideY = Int32(CVPixelBufferGetBytesPerRowOfPlane(destination, 0))
        let dstStrideUV = Int32(CVPixelBufferGetBytesPerRowOfPlane(destination, 1))
        return source.y.withUnsafeBytes { yBytes -> Bool in
            return source.u.withUnsafeBytes { uBytes -> Bool in
                return source.v.withUnsafeBytes { vBytes -> Bool in
                    guard let y = yBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), let u = uBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), let v = vBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return false
                    }
                    return libyuv_I420ToNV12(y, Int32(source.strideY), u, Int32(source.strideU), v, Int32(source.strideV), dstY.assumingMemoryBound(to: UInt8.self), dstStrideY, dstUV.assumingMemoryBound(to: UInt8.self), dstStrideUV, Int32(source.width), Int32(source.height))
                }
            }
        }
    }
}
