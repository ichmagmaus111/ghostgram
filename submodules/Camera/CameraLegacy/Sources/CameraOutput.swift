import Foundation
import AVFoundation
import UIKit
import Display
import SwiftSignalKit
import CoreImage
import Vision
import VideoToolbox
import TelegramCore
import Camera
// GHOST: Ghostgram round video settings and frame processor (masks)
import GGCameraPipeline

final class CameraOutput: NSObject {
    private struct RoundVideoFormatDescriptionCacheEntry {
        let sourceFormatDescription: CMFormatDescription
        let outputFormatDescription: CMFormatDescription
    }

    let exclusive: Bool
    let ciContext: CIContext
    let colorSpace: CGColorSpace
    let isVideoMessage: Bool
    
    var hasAudio: Bool = false
    
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let metadataOutput = AVCaptureMetadataOutput()

    private var photoConnection: AVCaptureConnection?
    private var videoConnection: AVCaptureConnection?
    private var previewConnection: AVCaptureConnection?

    private var roundVideoFilter: CameraRoundLegacyVideoFilter?
    private let semaphore = DispatchSemaphore(value: 1)
    private var roundVideoFormatDescriptionCache: [RoundVideoFormatDescriptionCacheEntry] = []
    
    private let videoQueue = DispatchQueue(label: "", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "")
    
    private let metadataQueue = DispatchQueue(label: "")
    
    private var photoCaptureRequests = Atomic<[Int64: PhotoCaptureContext]>(value: [:])
    private var videoRecorder: VideoRecorder?
    
    private var captureOrientation: AVCaptureVideoOrientation = .portrait
        
    var processSampleBuffer: ((CMSampleBuffer, CVImageBuffer, AVCaptureConnection) -> Void)?

    // GHOST: round video settings of this session, the frame processor (masks) and the watermark
    // of the current recording; defaults keep upstream's 400×400 H.264 1 Mbit/s
    var ggRecording: GGRoundVideoRecordingConfig = .standard
    var ggFrameProcessor: GGCameraFrameProcessor?
    private var ggWatermark: GGRoundVideoWatermark?
    private var ggFormatDescription: CMVideoFormatDescription?
    private var ggSide: Int {
        return self.ggRecording.outputSide(defaultSide: Int(videoMessageDimensions.width))
    }
    var processAudioBuffer: ((CMSampleBuffer) -> Void)?
    var processCodes: (([CameraCode]) -> Void)?
        
    init(exclusive: Bool, ciContext: CIContext, colorSpace: CGColorSpace, use32BGRA: Bool = false) {
        self.exclusive = exclusive
        self.ciContext = ciContext
        self.colorSpace = colorSpace
        self.isVideoMessage = use32BGRA
        
        super.init()
        
        if #available(iOS 13.0, *) {
            self.photoOutput.maxPhotoQualityPrioritization = .balanced
        }
        
