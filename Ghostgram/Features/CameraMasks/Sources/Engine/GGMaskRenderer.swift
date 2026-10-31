import Foundation
import CoreImage
import ImageIO

/// Images of one mask (its `assets/` directory), decoded once and kept in a small LRU.
final class GGMaskAssets {
    let directory: URL
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]
    private var order: [String] = []
    private var missing = Set<String>()

    init(directory: URL) {
        self.directory = directory
    }

    func image(named name: String) -> CIImage? {
        self.lock.lock()
        if let image = self.cache[name] {
            self.lock.unlock()
            return image
        }
        if self.missing.contains(name) {
            self.lock.unlock()
            return nil
        }
        self.lock.unlock()

        let url = self.directory.appendingPathComponent(GGMaskStore.safeComponent(name))
        let image = GGMaskAssets.load(url)

        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let image else {
            // Remembered: a missing file is not looked for again on every frame.
            self.missing.insert(name)
            return nil
        }
        self.cache[name] = image
        self.order.append(name)
        if self.order.count > 12 {
            let evicted = self.order.removeFirst()
            self.cache[evicted] = nil
        }
        return image
    }

    /// Up to 1280 px, the orientation applied, decoded into memory once (GIFs: the first frame).
    private static func load(_ url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }
}

/// A mask ready for rendering: its manifest and assets, resolved off the frame path.
final class GGPreparedMask {
    let selection: GGMaskSelection
    let manifest: GGMaskManifest
    let assets: GGMaskAssets?

    init(selection: GGMaskSelection, manifest: GGMaskManifest, assets: GGMaskAssets?) {
        self.selection = selection
        self.manifest = manifest
        self.assets = assets
    }
}

/// How far the governor has simplified each effect of the current mask (steps per effect index).
struct GGMaskDegradeState: Equatable {
    var steps: [Int: Int] = [:]

    /// The effects with every applied step; disabled ones are dropped.
    func apply(to effects: [GGMaskEffect]) -> [(effect: GGMaskEffect, scales: [String: Double], overrides: [String: GGMaskParamValue])] {
        var result: [(effect: GGMaskEffect, scales: [String: Double], overrides: [String: GGMaskParamValue])] = []
        for (index, effect) in effects.enumerated() {
            if !effect.isEnabled {
                continue
            }
            var scales: [String: Double] = [:]
            var overrides: [String: GGMaskParamValue] = [:]
            var disabled = false
            if let count = self.steps[index], count > 0, effect.type == .filter, let id = effect.filterId, let descriptor = GGFilterCatalog.descriptor(id) {
                for step in descriptor.degrade.prefix(count) {
                    switch step {
                    case let .scale(param, factor):
                        scales[param] = (scales[param] ?? 1.0) * factor
                    case let .set(param, value):
                        overrides[param] = value
                    case .disable:
                        disabled = true
                    }
                }
            }
            if !disabled {
                result.append((effect, scales, overrides))
            }
        }
        return result
    }
}

enum GGMaskRenderer {
    /// The whole chain over `source`, in order; every result is cropped to the frame.
    static func render(_ mask: GGPreparedMask, source: CIImage, frame: GGMaskFrame, degrade: GGMaskDegradeState) -> CIImage {
        var image = source
        for item in degrade.apply(to: mask.manifest.effects) {
            let input = image
            let output = GGMaskRenderer.render(item.effect, source: input, frame: frame, scales: item.scales, overrides: item.overrides)
            if let opacity = item.effect.opacity, opacity < 0.999, item.effect.type == .filter, GGFilterCatalog.descriptor(item.effect.filterId ?? "")?.param("opacity") == nil {
                image = GGMaskOps.mix(base: input, overlay: output, amount: opacity, extent: frame.extent)
            } else {
                image = output
            }
        }
        return image.cropped(to: frame.extent)
    }

