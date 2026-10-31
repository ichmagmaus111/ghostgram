import Foundation
import CoreImage
import CoreVideo
import ImageIO
import Vision

/// Face geometry in the coordinates of the upright frame image (Core Image: origin bottom-left,
/// pixels of the frame the effects are drawn on).
struct GGFaceGeometry {
    var bounds: CGRect
    /// Head roll, radians, counter-clockwise.
    var roll: CGFloat
    var landmarks: GGFaceLandmarks?

    func applying(_ transform: CGAffineTransform) -> GGFaceGeometry {
        var result = self
        result.bounds = self.bounds.applying(transform)
        result.landmarks = self.landmarks?.applying(transform)
        return result
    }

    /// Distance between the eye centres (or a share of the face width without landmarks).
    var interEyeDistance: CGFloat {
        if let landmarks = self.landmarks, let left = landmarks.leftEyeCenter, let right = landmarks.rightEyeCenter {
            return hypot(right.x - left.x, right.y - left.y)
        }
        return self.bounds.width * 0.42
    }
}

struct GGFaceLandmarks {
    var leftEye: [CGPoint] = []
    var rightEye: [CGPoint] = []
    var leftPupil: CGPoint?
    var rightPupil: CGPoint?
    var leftEyebrow: [CGPoint] = []
    var rightEyebrow: [CGPoint] = []
    var nose: [CGPoint] = []
    var outerLips: [CGPoint] = []
    var faceContour: [CGPoint] = []
    var medianLine: [CGPoint] = []

    func applying(_ transform: CGAffineTransform) -> GGFaceLandmarks {
        func map(_ points: [CGPoint]) -> [CGPoint] {
            return points.map { $0.applying(transform) }
        }
        var result = GGFaceLandmarks()
        result.leftEye = map(self.leftEye)
        result.rightEye = map(self.rightEye)
        result.leftPupil = self.leftPupil?.applying(transform)
        result.rightPupil = self.rightPupil?.applying(transform)
        result.leftEyebrow = map(self.leftEyebrow)
        result.rightEyebrow = map(self.rightEyebrow)
        result.nose = map(self.nose)
        result.outerLips = map(self.outerLips)
        result.faceContour = map(self.faceContour)
        result.medianLine = map(self.medianLine)
        return result
    }

    var leftEyeCenter: CGPoint? {
        return self.leftPupil ?? ggCentroid(self.leftEye)
    }

    var rightEyeCenter: CGPoint? {
        return self.rightPupil ?? ggCentroid(self.rightEye)
    }

    /// The lowest point of the median line, else of the face contour.
    var chinPoint: CGPoint? {
        if let point = self.medianLine.min(by: { $0.y < $1.y }) {
            return point
        }
        return self.faceContour.min(by: { $0.y < $1.y })
    }

    /// Every point, for smoothing.
    var allPoints: [CGPoint] {
        var result = self.leftEye + self.rightEye + self.leftEyebrow + self.rightEyebrow + self.nose + self.outerLips + self.faceContour + self.medianLine
        if let point = self.leftPupil {
            result.append(point)
        }
        if let point = self.rightPupil {
            result.append(point)
        }
        return result
    }

    /// Rebuilds landmarks from `allPoints` of the same layout.
    func replacingPoints(_ points: [CGPoint]) -> GGFaceLandmarks {
        var result = self
        var index = 0
        func take(_ count: Int) -> [CGPoint] {
            let slice = Array(points[index ..< index + count])
            index += count
            return slice
        }
        result.leftEye = take(self.leftEye.count)
        result.rightEye = take(self.rightEye.count)
        result.leftEyebrow = take(self.leftEyebrow.count)
        result.rightEyebrow = take(self.rightEyebrow.count)
        result.nose = take(self.nose.count)
        result.outerLips = take(self.outerLips.count)
        result.faceContour = take(self.faceContour.count)
        result.medianLine = take(self.medianLine.count)
        if self.leftPupil != nil {
            result.leftPupil = points[index]
            index += 1
        }
        if self.rightPupil != nil {
            result.rightPupil = points[index]
        }
        return result
    }
}

func ggCentroid(_ points: [CGPoint]) -> CGPoint? {
    if points.isEmpty {
        return nil
    }
    var x: CGFloat = 0.0
    var y: CGFloat = 0.0
    for point in points {
        x += point.x
        y += point.y
    }
    return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
}

