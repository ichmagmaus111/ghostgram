import Foundation
import UIKit
import AVFoundation
import CoreMedia
import GGCameraPipeline

/// Shows processed camera frames (the live mask preview). Frames are enqueued straight from the
/// capture queue into an `AVSampleBufferDisplayLayer`: no Core Image pass and no copy for display.
/// The view hides itself while frames pass through untouched, so the camera's own preview shows.
final class GGProcessedFrameView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var isShowingFrames = false
    private var orientation: CGImagePropertyOrientation = .up

    /// Main thread: the first processed frame arrived / frames stopped.
    var visibilityChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.displayLayer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(self.displayLayer)
        self.backgroundColor = .clear
        self.alpha = 0.0
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    /// Capture queue. nil = no processed frame (hide).
    func enqueue(_ pixelBuffer: CVPixelBuffer?, orientation: CGImagePropertyOrientation) {
        guard let pixelBuffer else {
            self.setShowing(false, orientation: orientation)
            return
        }
        self.lock.lock()
        if self.formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(self.formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            self.formatDescription = description
        }
        let formatDescription = self.formatDescription
        self.lock.unlock()
        guard let formatDescription else {
            return
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else {
            return
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let layer = self.displayLayer
        if layer.status == .failed {
            layer.flush()
        }
        if layer.isReadyForMoreMediaData {
            layer.enqueue(sampleBuffer)
        }
        self.setShowing(true, orientation: orientation)
    }

    private func setShowing(_ showing: Bool, orientation: CGImagePropertyOrientation) {
        self.lock.lock()
        let changed = self.isShowingFrames != showing || self.orientation != orientation
        self.isShowingFrames = showing
        self.orientation = orientation
        self.lock.unlock()
        if !changed {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.applyOrientation(orientation)
            UIView.animate(withDuration: 0.15, animations: {
                self.alpha = showing ? 1.0 : 0.0
            })
            if !showing {
                self.displayLayer.flushAndRemoveImage()
            }
            self.visibilityChanged?(showing)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.lock.lock()
        let orientation = self.orientation
        self.lock.unlock()
        self.applyOrientation(orientation)
    }

    /// The buffer is in the sensor's orientation: turn the layer the way `orientation` says.
    private func applyOrientation(_ orientation: CGImagePropertyOrientation) {
        let angle: CGFloat
        let mirrored: Bool
        switch orientation {
        case .up:
            angle = 0.0
            mirrored = false
        case .upMirrored:
            angle = 0.0
            mirrored = true
        case .right:
            angle = .pi / 2.0
            mirrored = false
        case .leftMirrored:
            angle = .pi / 2.0
            mirrored = true
        case .down:
            angle = .pi
            mirrored = false
        case .downMirrored:
            angle = .pi
            mirrored = true
        case .left:
            angle = -.pi / 2.0
            mirrored = false
        case .rightMirrored:
            angle = -.pi / 2.0
            mirrored = true
        @unknown default:
            angle = 0.0
            mirrored = false
        }
        let size = self.bounds.size
        let isSideways = abs(abs(angle) - .pi / 2.0) < 0.01
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.displayLayer.bounds = CGRect(origin: .zero, size: isSideways ? CGSize(width: size.height, height: size.width) : size)
        self.displayLayer.position = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        self.displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(scaleX: mirrored ? -1.0 : 1.0, y: 1.0)))
        CATransaction.commit()
    }
}