        self.videoOutput.alwaysDiscardsLateVideoFrames = false
        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: use32BGRA ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as [String : Any]
    }
    
    deinit {
        self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
        self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
    }
    
    func configure(for session: CameraSession, device: CameraDevice, input: CameraInput, previewView: LegacyCameraSimplePreviewView?, audio: Bool, photo: Bool, metadata: Bool) {
        if session.session.canAddOutput(self.videoOutput) {
            if session.hasMultiCam {
                session.session.addOutputWithNoConnections(self.videoOutput)
            } else {
                session.session.addOutput(self.videoOutput)
            }
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
        } else {
            Logger.shared.log("Camera", "Can't add video output")
        }
        if audio {
            self.hasAudio = true
            if session.session.canAddOutput(self.audioOutput) {
                session.session.addOutput(self.audioOutput)
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
            } else {
                Logger.shared.log("Camera", "Can't add audio output")
            }
        }
        if photo, session.session.canAddOutput(self.photoOutput) {
            if session.hasMultiCam {
                session.session.addOutputWithNoConnections(self.photoOutput)
            } else {
                session.session.addOutput(self.photoOutput)
            }
        } else {
            Logger.shared.log("Camera", "Can't add photo output")
        }
        if metadata, session.session.canAddOutput(self.metadataOutput) {
            session.session.addOutput(self.metadataOutput)
            
            self.metadataOutput.setMetadataObjectsDelegate(self, queue: self.metadataQueue)
            if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                self.metadataOutput.metadataObjectTypes = [.qr]
            }
        }
        
        if #available(iOS 13.0, *), session.hasMultiCam {
            if let device = device.videoDevice, let ports = input.videoInput?.ports(for: AVMediaType.video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position), let firstPort = ports.first {
                if let previewView {
                    let previewConnection = AVCaptureConnection(inputPort: firstPort, videoPreviewLayer: previewView.videoPreviewLayer)
                    if session.session.canAddConnection(previewConnection) {
                        session.session.addConnection(previewConnection)
                        self.previewConnection = previewConnection
                    } else {
                        Logger.shared.log("Camera", "Can't add preview connection")
                    }
                }
                
                let videoConnection = AVCaptureConnection(inputPorts: ports, output: self.videoOutput)
                if session.session.canAddConnection(videoConnection) {
                    session.session.addConnection(videoConnection)
                    self.videoConnection = videoConnection
                } else {
                    Logger.shared.log("Camera", "Can't add video connection")
                }

                if photo {
                    let photoConnection = AVCaptureConnection(inputPorts: ports, output: self.photoOutput)
                    if session.session.canAddConnection(photoConnection) {
                        session.session.addConnection(photoConnection)
                        self.photoConnection = photoConnection
                    }
                }
            } else {
                Logger.shared.log("Camera", "Can't get video port")
            }
        }
    }
        
    func invalidate(for session: CameraSession, switchAudio: Bool = true) {
        if #available(iOS 13.0, *) {
            if let previewConnection = self.previewConnection {
                if session.session.connections.contains(where: { $0 === previewConnection }) {
                    session.session.removeConnection(previewConnection)
                }
                self.previewConnection = nil
            }
            if let videoConnection = self.videoConnection {
                if session.session.connections.contains(where: { $0 === videoConnection }) {
                    session.session.removeConnection(videoConnection)
                }
                self.videoConnection = nil
            }
            if let photoConnection = self.photoConnection {
                if session.session.connections.contains(where: { $0 === photoConnection }) {
                    session.session.removeConnection(photoConnection)
                }
                self.photoConnection = nil
            }
        }
        if session.session.outputs.contains(where: { $0 === self.videoOutput }) {
            session.session.removeOutput(self.videoOutput)
        }
        if switchAudio, session.session.outputs.contains(where: { $0 === self.audioOutput }) {
            session.session.removeOutput(self.audioOutput)
        }
        if session.session.outputs.contains(where: { $0 === self.photoOutput }) {
            session.session.removeOutput(self.photoOutput)
        }
        if session.session.outputs.contains(where: { $0 === self.metadataOutput }) {
            session.session.removeOutput(self.metadataOutput)
        }
    }
    
    func configureVideoStabilization() {
        if let videoDataOutputConnection = self.videoOutput.connection(with: .video) {
            if videoDataOutputConnection.isVideoStabilizationSupported {
                videoDataOutputConnection.preferredVideoStabilizationMode = self.ggStabilizationMode(connection: videoDataOutputConnection) // GHOST: stabilization setting
            }
        }
    }
    
    var isFlashActive: Signal<Bool, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            subscriber.putNext(self.photoOutput.isFlashScene)
            let observer = self.photoOutput.observe(\.isFlashScene, options: [.new], changeHandler: { output, _ in
                subscriber.putNext(output.isFlashScene)
            })
            return ActionDisposable {
                observer.invalidate()
            }
        }
        |> distinctUntilChanged
    }
    
    func takePhoto(orientation: AVCaptureVideoOrientation, flashMode: AVCaptureDevice.FlashMode) -> Signal<PhotoCaptureResult, NoError> {
        var mirror = false
        if let connection = self.photoOutput.connection(with: .video) {
            connection.videoOrientation = orientation
            
            if #available(iOS 13.0, *) {
                mirror = connection.inputPorts.first?.sourceDevicePosition == .front
            }
        }
        
        let settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        settings.flashMode = mirror ? .off : flashMode
        if let previewPhotoPixelFormatType = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPhotoPixelFormatType]
        }
        if #available(iOS 13.0, *) {
            if self.photoOutput.maxPhotoQualityPrioritization != .speed  {
                settings.photoQualityPrioritization = .balanced
            } else {
                settings.photoQualityPrioritization = .speed
            }
        }
        
