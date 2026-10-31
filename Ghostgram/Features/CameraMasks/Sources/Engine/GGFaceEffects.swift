import Foundation
import UIKit
import CoreImage

/// Effects built on face landmarks. Warps run only inside a padded region around the feature,
/// so they cost a fraction of a full-frame pass.
enum GGFaceEffects {
    // MARK: Geometry

    static func eyes(_ c: GGFilterContext, amount: Double) -> CIImage {
        guard let face = c.face, abs(amount) > 0.001 else {
            return c.source
        }
        let reference = face.interEyeDistance
        let radius = max(reference * CGFloat(c.number("radius")) * 0.5, 6.0)
        var image = c.source
        let centers = [face.landmarks?.leftEyeCenter, face.landmarks?.rightEyeCenter].compactMap { $0 }
        for center in centers {
            let region = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
            image = GGMaskOps.withinRegion(image, region: region, pad: radius * 0.5, extent: c.extent) { input in
                return GGMaskOps.apply("CIBumpDistortion", input, [kCIInputCenterKey: CIVector(x: center.x, y: center.y), kCIInputRadiusKey: radius, kCIInputScaleKey: amount], clamp: false, extent: c.extent)
            }
        }
        return image
    }

    /// Positive = slimmer (pinch the cheeks), negative = wider (bulge them).
    static func width(_ c: GGFilterContext, amount: Double) -> CIImage {
        guard let face = c.face, abs(amount) > 0.001 else {
            return c.source
        }
        let bounds = face.bounds
        var leftPoint = CGPoint(x: bounds.minX, y: bounds.midY - bounds.height * 0.1)
        var rightPoint = CGPoint(x: bounds.maxX, y: bounds.midY - bounds.height * 0.1)
        if let contour = face.landmarks?.faceContour, let minPoint = contour.min(by: { $0.x < $1.x }), let maxPoint = contour.max(by: { $0.x < $1.x }) {
            leftPoint = minPoint
            rightPoint = maxPoint
        }
        let radius = max(bounds.width * 0.42, 8.0)
        let filterName = amount > 0.0 ? "CIPinchDistortion" : "CIBumpDistortion"
        let strength = amount > 0.0 ? amount : -amount * 0.6
        var image = c.source
        for center in [leftPoint, rightPoint] {
            let region = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
            image = GGMaskOps.withinRegion(image, region: region, pad: radius * 0.3, extent: c.extent) { input in
                return GGMaskOps.apply(filterName, input, [kCIInputCenterKey: CIVector(x: center.x, y: center.y), kCIInputRadiusKey: radius, kCIInputScaleKey: strength], clamp: false, extent: c.extent)
            }
        }
        return image
    }

