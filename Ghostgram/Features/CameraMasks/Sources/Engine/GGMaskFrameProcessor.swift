import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import Metal
import QuartzCore
import GGCameraPipeline

/// The one Core Image context of the masks, created on the first frame that has a mask (never by
/// opening a screen or starting a call).
enum GGMaskRenderContext {
    static let shared: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

/// Keeps the masks within the frame budget. It watches how long a frame takes against the frame
/// interval it measures (30 or 60 fps), the thermal state and Low Power Mode, and answers with
/// two knobs: how much slower Vision runs, and how many simplification steps each heavy layer
/// gets. Unlike before, quality comes back when the device cools down or the load drops.
final class GGMaskGovernor {
    private var averageMs: Double = 0.0
    private var hasAverage = false
    private var lastTimestamp: Double?
    private var frameIntervalMs: Double = 1000.0 / 30.0
    private var overBudgetFrames = 0
    private var underBudgetFrames = 0
    private var framesSinceEnvironmentCheck = 0
    private var thermalLevel = 0
    private var isLowPower = false
    private var history: [Int] = []

    private(set) var degrade = GGMaskDegradeState()
    private(set) var visionSlowdown: Double = 1.0
    private(set) var isSimplified = false

    func reset() {
        self.averageMs = 0.0
        self.hasAverage = false
        self.overBudgetFrames = 0
        self.underBudgetFrames = 0
        self.degrade = GGMaskDegradeState()
        self.history = []
        self.isSimplified = false
        self.updateVisionSlowdown()
    }

    /// Capture queue, after every processed frame.
    func record(processingMs: Double, timestamp: Double, mask: GGPreparedMask) {
        if let last = self.lastTimestamp {
            let interval = (timestamp - last) * 1000.0
            if interval > 5.0 && interval < 200.0 {
                self.frameIntervalMs = self.frameIntervalMs * 0.9 + interval * 0.1
            }
        }
        self.lastTimestamp = timestamp
        if self.hasAverage {
            self.averageMs = self.averageMs * 0.9 + processingMs * 0.1
        } else {
            self.averageMs = processingMs
            self.hasAverage = true
        }

        self.framesSinceEnvironmentCheck += 1
        if self.framesSinceEnvironmentCheck >= 30 {
            self.framesSinceEnvironmentCheck = 0
            let state = ProcessInfo.processInfo.thermalState
            switch state {
            case .serious:
                self.thermalLevel = 1
            case .critical:
                self.thermalLevel = 2
            default:
                self.thermalLevel = 0
            }
            self.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.updateVisionSlowdown()
        }

        // The mask may use ¾ of the frame interval: the rest is the camera, the preview and the encoder.
        var budget = self.frameIntervalMs * 0.75
        if self.isLowPower {
            budget *= 0.75
        }
        if self.thermalLevel > 0 {
            budget *= self.thermalLevel == 2 ? 0.5 : 0.7
        }
        if self.averageMs > budget {
            self.underBudgetFrames = 0
            self.overBudgetFrames += 1
            if self.overBudgetFrames >= 30 {
                self.overBudgetFrames = 0
                self.simplify(mask: mask)
            }
        } else if self.averageMs < budget * 0.5 {
            self.overBudgetFrames = 0
            self.underBudgetFrames += 1
            if self.underBudgetFrames >= 90 {
                self.underBudgetFrames = 0
                self.restore()
            }
        } else {
            self.overBudgetFrames = 0
            self.underBudgetFrames = 0
        }
    }

    /// One more step for the most expensive layer that can still be simplified.
    private func simplify(mask: GGPreparedMask) {
        var best: (index: Int, cost: Int)?
        for (index, effect) in mask.manifest.effects.enumerated() where effect.isEnabled && effect.type == .filter {
            guard let id = effect.filterId, let descriptor = GGFilterCatalog.descriptor(id) else {
                continue
            }
            let applied = self.degrade.steps[index] ?? 0
            if applied >= descriptor.degrade.count {
                continue
            }
            if best == nil || descriptor.cost > best!.cost {
                best = (index, descriptor.cost)
            }
        }
        if let best {
            self.degrade.steps[best.index] = (self.degrade.steps[best.index] ?? 0) + 1
            self.history.append(best.index)
            self.isSimplified = true
        } else if self.visionSlowdown < 3.0 {
            self.history.append(-1)
            self.updateVisionSlowdown()
        }
    }

    private func restore() {
        guard let last = self.history.popLast() else {
            return
        }
        if last >= 0, let steps = self.degrade.steps[last] {
            self.degrade.steps[last] = steps > 1 ? steps - 1 : nil
        }
        self.isSimplified = !self.history.isEmpty
        self.updateVisionSlowdown()
    }