#if targetEnvironment(simulator)
        let image = generateImage(CGSize(width: 1080, height: 1920), opaque: true, scale: 1.0, rotatedContext: { size, context in
            let colors: [UIColor] = [UIColor(rgb: 0xff00ff), UIColor(rgb: 0xff0000), UIColor(rgb: 0x00ffff), UIColor(rgb: 0x00ff00)]
            if let randomColor = colors.randomElement() {
                context.setFillColor(randomColor.cgColor)
            }
            context.fill(CGRect(origin: .zero, size: size))
        })!
        return .single(.began)
        |> then(
            .single(.finished(image, nil, CACurrentMediaTime())) |> delay(0.5, queue: Queue.concurrentDefaultQueue())
        )
#else
        let uniqueId = settings.uniqueID
        let photoCapture = PhotoCaptureContext(ciContext: self.ciContext, settings: settings, orientation: orientation, mirror: mirror)
        let _ = self.photoCaptureRequests.modify { dict in
            var dict = dict
            dict[uniqueId] = photoCapture
            return dict
        }
        self.photoOutput.capturePhoto(with: settings, delegate: photoCapture)
        
        return photoCapture.signal
        |> afterDisposed { [weak self] in
            let _ = self?.photoCaptureRequests.modify { dict in
                var dict = dict
                dict.removeValue(forKey: uniqueId)
                return dict
            }
        }