    private static func render(_ effect: GGMaskEffect, source: CIImage, frame: GGMaskFrame, scales: [String: Double], overrides: [String: GGMaskParamValue]) -> CIImage {
        let extent = frame.extent
        let intensity = max(0.0, min(1.0, effect.intensity ?? 0.5))
        switch effect.type {
        case .filter:
            guard let id = effect.filterId, let descriptor = GGFilterCatalog.descriptor(id) else {
                return source
            }
            let context = GGFilterContext(source: source, frame: frame, effect: effect, descriptor: descriptor, scales: scales, overrides: overrides)
            return descriptor.render(context)
        case .blur:
            let anchor = effect.anchor ?? .face
            if anchor == .fullFrame {
                return GGMaskOps.blur(source, radius: intensity * 50.0 + 8.0, region: nil, extent: extent)
            }
            guard let rect = GGMaskOps.anchorRect(anchor, face: frame.face, extent: extent) else {
                return source
            }
            return GGMaskOps.blur(source, radius: intensity * 50.0 + 8.0, region: rect, extent: extent)
        case .pixelate:
            let anchor = effect.anchor ?? .face
            if anchor == .fullFrame {
                return GGMaskOps.pixelate(source, scale: intensity * 40.0 + 10.0, region: nil, extent: extent)
            }
            guard let rect = GGMaskOps.anchorRect(anchor, face: frame.face, extent: extent) else {
                return source
            }
            return GGMaskOps.pixelate(source, scale: intensity * 40.0 + 10.0, region: rect, extent: extent)
        case .sticker2d:
            guard let name = effect.asset, let image = frame.assets?.image(named: name), let rect = GGMaskOps.anchorRect(effect.anchor ?? .face, face: frame.face, extent: extent) else {
                return source
            }
            let offset = effect.offset ?? [0.0, 0.0]
            let rotation: CGFloat = (effect.anchor ?? .face) != .fullFrame ? (frame.face?.roll ?? 0.0) : 0.0
            let placed = GGMaskOps.layer(image, in: rect, scale: effect.scale ?? 1.0, offset: CGPoint(x: offset.first ?? 0.0, y: offset.count > 1 ? offset[1] : 0.0), rotation: rotation, fill: false)
            return placed.cropped(to: extent).composited(over: source).cropped(to: extent)
        case .colorFilter:
            return GGMaskRenderer.colorPreset(effect.preset ?? .noir, source: source, extent: extent)
        case .backgroundReplace:
            guard let mask = frame.segmentation else {
                return source
            }
            let background: CIImage
            switch effect.backgroundMode ?? "blur" {
            case "color":
                let rgba = effect.backgroundColor.flatMap(ggParseHexColor) ?? (0.0, 0.0, 0.0, 1.0)
                background = CIImage(color: CIColor(red: rgba.r, green: rgba.g, blue: rgba.b)).cropped(to: extent)
            case "image", "gif":
                guard let name = effect.backgroundAsset, let image = frame.assets?.image(named: name) else {
                    return source
                }
                background = GGMaskOps.layer(image, in: extent, scale: 1.0, offset: .zero, rotation: 0.0, fill: true).cropped(to: extent)
            default:
                background = GGMaskOps.blur(source, radius: intensity * 30.0 + 6.0, region: nil, extent: extent)
            }
            return GGMaskOps.masked(source, over: background, mask: mask, extent: extent)
        case .glitchRGB:
            return GGMaskOps.rgbSplit(source, offset: CGFloat(intensity * 12.0 + 2.0), angle: 0.0, extent: extent)
        case .faceDistort:
            guard let face = frame.face else {
                return source
            }
            let center = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
            let radius = max(face.bounds.width, face.bounds.height) * 0.6
            let region = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
            let kind = effect.distortKind ?? .bulge
            return GGMaskOps.withinRegion(source, region: region, pad: radius * 0.3, extent: extent) { input in
                let centerVector = CIVector(x: center.x, y: center.y)
                switch kind {
                case .bulge:
                    return GGMaskOps.apply("CIBumpDistortion", input, [kCIInputCenterKey: centerVector, kCIInputRadiusKey: radius, kCIInputScaleKey: intensity], clamp: false, extent: extent)
                case .pinch:
                    return GGMaskOps.apply("CIPinchDistortion", input, [kCIInputCenterKey: centerVector, kCIInputRadiusKey: radius, kCIInputScaleKey: intensity], clamp: false, extent: extent)
                case .twirl:
                    return GGMaskOps.apply("CITwirlDistortion", input, [kCIInputCenterKey: centerVector, kCIInputRadiusKey: radius, kCIInputAngleKey: Double.pi * intensity], clamp: false, extent: extent)
                }
            }
        case .emojiHead:
            guard let rect = GGMaskOps.anchorRect(effect.anchor ?? .face, face: frame.face, extent: extent) else {
                return source
            }
            return GGMaskOps.emojiHead(source, emoji: effect.emoji ?? "🙂", rect: rect, extent: extent)
        }
    }

    static func colorPreset(_ preset: GGMaskColorPreset, source: CIImage, extent: CGRect) -> CIImage {
        switch preset {
        case .sepia:
            return GGMaskOps.apply("CISepiaTone", source, [kCIInputIntensityKey: 0.9], clamp: false, extent: extent)
        case .noir:
            return GGMaskOps.apply("CIPhotoEffectNoir", source, [:], clamp: false, extent: extent)
        case .chrome:
            return GGMaskOps.apply("CIPhotoEffectChrome", source, [:], clamp: false, extent: extent)
        case .fade:
            return GGMaskOps.apply("CIPhotoEffectFade", source, [:], clamp: false, extent: extent)
        case .warm:
            return GGMaskOps.apply("CITemperatureAndTint", source, ["inputNeutral": CIVector(x: 6500.0, y: 0.0), "inputTargetNeutral": CIVector(x: 5500.0, y: 0.0)], clamp: false, extent: extent)
        case .cold:
            return GGMaskOps.apply("CITemperatureAndTint", source, ["inputNeutral": CIVector(x: 6500.0, y: 0.0), "inputTargetNeutral": CIVector(x: 8500.0, y: 0.0)], clamp: false, extent: extent)
        case .vhs:
            let noir = GGMaskOps.apply("CIPhotoEffectNoir", source, [:], clamp: false, extent: extent)
            return GGMaskOps.rgbSplit(noir, offset: 4.0, angle: 0.0, extent: extent)
        }
    }
}

