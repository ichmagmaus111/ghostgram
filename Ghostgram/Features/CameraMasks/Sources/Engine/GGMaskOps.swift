import Foundation
import UIKit
import CoreImage

/// What every effect of one frame shares: the frame's extent and time, the face and the person
/// mask (both resolved lazily, at most once per frame, and only if an effect asks), the mask's
/// assets.
final class GGMaskFrame {
    let extent: CGRect
    let time: Double
    let assets: GGMaskAssets?
    private let faceProvider: () -> GGFaceGeometry?
    private let segmentationProvider: () -> CIImage?
    private var resolvedFace: GGFaceGeometry??
    private var resolvedSegmentation: CIImage??

    init(extent: CGRect, time: Double, assets: GGMaskAssets?, face: @escaping () -> GGFaceGeometry?, segmentation: @escaping () -> CIImage?) {
        self.extent = extent
        self.time = time
        self.assets = assets
        self.faceProvider = face
        self.segmentationProvider = segmentation
    }

    var face: GGFaceGeometry? {
        if let resolved = self.resolvedFace {
            return resolved
        }
        let value = self.faceProvider()
        self.resolvedFace = .some(value)
        return value
    }

    var segmentation: CIImage? {
        if let resolved = self.resolvedSegmentation {
            return resolved
        }
        let value = self.segmentationProvider()
        self.resolvedSegmentation = .some(value)
        return value
    }

    var shortSide: CGFloat {
        return min(self.extent.width, self.extent.height)
    }
}

/// Parameters of one effect for one frame, with the governor's simplifications applied.
struct GGFilterContext {
    let source: CIImage
    let frame: GGMaskFrame
    let effect: GGMaskEffect
    let descriptor: GGFilterDescriptor?
    /// Multipliers the governor applies to numeric parameters (by parameter id).
    let scales: [String: Double]
    /// Values the governor forces (by parameter id).
    let overrides: [String: GGMaskParamValue]

    var extent: CGRect {
        return self.frame.extent
    }

    private func value(_ id: String) -> GGMaskParamValue? {
        if let value = self.overrides[id] {
            return value
        }
        if let value = self.effect.params?[id], value != .unknown {
            return value
        }
        return self.descriptor?.param(id)?.defaultValue
    }

    func number(_ id: String) -> Double {
        let raw = self.value(id)?.number ?? 0.0
        if let scale = self.scales[id] {
            return raw * scale
        }
        return raw
    }

    func bool(_ id: String) -> Bool {
        return self.value(id)?.bool ?? false
    }

    func text(_ id: String) -> String {
        return self.value(id)?.text ?? ""
    }

    func numbers(_ id: String) -> [Double] {
        return self.value(id)?.numbers ?? []
    }

    func color(_ id: String) -> CIColor {
        if let text = self.value(id)?.text, let rgba = ggParseHexColor(text) {
            return CIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        }
        return CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    }

    /// A normalized point parameter (origin bottom-left) in frame pixels.
    func point(_ id: String) -> CIVector {
        let point = self.value(id)?.point ?? CGPoint(x: 0.5, y: 0.5)
        return CIVector(x: self.extent.minX + point.x * self.extent.width, y: self.extent.minY + point.y * self.extent.height)
    }

    /// A parameter given as a share of the frame's short side, in pixels.
    func fraction(_ id: String) -> Double {
        return self.number(id) * Double(self.frame.shortSide)
    }

    var center: CIVector {
        return CIVector(x: self.extent.midX, y: self.extent.midY)
    }

    var face: GGFaceGeometry? {
        return self.frame.face
    }

    var anchor: GGMaskAnchor {
        return self.effect.effectiveAnchor ?? .face
    }

    func image(_ name: String?) -> CIImage? {
        guard let name, !name.isEmpty else {
            return nil
        }
        return self.frame.assets?.image(named: name)
    }

    /// Runs a Core Image filter on the source (optionally clamped so edges do not darken).
    func apply(_ name: String, _ parameters: [String: Any] = [:], clamp: Bool = false, input: CIImage? = nil) -> CIImage {
        return GGMaskOps.apply(name, input ?? self.source, parameters, clamp: clamp, extent: self.extent)
    }
}