#endif
    }
    
    var isRecording: Bool {
        return self.videoRecorder != nil
    }
    
    enum RecorderMode {
        case `default`
        case roundVideo
        case dualCamera
    }
    
    private var currentMode: RecorderMode = .default
    private var recordingCompletionPipe = ValuePipe<VideoCaptureResult>()
    func startRecording(mode: RecorderMode, position: Camera.Position? = nil, orientation: AVCaptureVideoOrientation, additionalOutput: CameraOutput? = nil) -> Signal<CameraRecordingData, CameraRecordingError> {
        guard self.videoRecorder == nil else {
            return .complete()
        }
        
        Logger.shared.log("CameraOutput", "startRecording")
        
        self.currentMode = mode
        self.lastSampleTimestamp = nil
        self.captureOrientation = orientation
        
        var orientation = orientation
        let dimensions: CGSize
        let videoSettings: [String: Any]
        if case .roundVideo = mode {
            dimensions = CGSize(width: self.ggSide, height: self.ggSide) // GHOST: round video resolution
            orientation = .landscapeRight
            
            // GHOST: bitrate and codec from the round video settings (upstream: H.264, 1 Mbit/s)
            if self.ggRecording.useHEVC {
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: self.ggRecording.bitrate(defaultKbps: 1000)],
                    AVVideoWidthKey: Int(dimensions.width),
                    AVVideoHeightKey: Int(dimensions.height)
                ]
            } else {
            let compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: self.ggRecording.bitrate(defaultKbps: 1000), // GHOST: bitrate setting
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC
            ]
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoCompressionPropertiesKey: compressionProperties,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height)
            ]
            }
            self.ggWatermark = GGRoundVideoConfig.watermark(side: self.ggSide) // GHOST: round video watermark
        } else {
            let codecType: AVVideoCodecType = hasHEVCHardwareEncoder ? .hevc : .h264
            if orientation == .landscapeLeft || orientation == .landscapeRight {
                dimensions = CGSize(width: 1920, height: 1080)
            } else {
                dimensions = CGSize(width: 1080, height: 1920)
            }
            guard let settings = self.videoOutput.recommendedVideoSettings(forVideoCodecType: codecType, assetWriterOutputFileType: .mp4) else {
                return .complete()
            }
            videoSettings = settings
        }
        
        var audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) ?? [:]
        // GHOST: «record without sound»: no audio settings = no audio track
        if case .roundVideo = mode, self.ggRecording.muteAudio {
            audioSettings = [:]
        } else if self.hasAudio && audioSettings.isEmpty {
            Logger.shared.log("Camera", "Audio settings are empty on recording start")
            return .fail(.audioInitializationError)
        }
        
        let outputFileName = NSUUID().uuidString
        let outputFilePath = NSTemporaryDirectory() + outputFileName + ".mp4"
        let outputFileURL = URL(fileURLWithPath: outputFilePath)
        
        let videoRecorder = VideoRecorder(
            configuration: VideoRecorder.Configuration(videoSettings: videoSettings, audioSettings: audioSettings),
            ciContext: self.ciContext,
            orientation: orientation,
            fileUrl: outputFileURL,
            completion: { [weak self] result in
                guard let self else {
                    return
                }
                if case let .success(transitionImage, duration, positionChangeTimestamps) = result {
                    self.recordingCompletionPipe.putNext(
                        .finished(
                            main: VideoCaptureResult.Result(
                                path: outputFilePath,
                                thumbnail: transitionImage ?? UIImage(),
                                isMirrored: false,
                                dimensions: dimensions
                            ),
                            additional: nil,
                            duration: duration,
                            positionChangeTimestamps: positionChangeTimestamps.map { ($0 == .front, $1) },
                            captureTimestamp: CACurrentMediaTime()
                        )
                    )
                } else {
                    self.recordingCompletionPipe.putNext(.failed)
                }
            }
        )
        guard let videoRecorder else {
            return .fail(.videoRecorderInitializationError)
        }
        
        videoRecorder.start()
        self.videoRecorder = videoRecorder
        
        if case .dualCamera = mode, let position {
            videoRecorder.markPositionChange(position: position, time: .zero)
        } else if case .roundVideo = mode {
            additionalOutput?.masterOutput = self
        }
        
        return Signal { [videoRecorder] subscriber in
            let timer = SwiftSignalKit.Timer(timeout: 0.09, repeat: true, completion: { [weak videoRecorder] in
                let recordingData = CameraRecordingData(duration: videoRecorder?.duration ?? 0.0, filePath: outputFilePath)
                subscriber.putNext(recordingData)
            }, queue: Queue.mainQueue())
            timer.start()
            
            return ActionDisposable {
                timer.invalidate()
            }
        }
    }
    
    func stopRecording() -> Signal<VideoCaptureResult, NoError> {
        guard let videoRecorder = self.videoRecorder, videoRecorder.isRecording else {
            return .complete()
        }
        videoRecorder.stop()
        
        return self.recordingCompletionPipe.signal()
        |> take(1)
        |> afterDisposed {
            self.videoRecorder = nil
        }
    }
    
    var transitionImage: UIImage? {
        return self.videoRecorder?.transitionImage
    }
    
    private weak var masterOutput: CameraOutput?
    
    private var lastSampleTimestamp: CMTime?
    
    private func roundVideoFormatDescription(for sourceFormatDescription: CMFormatDescription) -> CMFormatDescription? {
        if let entry = self.roundVideoFormatDescriptionCache.first(where: { CFEqual($0.sourceFormatDescription, sourceFormatDescription) }) {
            return entry.outputFormatDescription
        }

        guard let extensions = CMFormatDescriptionGetExtensions(sourceFormatDescription) as? [String: Any] else {
            return nil
        }

        let mediaSubType = CMFormatDescriptionGetMediaSubType(sourceFormatDescription)
        var updatedExtensions = extensions
        updatedExtensions["CVBytesPerRow"] = self.ggSide * 4 // GHOST: round video resolution

        var outputFormatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: mediaSubType,
            width: Int32(self.ggSide), // GHOST: round video resolution
            height: Int32(self.ggSide),
            extensions: updatedExtensions as CFDictionary,
            formatDescriptionOut: &outputFormatDescription
        )
        guard status == noErr, let outputFormatDescription else {
            return nil
        }

        self.roundVideoFormatDescriptionCache.append(RoundVideoFormatDescriptionCacheEntry(
            sourceFormatDescription: sourceFormatDescription,
            outputFormatDescription: outputFormatDescription
        ))
        if self.roundVideoFormatDescriptionCache.count > 4 {
            self.roundVideoFormatDescriptionCache.removeFirst(self.roundVideoFormatDescriptionCache.count - 4)
        }

        return outputFormatDescription
    }

    private var needsCrossfadeTransition = false
    private var crossfadeTransitionStart: Double = 0.0
    
    private var needsSwitchSampleOffset = false
    private var lastAudioSampleTime: CMTime?
    private var videoSwitchSampleTimeOffset: CMTime?
    
    func processVideoRecording(_ sampleBuffer: CMSampleBuffer, fromAdditionalOutput: Bool) {
        guard let formatDescriptor = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let type = CMFormatDescriptionGetMediaType(formatDescriptor)
        guard let videoRecorder = self.videoRecorder, videoRecorder.isRecording else {
            return
        }
        
        if case .roundVideo = self.currentMode, type == kCMMediaType_Video {
            let currentTimestamp = CACurrentMediaTime()
            let duration: Double = 0.2
            if !self.exclusive {
                var transitionFactor: CGFloat = 0.0
                if case .front = self.currentPosition {
                    transitionFactor = 1.0
                    if self.lastSwitchTimestamp > 0.0, currentTimestamp - self.lastSwitchTimestamp < duration {
                        transitionFactor = max(0.0, (currentTimestamp - self.lastSwitchTimestamp) / duration)
                    }
                } else {
                    transitionFactor = 0.0
                    if self.lastSwitchTimestamp > 0.0, currentTimestamp - self.lastSwitchTimestamp < duration {
                        transitionFactor = 1.0 - max(0.0, (currentTimestamp - self.lastSwitchTimestamp) / duration)
                    }
                }
                
                if (transitionFactor == 1.0 && fromAdditionalOutput)
                    || (transitionFactor == 0.0 && !fromAdditionalOutput)
                    || (transitionFactor > 0.0 && transitionFactor < 1.0) {
                    let processedSampleBuffer = self.processRoundVideoSampleBuffer(sampleBuffer, additional: fromAdditionalOutput, transitionFactor: transitionFactor)
                    if let processedSampleBuffer {
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(processedSampleBuffer)
                        if let lastSampleTimestamp = self.lastSampleTimestamp, lastSampleTimestamp > presentationTime {
                        } else {
                            videoRecorder.appendSampleBuffer(processedSampleBuffer)
                            self.lastSampleTimestamp = presentationTime
                        }
                    }
                } else {
                }
            } else {
                var additional = self.currentPosition == .front
                var transitionFactor = self.currentPosition == .front ? 1.0 : 0.0
                if self.lastSwitchTimestamp > 0.0 {
                    if self.needsCrossfadeTransition {
                        self.needsCrossfadeTransition = false
                        self.crossfadeTransitionStart = currentTimestamp + 0.03
                        self.needsSwitchSampleOffset = true
                    }
                    if self.crossfadeTransitionStart > 0.0, currentTimestamp - self.crossfadeTransitionStart < duration {
                        if case .front = self.currentPosition {
                            transitionFactor = max(0.0, (currentTimestamp - self.crossfadeTransitionStart) / duration)
                        } else {
                            transitionFactor = 1.0 - max(0.0, (currentTimestamp - self.crossfadeTransitionStart) / duration)
                        }
                    } else if currentTimestamp - self.lastSwitchTimestamp < 0.05 {
                        additional = !additional
                        transitionFactor = 1.0 - transitionFactor
                        self.needsCrossfadeTransition = true
                    }
                }
                let processedSampleBuffer = self.processRoundVideoSampleBuffer(sampleBuffer, additional: additional, transitionFactor: transitionFactor)
                if let processedSampleBuffer {
                    videoRecorder.appendSampleBuffer(processedSampleBuffer)
                } else {
                    videoRecorder.appendSampleBuffer(sampleBuffer)
                }
            }
        } else {
            if type == kCMMediaType_Audio {
                if self.needsSwitchSampleOffset {
                    self.needsSwitchSampleOffset = false
                    
                    if let lastAudioSampleTime = self.lastAudioSampleTime {
                        let videoSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let offset = videoSampleTime - lastAudioSampleTime
                        if let current = self.videoSwitchSampleTimeOffset {
                            self.videoSwitchSampleTimeOffset = current + offset
                        } else {
                            self.videoSwitchSampleTimeOffset = offset
                        }
                        self.lastAudioSampleTime = nil
                    }
                }
                
                self.lastAudioSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) + CMSampleBufferGetDuration(sampleBuffer)
            }
            videoRecorder.appendSampleBuffer(sampleBuffer)
        }
    }
    
    private func processRoundVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, additional: Bool, transitionFactor: CGFloat) -> CMSampleBuffer? {
        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        self.semaphore.wait()
        defer {
            self.semaphore.signal()
        }

        guard let newFormatDescription = self.roundVideoFormatDescription(for: formatDescription) else {
            return nil
        }
        
        let filter: CameraRoundLegacyVideoFilter
        if let current = self.roundVideoFilter {
            filter = current
        } else {
            filter = CameraRoundLegacyVideoFilter(ciContext: self.ciContext, colorSpace: self.colorSpace, simple: self.exclusive, side: self.ggSide) // GHOST: round video resolution
            self.roundVideoFilter = filter
        }
        if !filter.isPrepared || filter.inputFormatDescription.map({ !CFEqual($0, newFormatDescription) }) ?? true {
            filter.prepare(with: newFormatDescription, outputRetainedBufferCountHint: 4)
        }

        guard let newPixelBuffer = filter.render(pixelBuffer: videoPixelBuffer, additional: additional, captureOrientation: self.captureOrientation, transitionFactor: transitionFactor) else {
            return nil
        }
        // GHOST: round video watermark over the finished square
        self.ggWatermark?.draw(into: newPixelBuffer)
        
        var sampleTimingInfo: CMSampleTimingInfo = .invalid
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &sampleTimingInfo)
        
        if let videoSwitchSampleTimeOffset = self.videoSwitchSampleTimeOffset {
            sampleTimingInfo.decodeTimeStamp = sampleTimingInfo.decodeTimeStamp - videoSwitchSampleTimeOffset
            sampleTimingInfo.presentationTimeStamp = sampleTimingInfo.presentationTimeStamp - videoSwitchSampleTimeOffset
        }
        
        var newSampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: newPixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: newFormatDescription,
            sampleTiming: &sampleTimingInfo,
            sampleBufferOut: &newSampleBuffer
        )
        
        if status == noErr, let newSampleBuffer {
            return newSampleBuffer
        }
        return nil
    }
    
    private var currentPosition: Camera.Position = .front
    private var lastSwitchTimestamp: Double = 0.0
   
    func markPositionChange(position: Camera.Position) {
        self.currentPosition = position
        self.lastSwitchTimestamp = CACurrentMediaTime()
        
        if let videoRecorder = self.videoRecorder {
            videoRecorder.markPositionChange(position: position)
        }
    }
}