    private func updateVisionSlowdown() {
        var slowdown = 1.0
        if self.frameIntervalMs < 25.0 {
            // 60 fps: detection does not need to follow every frame.
            slowdown = 1.5
        }
        if self.isLowPower {
            slowdown = max(slowdown, 1.5)
        }
        if self.thermalLevel == 1 {
            slowdown = max(slowdown, 2.0)
        } else if self.thermalLevel == 2 {
            slowdown = 3.0
        }
        let extra = Double(self.history.filter { $0 < 0 }.count) * 0.5
        self.visionSlowdown = min(3.0, slowdown + extra)
    }
}

/// The mask stage of a camera stream: a frame of the visible camera in, the same frame with the
/// mask out (same size and pixel format: NV12 from CameraNeo and calls, BGRA from the legacy
/// camera). One render per frame; the result feeds both the recorder and the live preview.
final class GGMaskFrameProcessor: GGCameraFrameProcessor {
    /// Returns the mask to apply right now (one atomic load; nil = pass frames through).
    private let maskProvider: () -> GGPreparedMask?
    private let tracker = GGFaceTracker()
    private let governor = GGMaskGovernor()
    private var lastMask: GGPreparedMask?

    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?

    /// Every processed frame (and nil when frames pass through untouched), on the capture queue.
    var previewSink: ((CVPixelBuffer?, GGCameraFrameInfo) -> Void)?

    /// Read by the studio on the main thread («≈N fps on this device», «simplified»); written on
    /// the capture queue, hence the lock.
    private let statsLock = NSLock()
    private var measuredFpsValue = 0
    private var isSimplifiedValue = false

    var measuredFps: Int {
        self.statsLock.lock()
        defer {
            self.statsLock.unlock()
        }
        return self.measuredFpsValue
    }

    var isSimplified: Bool {
        self.statsLock.lock()
        defer {
            self.statsLock.unlock()
        }
        return self.isSimplifiedValue
    }

    private func publishStats(fps: Int) {
        let simplified = self.governor.isSimplified
        self.statsLock.lock()
        self.measuredFpsValue = fps
        self.isSimplifiedValue = simplified
        self.statsLock.unlock()
    }

    init(maskProvider: @escaping () -> GGPreparedMask?) {
        self.maskProvider = maskProvider
    }

    func process(_ pixelBuffer: CVPixelBuffer, info: GGCameraFrameInfo) -> CVPixelBuffer? {
        guard let mask = self.maskProvider() else {
            if self.lastMask != nil {
                self.lastMask = nil
                self.tracker.reset()
                self.governor.reset()
                self.publishStats(fps: 0)
            }
            self.previewSink?(nil, info)
            return nil
        }
        if self.lastMask !== mask {
            self.lastMask = mask
            self.governor.reset()
        }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_32BGRA else {
            self.previewSink?(nil, info)
            return nil
        }
        let start = CACurrentMediaTime()
        let time = info.timestamp.isValid ? info.timestamp.seconds : start

        let raw = CIImage(cvPixelBuffer: pixelBuffer)
        var toUpright = raw.orientationTransform(for: info.orientation)
        let orientedExtent = raw.extent.applying(toUpright)
        toUpright = toUpright.concatenating(CGAffineTransform(translationX: -orientedExtent.minX, y: -orientedExtent.minY))
        let upright = raw.transformed(by: toUpright)
        let extent = CGRect(origin: .zero, size: orientedExtent.size)

        let degrade = self.governor.degrade
        var needs = GGVisionNeeds()
        for item in degrade.apply(to: mask.manifest.effects) {
            needs.formUnion(GGFilterCatalog.visionNeeds(of: item.effect))
        }
        self.tracker.submit(pixelBuffer, orientation: info.orientation, needs: needs, time: time, slowdown: self.governor.visionSlowdown)

        let tracker = self.tracker
        let frame = GGMaskFrame(extent: extent, time: time, assets: mask.assets, face: {
            return tracker.face(time: time, extent: extent)
        }, segmentation: {
            return tracker.segmentationMask(extent: extent)
        })
        let rendered = GGMaskRenderer.render(mask, source: upright, frame: frame, degrade: degrade)
        let back = rendered.transformed(by: toUpright.inverted())

        guard let output = self.makeBuffer(like: pixelBuffer) else {
            self.previewSink?(nil, info)
            return nil
        }
        CVBufferPropagateAttachments(pixelBuffer, output)
        GGMaskRenderContext.shared.render(back, to: output, bounds: raw.extent, colorSpace: GGMaskRenderContext.colorSpace)

        let elapsedMs = (CACurrentMediaTime() - start) * 1000.0
        self.governor.record(processingMs: elapsedMs, timestamp: time, mask: mask)
        self.publishStats(fps: elapsedMs <= 0.5 ? 30 : max(1, min(30, Int((1000.0 / (elapsedMs + 11.0)).rounded()))))
        self.previewSink?(output, info)
        return output
    }

    private func makeBuffer(like pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if self.pool == nil || self.poolKey?.width != width || self.poolKey?.height != height || self.poolKey?.format != format {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attributes as CFDictionary, &pool)
            self.pool = pool
            self.poolKey = (width, height, format)
        }
        guard let pool = self.pool else {
            return nil
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