func ggBounds(_ points: [CGPoint]) -> CGRect? {
    guard let first = points.first else {
        return nil
    }
    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y
    for point in points {
        minX = min(minX, point.x)
        maxX = max(maxX, point.x)
        minY = min(minY, point.y)
        maxY = max(maxY, point.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// Face detection, landmarks and person segmentation for one camera stream.
///
/// Vision never runs on the capture queue: a frame is handed to the tracker's own queue when a new
/// detection is due (20 Hz faces, ~13 Hz landmarks, 10 Hz segmentation, slower under the governor),
/// at most one at a time. Every frame reads the latest result, smoothed toward it, so stickers glide
/// instead of jumping between detections. A lost face is held for 1.2 s before it disappears.
final class GGFaceTracker {
    private let queue = DispatchQueue(label: "org.ghostgram.masks.vision", qos: .userInitiated)
    private let lock = NSLock()

    private var isDetecting = false
    private var lastFaceRequestTime: Double = 0.0
    private var lastSegmentationRequestTime: Double = 0.0

    // Latest raw results, in normalized upright coordinates (origin bottom-left).
    private var latestFace: (bounds: CGRect, roll: CGFloat, landmarks: GGFaceLandmarks?)?
    private var latestFaceTime: Double = 0.0
    private var latestSegmentation: CVPixelBuffer?

    // Smoothed state, in normalized coordinates.
    private var smoothedBounds: CGRect?
    private var smoothedRoll: CGFloat = 0.0
    private var smoothedLandmarks: GGFaceLandmarks?

    private let sequenceHandler = VNSequenceRequestHandler()

    static let holdDuration: Double = 1.2

    /// Called on the capture queue for every processed frame. Starts a detection when one is due.
    func submit(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, needs: GGVisionNeeds, time: Double, slowdown: Double) {
        if needs.isEmpty {
            return
        }
        self.lock.lock()
        let isBusy = self.isDetecting
        let faceInterval = (needs.contains(.landmarks) ? 0.075 : 0.05) * slowdown
        let segmentationInterval = 0.1 * slowdown
        let wantsFace = needs.contains(.face) && time - self.lastFaceRequestTime >= faceInterval
        let wantsSegmentation = needs.contains(.segmentation) && time - self.lastSegmentationRequestTime >= segmentationInterval
        if isBusy || (!wantsFace && !wantsSegmentation) {
            self.lock.unlock()
            return
        }
        self.isDetecting = true
        if wantsFace {
            self.lastFaceRequestTime = time
        }
        if wantsSegmentation {
            self.lastSegmentationRequestTime = time
        }
        self.lock.unlock()

        let wantsLandmarks = needs.contains(.landmarks)
        self.queue.async { [weak self] in
            self?.detect(pixelBuffer, orientation: orientation, face: wantsFace, landmarks: wantsLandmarks, segmentation: wantsSegmentation, time: time)
        }
    }

    private func detect(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, face: Bool, landmarks: Bool, segmentation: Bool, time: Double) {
        var requests: [VNRequest] = []
        var faceRequest: VNImageBasedRequest?
        if face {
            if landmarks {
                let request = VNDetectFaceLandmarksRequest()
                request.revision = VNDetectFaceLandmarksRequestRevision3
                faceRequest = request
            } else {
                faceRequest = VNDetectFaceRectanglesRequest()
            }
            if let faceRequest {
                requests.append(faceRequest)
            }
        }
        var segmentationRequest: VNGeneratePersonSegmentationRequest?
        if segmentation {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .fast
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            segmentationRequest = request
            requests.append(request)
        }
        try? self.sequenceHandler.perform(requests, on: pixelBuffer, orientation: orientation)

        var faceResult: (bounds: CGRect, roll: CGFloat, landmarks: GGFaceLandmarks?)?
        if let faceRequest, let observations = faceRequest.results as? [VNFaceObservation] {
            // The largest face, not the first one Vision lists.
            if let observation = observations.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                faceResult = (observation.boundingBox, CGFloat(observation.roll?.doubleValue ?? 0.0), GGFaceTracker.landmarks(observation))
            }
        }
        let mask = segmentationRequest?.results?.first?.pixelBuffer

        self.lock.lock()
        if face, let faceResult {
            self.latestFace = faceResult
            self.latestFaceTime = time
        }
        if segmentation, let mask {
            self.latestSegmentation = mask
        }
        self.isDetecting = false
        self.lock.unlock()
    }

    /// Landmark points in normalized image coordinates (Vision gives them relative to the face box).
    private static func landmarks(_ observation: VNFaceObservation) -> GGFaceLandmarks? {
        guard let source = observation.landmarks else {
            return nil
        }
        let box = observation.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else {
                return []
            }
            return region.normalizedPoints.map { point in
                CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
            }
        }
        var result = GGFaceLandmarks()
        result.leftEye = points(source.leftEye)
        result.rightEye = points(source.rightEye)
        result.leftPupil = points(source.leftPupil).first
        result.rightPupil = points(source.rightPupil).first
        result.leftEyebrow = points(source.leftEyebrow)
        result.rightEyebrow = points(source.rightEyebrow)
        result.nose = points(source.nose)
        result.outerLips = points(source.outerLips)
        result.faceContour = points(source.faceContour)
        result.medianLine = points(source.medianLine)
        return result
    }

    /// The smoothed face for this frame in pixels of `extent`, or nil (no face, or lost for longer
    /// than the hold time). Advances the smoothing one step.
    func face(time: Double, extent: CGRect) -> GGFaceGeometry? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let latest = self.latestFace else {
            return nil
        }
        if time - self.latestFaceTime > GGFaceTracker.holdDuration {
            // Keep the smoothed state: a face that comes back slides in instead of popping.
            return nil
        }
        let target = latest.bounds
        if let current = self.smoothedBounds {
            let faceSize = max(current.width, current.height, 0.0001)
            let motion = max(
                hypot(target.midX - current.midX, target.midY - current.midY) / faceSize,
                (abs(target.width - current.width) + abs(target.height - current.height)) / (2.0 * faceSize)
            )
            let alpha = GGFaceTracker.smoothingFactor(motion: motion)
            self.smoothedBounds = CGRect(
                x: current.minX + (target.minX - current.minX) * alpha,
                y: current.minY + (target.minY - current.minY) * alpha,
                width: current.width + (target.width - current.width) * alpha,
                height: current.height + (target.height - current.height) * alpha
            )
            var delta = latest.roll - self.smoothedRoll
            while delta > .pi {
                delta -= 2.0 * .pi
            }
            while delta < -.pi {
                delta += 2.0 * .pi
            }
            if abs(delta) > 1.2 {
                self.smoothedRoll = latest.roll
            } else if abs(delta) > 0.004 {
                self.smoothedRoll += delta * 0.35
            }
            if let targetLandmarks = latest.landmarks {
                if let currentLandmarks = self.smoothedLandmarks, currentLandmarks.allPoints.count == targetLandmarks.allPoints.count {
                    let currentPoints = currentLandmarks.allPoints
                    let targetPoints = targetLandmarks.allPoints
                    var points: [CGPoint] = []
                    points.reserveCapacity(targetPoints.count)
                    for i in 0 ..< targetPoints.count {
                        let distance = hypot(targetPoints[i].x - currentPoints[i].x, targetPoints[i].y - currentPoints[i].y) / faceSize
                        if distance < 0.012 {
                            points.append(currentPoints[i])
                        } else {
                            let pointAlpha = GGFaceTracker.smoothingFactor(motion: distance)
                            points.append(CGPoint(x: currentPoints[i].x + (targetPoints[i].x - currentPoints[i].x) * pointAlpha, y: currentPoints[i].y + (targetPoints[i].y - currentPoints[i].y) * pointAlpha))
                        }
                    }
                    self.smoothedLandmarks = targetLandmarks.replacingPoints(points)
                } else {
                    self.smoothedLandmarks = targetLandmarks
                }
            } else {
                self.smoothedLandmarks = nil
            }
        } else {
            self.smoothedBounds = target
            self.smoothedRoll = latest.roll
            self.smoothedLandmarks = latest.landmarks
        }
        guard let bounds = self.smoothedBounds else {
            return nil
        }
        let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY).scaledBy(x: extent.width, y: extent.height)
        return GGFaceGeometry(bounds: bounds, roll: self.smoothedRoll, landmarks: self.smoothedLandmarks).applying(transform)
    }

    /// Person mask scaled to `extent` (white = person), or nil while none was computed yet.
    func segmentationMask(extent: CGRect) -> CIImage? {
        self.lock.lock()
        let buffer = self.latestSegmentation
        self.lock.unlock()
        guard let buffer else {
            return nil
        }
        let image = CIImage(cvPixelBuffer: buffer)
        let scaleX = extent.width / max(1.0, image.extent.width)
        let scaleY = extent.height / max(1.0, image.extent.height)
        return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY).concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
    }

    func reset() {
        self.lock.lock()
        self.latestFace = nil
        self.latestSegmentation = nil
        self.smoothedBounds = nil
        self.smoothedLandmarks = nil
        self.lock.unlock()
    }

    /// Hold below a small motion, snap above a large one, ease in between (quadratic ramp).
    private static func smoothingFactor(motion: CGFloat) -> CGFloat {
        if motion < 0.006 {
            return 0.0
        }
        if motion > 0.45 {
            return 1.0
        }
        let t = min(1.0, max(0.0, (motion - 0.006) / (0.32 - 0.006)))
        return 0.15 + 0.75 * t * t
    }
}