enum GGMaskOps {
    static func apply(_ name: String, _ image: CIImage, _ parameters: [String: Any], clamp: Bool, extent: CGRect) -> CIImage {
        guard let filter = CIFilter(name: name) else {
            return image
        }
        let input = clamp ? image.clampedToExtent() : image
        if filter.inputKeys.contains(kCIInputImageKey) {
            filter.setValue(input, forKey: kCIInputImageKey)
        }
        for (key, value) in parameters {
            filter.setValue(value, forKey: key)
        }
        guard let output = filter.outputImage else {
            return image
        }
        return output.cropped(to: extent)
    }

    /// A generator (sunbeams, halo…): its output composited with `compositeFilter` over the image.
    static func composite(_ generated: CIImage?, over image: CIImage, filter compositeName: String, extent: CGRect) -> CIImage {
        guard let generated, let filter = CIFilter(name: compositeName) else {
            return image
        }
        filter.setValue(generated.cropped(to: extent), forKey: kCIInputImageKey)
        filter.setValue(image, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// `overlay` over `base` with its alpha scaled by `amount` (0 = base, 1 = overlay).
    static func mix(base: CIImage, overlay: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let clamped = max(0.0, min(1.0, amount))
        if clamped >= 0.999 {
            return overlay
        }
        if clamped <= 0.001 {
            return base
        }
        let faded = overlay.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: CGFloat(clamped))])
        return faded.composited(over: base).cropped(to: extent)
    }

    /// A layer blended over the base with a blend mode and an opacity.
    static func blend(layer: CIImage, over base: CIImage, mode: GGMaskBlendMode, opacity: Double, extent: CGRect) -> CIImage {
        var top = layer
        if opacity < 0.999 {
            top = top.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: CGFloat(max(0.0, opacity)))])
        }
        guard let filter = CIFilter(name: mode.filterName) else {
            return top.composited(over: base)
        }
        filter.setValue(top, forKey: kCIInputImageKey)
        filter.setValue(base, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage?.cropped(to: extent) ?? base
    }

    /// White inside `innerRadius`, fading to black at `outerRadius`.
    static func radialMask(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat, extent: CGRect) -> CIImage {
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": max(0.0, innerRadius),
            "inputRadius1": max(innerRadius + 1.0, outerRadius),
            "inputColor0": CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            "inputColor1": CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ])
        return gradient?.outputImage?.cropped(to: extent) ?? CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0)).cropped(to: extent)
    }

    /// A soft ellipse mask: a radial mask stretched to the ellipse and rotated.
    static func ellipseMask(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, feather: CGFloat, rotation: CGFloat, extent: CGRect) -> CIImage {
        let base = max(1.0, radiusX)
        let inner = base * max(0.0, 1.0 - feather)
        let mask = GGMaskOps.radialMask(center: .zero, innerRadius: inner, outerRadius: base, extent: CGRect(x: -base * 2.0, y: -base * 2.0, width: base * 4.0, height: base * 4.0))
        let transform = CGAffineTransform(scaleX: 1.0, y: max(0.01, radiusY / base)).concatenating(CGAffineTransform(rotationAngle: rotation)).concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        let black = CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0)).cropped(to: extent)
        return mask.transformed(by: transform).composited(over: black).cropped(to: extent)
    }

    /// `effect` inside the mask (white), `base` outside.
    static func masked(_ effect: CIImage, over base: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        return effect.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
    }

    /// Runs `process` only inside `region` (padded): cheap local warps.
    static func withinRegion(_ source: CIImage, region: CGRect, pad: CGFloat, extent: CGRect, _ process: (CIImage) -> CIImage) -> CIImage {
        let roi = region.insetBy(dx: -pad, dy: -pad).intersection(extent)
        if roi.isNull || roi.isEmpty {
            return source
        }
        let processed = process(source.clampedToExtent().cropped(to: roi)).cropped(to: roi)
        return processed.composited(over: source).cropped(to: extent)
    }

    /// Gaussian blur of the whole frame, or of a soft circle around a region.
    static func blur(_ source: CIImage, radius: Double, region: CGRect?, extent: CGRect) -> CIImage {
        guard let region else {
            return source.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        let inner = hypot(region.width, region.height) / 2.0
        let feather = max(region.width, region.height) * 0.18
        let reach = inner + feather + CGFloat(radius) * 3.0 + 1.0
        let roi = CGRect(x: region.midX - reach, y: region.midY - reach, width: reach * 2.0, height: reach * 2.0).intersection(extent)
        let blurred = source.clampedToExtent().cropped(to: roi.insetBy(dx: -CGFloat(radius) * 3.0, dy: -CGFloat(radius) * 3.0)).applyingGaussianBlur(sigma: radius).cropped(to: roi)
        let mask = GGMaskOps.radialMask(center: CGPoint(x: region.midX, y: region.midY), innerRadius: inner, outerRadius: inner + feather, extent: extent)
        return GGMaskOps.masked(blurred.composited(over: source), over: source, mask: mask, extent: extent)
    }

    /// Pixelation of the whole frame, or of a soft circle around a region.
    static func pixelate(_ source: CIImage, scale: Double, region: CGRect?, extent: CGRect) -> CIImage {
        let pixelated = GGMaskOps.apply("CIPixellate", source, [kCIInputScaleKey: max(2.0, scale), kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)], clamp: true, extent: extent)
        guard let region else {
            return pixelated
        }
        let inner = hypot(region.width, region.height) / 2.0 * 0.95
        let feather = max(region.width, region.height) * 0.18
        let mask = GGMaskOps.radialMask(center: CGPoint(x: region.midX, y: region.midY), innerRadius: inner, outerRadius: inner + feather, extent: extent)
        return GGMaskOps.masked(pixelated, over: source, mask: mask, extent: extent)
    }

    /// Where an anchored element goes. nil = no face (the element is not drawn this frame).
    static func anchorRect(_ anchor: GGMaskAnchor, face: GGFaceGeometry?, extent: CGRect) -> CGRect? {
        if anchor == .fullFrame {
            return extent
        }
        guard let face else {
            return nil
        }
        let f = face.bounds
        func fallback(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            return CGRect(x: f.minX + x * f.width, y: f.minY + y * f.height, width: w * f.width, height: h * f.height)
        }
        let landmarks = face.landmarks
        switch anchor {
        case .fullFrame:
            return extent
        case .face:
            return f
        case .eyes:
            if let landmarks, let left = ggBounds(landmarks.leftEye), let right = ggBounds(landmarks.rightEye) {
                let union = left.union(right)
                return union.insetBy(dx: -union.width * 0.25, dy: -union.height * 0.6)
            }
            return fallback(0.0, 0.55, 1.0, 0.25)
        case .leftEye, .rightEye:
            let points = anchor == .leftEye ? landmarks?.leftEye : landmarks?.rightEye
            if let points, let rect = ggBounds(points) {
                return rect.insetBy(dx: -rect.width * 0.4, dy: -rect.height * 0.9)
            }
            return anchor == .leftEye ? fallback(0.10, 0.56, 0.32, 0.20) : fallback(0.58, 0.56, 0.32, 0.20)
        case .nose:
            if let landmarks, let rect = ggBounds(landmarks.nose) {
                return rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.2)
            }
            return fallback(0.35, 0.40, 0.30, 0.25)
        case .mouth:
            if let landmarks, let rect = ggBounds(landmarks.outerLips) {
                return rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.35)
            }
            return fallback(0.25, 0.10, 0.50, 0.20)
        case .forehead:
            if let landmarks, let brows = ggBounds(landmarks.leftEyebrow + landmarks.rightEyebrow) {
                let x = brows.midX
                let y = brows.maxY + f.height * 0.12
                return CGRect(x: x - f.width * 0.4, y: y - f.height * 0.10, width: f.width * 0.8, height: f.height * 0.28)
            }
            return fallback(0.10, 0.78, 0.80, 0.28)
        case .chin:
            if let landmarks, let chin = landmarks.chinPoint {
                return CGRect(x: chin.x - f.width * 0.28, y: chin.y - f.height * 0.12, width: f.width * 0.56, height: f.height * 0.24)
            }
            return fallback(0.22, -0.06, 0.56, 0.24)
        }
    }

    /// An image placed over an anchor rect: scaled to the rect's longer side (or cover-filled),
    /// moved by `offset` (shares of the rect), rotated about its centre.
    static func layer(_ image: CIImage, in rect: CGRect, scale: Double, offset: CGPoint, rotation: CGFloat, fill: Bool) -> CIImage {
        let imageSize = image.extent.size
        guard imageSize.width > 0.0, imageSize.height > 0.0 else {
            return image
        }
        let factor: CGFloat
        if fill {
            factor = max(rect.width / imageSize.width, rect.height / imageSize.height) * CGFloat(scale)
        } else {
            let base = max(rect.width, rect.height) * CGFloat(scale)
            factor = base / imageSize.height
        }
        let center = CGPoint(x: rect.midX + offset.x * rect.width, y: rect.midY + offset.y * rect.height)
        let transform = CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return image.transformed(by: transform)
    }

    // MARK: Emoji glyphs (rendered once, 512²)

    private static let emojiLock = NSLock()
    private static var emojiCache: [String: CIImage] = [:]

    static func emojiImage(_ emoji: String) -> CIImage? {
        let glyph = emoji.isEmpty ? "🙂" : String(emoji.prefix(2))
        GGMaskOps.emojiLock.lock()
        if let cached = GGMaskOps.emojiCache[glyph] {
            GGMaskOps.emojiLock.unlock()
            return cached
        }
        GGMaskOps.emojiLock.unlock()
        let side: CGFloat = 512.0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: side * 0.85)]
            let text = glyph as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (side - size.width) / 2.0, y: (side - size.height) / 2.0), withAttributes: attributes)
        }
        guard let cgImage = rendered.cgImage else {
            return nil
        }
        let image = CIImage(cgImage: cgImage)
        GGMaskOps.emojiLock.lock()
        if GGMaskOps.emojiCache.count > 32 {
            GGMaskOps.emojiCache.removeAll()
        }
        GGMaskOps.emojiCache[glyph] = image
        GGMaskOps.emojiLock.unlock()
        return image
    }

    /// The emoji as a square of the face's longer side ×1.2 over the face rect.
    static func emojiHead(_ source: CIImage, emoji: String, rect: CGRect, extent: CGRect) -> CIImage {
        guard let glyph = GGMaskOps.emojiImage(emoji) else {
            return source
        }
        let side = max(rect.width, rect.height) * 1.2
        let factor = side / glyph.extent.width
        let transform = CGAffineTransform(scaleX: factor, y: factor).concatenating(CGAffineTransform(translationX: rect.midX - side / 2.0, y: rect.midY - side / 2.0))
        return glyph.transformed(by: transform).composited(over: source).cropped(to: extent)
    }

    /// R shifted one way, B the other, G in place; recombined additively.
    static func rgbSplit(_ source: CIImage, offset: CGFloat, angle: CGFloat, extent: CGRect) -> CIImage {
        if offset < 0.5 {
            return source
        }
        let dx = cos(angle) * offset
        let dy = sin(angle) * offset
        let clamped = source.clampedToExtent()
        let red = clamped.transformed(by: CGAffineTransform(translationX: dx, y: dy)).applyingFilter("CIColorMatrix", parameters: [
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let green = clamped.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let blue = clamped.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let redGreen = red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
        return blue.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: redGreen]).cropped(to: extent)
    }

    /// Horizontal stripes multiplied over the frame.
    static func scanlines(_ source: CIImage, width: Double, sharpness: Double, opacity: Double, extent: CGRect) -> CIImage {
        guard let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1.0, green: 1.0, blue: 1.0),
            "inputColor1": CIColor(red: 0.0, green: 0.0, blue: 0.0),
            "inputWidth": max(1.0, width),
            "inputSharpness": max(0.0, min(1.0, sharpness))
        ])?.outputImage else {
            return source
        }
        let rotated = stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 2.0)).cropped(to: extent)
        let multiplied = rotated.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: source]).cropped(to: extent)
        return GGMaskOps.mix(base: source, overlay: multiplied, amount: opacity, extent: extent)
    }

    private static let noiseLock = NSLock()
    private static var noiseTile: CIImage?

    /// A cached 256² grey noise tile.
    static func noise() -> CIImage {
        GGMaskOps.noiseLock.lock()
        defer {
            GGMaskOps.noiseLock.unlock()
        }
        if let tile = GGMaskOps.noiseTile {
            return tile
        }
        let random = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        let grey = random.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0 / 3.0, y: 1.0 / 3.0, z: 1.0 / 3.0, w: 0.0),
            "inputGVector": CIVector(x: 1.0 / 3.0, y: 1.0 / 3.0, z: 1.0 / 3.0, w: 0.0),
            "inputBVector": CIVector(x: 1.0 / 3.0, y: 1.0 / 3.0, z: 1.0 / 3.0, w: 0.0),
            "inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0),
            "inputBiasVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
        ]).cropped(to: CGRect(x: 0.0, y: 0.0, width: 256.0, height: 256.0))
        let tile = grey.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSValue(cgAffineTransform: .identity)])
        GGMaskOps.noiseTile = tile
        return tile
    }
}