    static func chin(_ c: GGFilterContext) -> CIImage {
        guard let face = c.face else {
            return c.source
        }
        let point = face.landmarks?.chinPoint ?? CGPoint(x: face.bounds.midX, y: face.bounds.minY)
        let radius = face.bounds.height * CGFloat(c.number("radius")) * 0.5
        let region = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2.0, height: radius * 2.0)
        return GGMaskOps.withinRegion(c.source, region: region, pad: radius * 0.4, extent: c.extent) { input in
            return GGMaskOps.apply("CIBumpDistortionLinear", input, [kCIInputCenterKey: CIVector(x: point.x, y: point.y), kCIInputRadiusKey: radius, kCIInputAngleKey: face.roll + .pi / 2.0, kCIInputScaleKey: c.number("amount")], clamp: false, extent: c.extent)
        }
    }

    static func nose(_ c: GGFilterContext) -> CIImage {
        guard let face = c.face else {
            return c.source
        }
        let points = face.landmarks?.nose ?? []
        let center = ggCentroid(points) ?? CGPoint(x: face.bounds.midX, y: face.bounds.midY)
        let width = ggBounds(points)?.width ?? face.bounds.width * 0.3
        return GGFaceEffects.bump(c, center: center, radius: width * CGFloat(c.number("radius")))
    }

    static func mouth(_ c: GGFilterContext) -> CIImage {
        guard let face = c.face else {
            return c.source
        }
        let points = face.landmarks?.outerLips ?? []
        let center = ggCentroid(points) ?? CGPoint(x: face.bounds.midX, y: face.bounds.minY + face.bounds.height * 0.2)
        let width = ggBounds(points)?.width ?? face.bounds.width * 0.4
        return GGFaceEffects.bump(c, center: center, radius: width * 0.75 * CGFloat(c.number("radius")))
    }

    private static func bump(_ c: GGFilterContext, center: CGPoint, radius: CGFloat) -> CIImage {
        let radius = max(radius, 6.0)
        let region = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
        return GGMaskOps.withinRegion(c.source, region: region, pad: radius * 0.4, extent: c.extent) { input in
            return GGMaskOps.apply("CIBumpDistortion", input, [kCIInputCenterKey: CIVector(x: center.x, y: center.y), kCIInputRadiusKey: radius, kCIInputScaleKey: c.number("amount")], clamp: false, extent: c.extent)
        }
    }

    // MARK: Skin

    /// The face ellipse mask (feathered).
    private static func faceMask(_ face: GGFaceGeometry, feather: CGFloat, expand: CGFloat, extent: CGRect) -> CIImage {
        let bounds = face.bounds
        return GGMaskOps.ellipseMask(center: CGPoint(x: bounds.midX, y: bounds.midY), radiusX: bounds.width * 0.5 * expand, radiusY: bounds.height * 0.58 * expand, feather: feather, rotation: face.roll, extent: extent)
    }

    static func skinSmooth(_ c: GGFilterContext) -> CIImage {
        guard let face = c.face else {
            return c.source
        }
        let amount = c.number("amount")
        if amount < 0.001 {
            return c.source
        }
        let bounds = face.bounds
        let radius = max(Double(bounds.width) * 0.02, 1.5)
        let region = bounds.insetBy(dx: -bounds.width * 0.15, dy: -bounds.height * 0.15).intersection(c.extent)
        if region.isNull || region.isEmpty {
            return c.source
        }
        let blurred = c.source.clampedToExtent().cropped(to: region.insetBy(dx: -CGFloat(radius) * 3.0, dy: -CGFloat(radius) * 3.0)).applyingGaussianBlur(sigma: radius).cropped(to: region)
        let sharpened = GGMaskOps.apply("CIUnsharpMask", blurred, [kCIInputRadiusKey: radius * 2.0, kCIInputIntensityKey: 0.25], clamp: false, extent: region)
        let smoothed = GGMaskOps.mix(base: c.source, overlay: sharpened.composited(over: c.source), amount: amount, extent: c.extent)
        var mask = GGFaceEffects.faceMask(face, feather: 0.35, expand: 1.05, extent: c.extent)
        if c.bool("keepDetail"), let landmarks = face.landmarks {
            var holes: [CIImage] = []
            let eyeRadius = face.interEyeDistance * 0.30
            for center in [landmarks.leftEyeCenter, landmarks.rightEyeCenter].compactMap({ $0 }) {
                holes.append(GGMaskOps.ellipseMask(center: center, radiusX: eyeRadius, radiusY: eyeRadius * 0.75, feather: 0.5, rotation: face.roll, extent: c.extent))
            }
            if let lips = ggBounds(landmarks.outerLips) {
                holes.append(GGMaskOps.ellipseMask(center: CGPoint(x: lips.midX, y: lips.midY), radiusX: lips.width * 0.75, radiusY: lips.height * 0.9, feather: 0.5, rotation: face.roll, extent: c.extent))
            }
            if var combined = holes.first {
                for hole in holes.dropFirst() {
                    combined = hole.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: combined])
                }
                let inverted = combined.applyingFilter("CIColorInvert")
                mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: inverted]).cropped(to: c.extent)
            }
        }
        return GGMaskOps.masked(smoothed, over: c.source, mask: mask, extent: c.extent)
    }

    static func skinTone(_ c: GGFilterContext) -> CIImage {
        guard let face = c.face else {
            return c.source
        }
        let warmth = c.number("warmth")
        let evenness = c.number("evenness")
        var toned = c.apply("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500.0, y: 0.0), "inputTargetNeutral": CIVector(x: CGFloat(6500.0 - warmth * 1200.0), y: 0.0)])
        toned = GGMaskOps.apply("CIColorControls", toned, [kCIInputSaturationKey: 1.0 - 0.25 * evenness, kCIInputContrastKey: 1.0 - 0.1 * evenness, kCIInputBrightnessKey: 0.03 * evenness], clamp: false, extent: c.extent)
        let mask = GGFaceEffects.faceMask(face, feather: 0.4, expand: 1.0, extent: c.extent)
        return GGMaskOps.masked(toned, over: c.source, mask: mask, extent: c.extent)
    }

    static func lipstick(_ c: GGFilterContext) -> CIImage {
        guard let face = c.face, let lips = face.landmarks?.outerLips, lips.count >= 3, let bounds = ggBounds(lips) else {
            return c.source
        }
        let padded = bounds.insetBy(dx: -bounds.width * 0.2, dy: -bounds.height * 0.5)
        guard let mask = GGFaceEffects.polygonMask(lips, in: padded, extent: c.extent) else {
            return c.source
        }
        let tint = CIImage(color: c.color("color")).cropped(to: c.extent).applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: c.source]).cropped(to: c.extent)
        let gloss = c.number("gloss")
        let glossy = GGMaskOps.apply("CIColorControls", tint, [kCIInputBrightnessKey: 0.12 * gloss, kCIInputContrastKey: 1.0 + 0.25 * gloss], clamp: false, extent: c.extent)
        let tinted = GGMaskOps.mix(base: c.source, overlay: glossy, amount: c.number("opacity"), extent: c.extent)
        return GGMaskOps.masked(tinted, over: c.source, mask: mask, extent: c.extent)
    }

    /// A soft mask of a polygon, rasterized at 128 px on the CPU and scaled into place.
    private static func polygonMask(_ points: [CGPoint], in rect: CGRect, extent: CGRect) -> CIImage? {
        let side: CGFloat = 128.0
        guard rect.width > 1.0, rect.height > 1.0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(x: 0.0, y: 0.0, width: side, height: side))
            cg.setFillColor(UIColor.white.cgColor)
            for (index, point) in points.enumerated() {
                // Core Image y-up → UIKit y-down.
                let mapped = CGPoint(x: (point.x - rect.minX) / rect.width * side, y: side - (point.y - rect.minY) / rect.height * side)
                if index == 0 {
                    cg.move(to: mapped)
                } else {
                    cg.addLine(to: mapped)
                }
            }
            cg.closePath()
            cg.fillPath()
        }
        guard let cgImage = image.cgImage else {
            return nil
        }
        let blurred = CIImage(cgImage: cgImage).clampedToExtent().applyingGaussianBlur(sigma: max(side * 0.35 * 0.15, 1.0)).cropped(to: CGRect(x: 0.0, y: 0.0, width: side, height: side))
        let placed = blurred.transformed(by: CGAffineTransform(scaleX: rect.width / side, y: rect.height / side).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        let black = CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0)).cropped(to: extent)
        return placed.composited(over: black).cropped(to: extent)
    }

    // MARK: Images

    /// The user's photo over the face: sized by the eye distance, centred between the eyes,
    /// optionally colour-matched to the light around the face, with a soft oval edge.
    static func swapImage(_ c: GGFilterContext) -> CIImage {
        guard let face = c.face, let photo = c.image(c.effect.asset) else {
            return c.source
        }
        let landmarks = face.landmarks
        let width = (landmarks != nil ? face.interEyeDistance * 2.35 : face.bounds.width) * CGFloat(c.number("scale"))
        let height = width * photo.extent.height / max(1.0, photo.extent.width)
        var center = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
        if let landmarks, let left = landmarks.leftEyeCenter, let right = landmarks.rightEyeCenter {
            center = CGPoint(x: (left.x + right.x) / 2.0, y: (left.y + right.y) / 2.0 - height * 0.10)
        }
        center.x += CGFloat(c.number("offsetX")) * width
        center.y += CGFloat(c.number("offsetY")) * height
        let rotation = c.bool("followRoll") ? face.roll : 0.0
        let factor = width / max(1.0, photo.extent.width)
        var placed = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.midX, y: -photo.extent.midY)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        let colorMatch = c.number("colorMatch")
        if colorMatch > 0.01 {
            let region = face.bounds.insetBy(dx: -face.bounds.width * 0.1, dy: -face.bounds.height * 0.1).intersection(c.extent)
            let ambient = c.source.clampedToExtent().applyingGaussianBlur(sigma: Double(max(face.bounds.width * 0.25, 4.0))).cropped(to: region)
            let matched = ambient.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: placed]).cropped(to: placed.extent)
            placed = GGMaskOps.mix(base: placed, overlay: matched, amount: colorMatch, extent: placed.extent)
        }
        let feather = CGFloat(max(0.02, min(0.9, c.number("feather"))))
        let mask = GGMaskOps.ellipseMask(center: center, radiusX: width * 0.46, radiusY: height * 0.52, feather: feather, rotation: rotation, extent: c.extent)
        let cut = GGMaskOps.masked(placed, over: CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)).cropped(to: c.extent), mask: mask, extent: c.extent)
        let mode = GGMaskBlendMode(rawValue: c.text("blendMode")) ?? .normal
        return GGMaskOps.blend(layer: cut, over: c.source, mode: mode, opacity: c.number("opacity"), extent: c.extent)
    }

    /// A sticker on a face anchor, turning with the head.
    static func sticker(_ c: GGFilterContext) -> CIImage {
        guard let image = c.image(c.effect.asset), let rect = GGMaskOps.anchorRect(c.anchor, face: c.face, extent: c.extent) else {
            return c.source
        }
        var rotation = CGFloat(c.number("rotation"))
        if c.bool("rotateWithHead"), let face = c.face {
            rotation += face.roll
        }
        let placed = GGMaskOps.layer(image, in: rect, scale: c.number("scale"), offset: CGPoint(x: c.number("offsetX"), y: c.number("offsetY")), rotation: rotation, fill: false)
        let mode = GGMaskBlendMode(rawValue: c.text("blendMode")) ?? .normal
        return GGMaskOps.blend(layer: placed.cropped(to: c.extent), over: c.source, mode: mode, opacity: c.number("opacity"), extent: c.extent)
    }

    /// An image layer over the frame or a face anchor.
    static func imageLayer(_ c: GGFilterContext) -> CIImage {
        let anchor = c.effect.effectiveAnchor ?? .fullFrame
        guard let image = c.image(c.effect.asset), let rect = GGMaskOps.anchorRect(anchor, face: c.face, extent: c.extent) else {
            return c.source
        }
        var rotation = CGFloat(c.number("rotation"))
        if c.bool("rotateWithHead"), anchor != .fullFrame, let face = c.face {
            rotation += face.roll
        }
        let placed = GGMaskOps.layer(image, in: rect, scale: c.number("scale"), offset: CGPoint(x: c.number("offsetX"), y: c.number("offsetY")), rotation: rotation, fill: c.bool("fill"))
        let mode = GGMaskBlendMode(rawValue: c.text("blendMode")) ?? .normal
        return GGMaskOps.blend(layer: placed.cropped(to: c.extent), over: c.source, mode: mode, opacity: c.number("opacity"), extent: c.extent)
    }
}