extension CameraOutput: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        // GHOST: Ghostgram frame processor (masks): once per frame of the visible camera, before both
        // the recorder and the preview see it
        let sampleBuffer = self.ggProcessedSampleBuffer(sampleBuffer, connection: connection)
                        
        if let masterOutput = self.masterOutput {
            masterOutput.processVideoRecording(sampleBuffer, fromAdditionalOutput: true)
        } else {
            self.processVideoRecording(sampleBuffer, fromAdditionalOutput: false)
        }
        
        if let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            self.processSampleBuffer?(sampleBuffer, videoPixelBuffer, connection)
        } else if sampleBuffer.type == kCMMediaType_Audio {
            self.processAudioBuffer?(sampleBuffer)
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if #available(iOS 13.0, *) {
            Logger.shared.log("Camera", "Dropped sample buffer \(sampleBuffer.attachments)")
        }
    }
}

// GHOST: Ghostgram round video settings and frame processor
extension CameraOutput {
    private func ggStabilizationMode(connection: AVCaptureConnection) -> AVCaptureVideoStabilizationMode {
        guard self.isVideoMessage else {
            return .standard
        }
        switch self.ggRecording.stabilization {
        case .standard:
            return .standard
        case .off:
            return .off
        case .cinematic:
            let device = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device
            if let device, device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                return .cinematic
            }
            return .standard
        }
    }

    private func ggProcessedSampleBuffer(_ sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) -> CMSampleBuffer {
        guard let processor = self.ggFrameProcessor, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return sampleBuffer
        }
        let position = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device.position ?? .front
        // Dual camera: only the camera the user sees is processed.
        let master = self.masterOutput ?? self
        if !master.exclusive && position != master.currentPosition {
            return sampleBuffer
        }
        let quarterTurns: Int
        switch self.captureOrientation {
        case .landscapeLeft:
            quarterTurns = position == .front ? 0 : 2
        case .landscapeRight:
            quarterTurns = position == .front ? 2 : 0
        case .portraitUpsideDown:
            quarterTurns = 3
        default:
            quarterTurns = 1
        }
        let info = GGCameraFrameInfo(
            facing: position == .front ? .front : .back,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            orientation: GGCameraFrameInfo.orientation(quarterTurns: quarterTurns, mirrored: position == .front)
        )
        guard let processed = processor.process(pixelBuffer, info: info) else {
            return sampleBuffer
        }
        if let current = self.ggFormatDescription, CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: processed) {
        } else {
            var formatDescription: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: processed, formatDescriptionOut: &formatDescription) == noErr, let formatDescription else {
                return sampleBuffer
            }
            self.ggFormatDescription = formatDescription
        }
        guard let formatDescription = self.ggFormatDescription else {
            return sampleBuffer
        }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: processed, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &result) == noErr, let result else {
            return sampleBuffer
        }
        return result
    }
}

extension CameraOutput: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let codes: [CameraCode] = metadataObjects.filter { $0.type == .qr }.compactMap { object in
            if let object = object as? AVMetadataMachineReadableCodeObject, let stringValue = object.stringValue, !stringValue.isEmpty {
                #if targetEnvironment(simulator)
                return CameraCode(type: .qr, message: stringValue, corners: [CGPoint(), CGPoint(), CGPoint(), CGPoint()])
                #else
                return CameraCode(type: .qr, message: stringValue, corners: object.corners)
                #endif
            } else {
                return nil
            }
        }
        self.processCodes?(codes)
    }
}

private let hasHEVCHardwareEncoder: Bool = {
    let spec: [CFString: Any] = [:]
    var outID: CFString?
    var properties: CFDictionary?
    let result = VTCopySupportedPropertyDictionaryForEncoder(width: 1920, height: 1080, codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary, encoderIDOut: &outID, supportedPropertiesOut: &properties)
    if result == kVTCouldNotFindVideoEncoderErr {
        return false
    }
    return result == noErr
}()