/// Static cost of a mask for the studio: budget units, the expected frame rate, and what breaks
/// the structural limits. 60 units fit a 30 fps frame; from 42 the mask is «getting heavy».
struct GGMaskBudget {
    enum Violation: Equatable {
        case tooManyEffects(Int)
        case tooManyHeavy
        case tooManySegmentation
        case tooManyFaceWarps
        case tooManyAnimated
        case overBudget
    }

    static let maximumUnits = 60
    static let warningUnits = 42
    static let maximumEffects = 12

    let units: Int
    let violations: [Violation]

    var estimatedFps: Int {
        let fps = min(30.0, 1000.0 / (16.0 + 0.25 * Double(self.units)))
        return max(5, Int(fps / 5.0) * 5)
    }

    var isWarning: Bool {
        return self.units >= GGMaskBudget.warningUnits && self.units <= GGMaskBudget.maximumUnits
    }

    static func evaluate(_ effects: [GGMaskEffect]) -> GGMaskBudget {
        let active = effects.filter { $0.isEnabled }
        var units = 0
        var heavy = 0
        var segmentation = 0
        var faceWarps = 0
        var animated = 0
        var previousFused = false
        var needs = GGVisionNeeds()
        for effect in active {
            needs.formUnion(GGFilterCatalog.visionNeeds(of: effect))
            let cost = GGMaskBudget.cost(of: effect)
            if let id = effect.filterId, effect.type == .filter, let descriptor = GGFilterCatalog.descriptor(id) {
                if descriptor.fuses {
                    units += previousFused ? max(1, Int(Double(cost) * 0.2)) : cost
                    previousFused = true
                } else {
                    units += cost
                    previousFused = false
                }
                if descriptor.isHeavy {
                    heavy += 1
                }
                if descriptor.needs.contains(.segmentation) {
                    segmentation += 1
                }
                if descriptor.category == .face && descriptor.id != "face.sticker" {
                    faceWarps += 1
                }
                if descriptor.isAnimated {
                    animated += 1
                }
            } else {
                units += cost
                previousFused = false
                if effect.type == .backgroundReplace {
                    segmentation += 1
                    heavy += 1
                }
            }
        }
        if needs.contains(.face) {
            units += 12
        }
        if needs.contains(.landmarks) {
            units += 16
        }
        if needs.contains(.segmentation) {
            units += 14
        }
        var violations: [Violation] = []
        if active.count > GGMaskBudget.maximumEffects {
            violations.append(.tooManyEffects(GGMaskBudget.maximumEffects))
        }
        if heavy > 2 {
            violations.append(.tooManyHeavy)
        }
        if segmentation > 1 {
            violations.append(.tooManySegmentation)
        }
        if faceWarps > 4 {
            violations.append(.tooManyFaceWarps)
        }
        if animated > 1 {
            violations.append(.tooManyAnimated)
        }
        if units > GGMaskBudget.maximumUnits {
            violations.append(.overBudget)
        }
        return GGMaskBudget(units: units, violations: violations)
    }

    static func cost(of effect: GGMaskEffect) -> Int {
        switch effect.type {
        case .filter:
            return effect.filterId.flatMap { GGFilterCatalog.descriptor($0)?.cost } ?? 0
        case .blur:
            return effect.anchor == .fullFrame ? 12 : 5
        case .pixelate:
            return effect.anchor == .fullFrame ? 5 : 4
        case .colorFilter:
            return 2
        case .sticker2d:
            return 3
        case .emojiHead:
            return 2
        case .glitchRGB:
            return 5
        case .faceDistort:
            return 6
        case .backgroundReplace:
            return 16
        }
    }

    /// Whether one more effect fits (the studio greys out what would break the mask).
    static func canAppend(_ effect: GGMaskEffect, to effects: [GGMaskEffect]) -> Bool {
        let before = GGMaskBudget.evaluate(effects)
        let after = GGMaskBudget.evaluate(effects + [effect])
        // Never make the mask break a limit it did not break already.
        for violation in after.violations where !before.violations.contains(violation) {
            return false
        }
        return true
    }
}
