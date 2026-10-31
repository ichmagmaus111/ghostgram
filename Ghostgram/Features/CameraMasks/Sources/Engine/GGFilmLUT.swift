import Foundation
import CoreImage

/// Film looks as 16³ colour cubes generated from a few numbers (no LUT files). A cube is built once
/// per look and cached; the strength of a look is a cross-fade with the source, so moving the
/// intensity slider never rebuilds a cube.
struct GGFilmLook: Equatable {
    var exposure: Double = 0.0
    var contrast: Double = 1.0
    var saturation: Double = 1.0
    var lift: [Double] = [0.0, 0.0, 0.0]
    var gamma: [Double] = [1.0, 1.0, 1.0]
    var gain: [Double] = [1.0, 1.0, 1.0]
    var shadowTint: [Double] = [0.0, 0.0, 0.0]
    var highlightTint: [Double] = [1.0, 1.0, 1.0]
    var split: Double = 0.0
    /// Row-major 3×3 channel mix, nil = identity.
    var mix: [Double]?

    var cacheKey: String {
        var parts: [Double] = [self.exposure, self.contrast, self.saturation, self.split]
        parts += self.lift + self.gamma + self.gain + self.shadowTint + self.highlightTint + (self.mix ?? [])
        return parts.map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    static func named(_ name: String) -> GGFilmLook? {
        var look = GGFilmLook()
        switch name {
        case "portra":
            look.exposure = 0.10; look.contrast = 0.92; look.saturation = 0.95
            look.lift = [0.02, 0.01, 0.0]; look.gain = [1.03, 1.0, 0.97]; look.shadowTint = [0.04, 0.08, 0.13]; look.split = 0.12
        case "kodachrome":
            look.contrast = 1.25; look.saturation = 1.15
            look.lift = [0.0, -0.01, -0.02]; look.gain = [1.06, 0.99, 0.95]; look.shadowTint = [0.06, 0.03, 0.02]; look.split = 0.15
        case "ektar":
            look.exposure = 0.05; look.contrast = 1.15; look.saturation = 1.25; look.gain = [1.02, 1.01, 1.02]
        case "provia":
            look.contrast = 1.10; look.saturation = 1.05; look.gain = [1.0, 1.0, 1.02]
        case "velvia":
            look.contrast = 1.30; look.saturation = 1.45; look.lift = [0.0, 0.0, -0.01]; look.gain = [1.04, 1.02, 0.98]
        case "cinema":
            look.exposure = -0.05; look.contrast = 1.18; look.saturation = 1.05
            look.lift = [0.01, 0.0, 0.03]; look.gain = [1.05, 0.99, 0.94]
            look.shadowTint = [0.05, 0.23, 0.27]; look.highlightTint = [1.0, 0.69, 0.44]; look.split = 0.30
            look.mix = [1.02, -0.02, 0.0, 0.0, 1.0, 0.0, 0.0, 0.06, 0.94]
        case "bleach":
            look.exposure = 0.15; look.contrast = 1.45; look.saturation = 0.45; look.lift = [0.03, 0.03, 0.03]
        case "crossProcess":
            look.contrast = 1.30; look.saturation = 1.20
            look.lift = [-0.02, 0.04, -0.03]; look.gain = [1.05, 1.0, 0.92]
            look.shadowTint = [0.10, 0.23, 0.06]; look.highlightTint = [1.0, 0.88, 0.38]; look.split = 0.25
        case "polaroid":
            look.exposure = 0.08; look.contrast = 0.85; look.saturation = 0.90
            look.lift = [0.06, 0.05, 0.07]; look.gain = [0.98, 0.98, 1.0]; look.highlightTint = [1.0, 0.94, 0.82]; look.split = 0.20
        case "lomo":
            look.contrast = 1.35; look.saturation = 1.30; look.lift = [0.0, 0.0, 0.02]; look.gain = [1.05, 1.0, 0.95]
        case "noirFilm":
            look.contrast = 1.40; look.saturation = 0.0
        case "archive":
            look.contrast = 0.95; look.saturation = 0.15; look.lift = [0.05, 0.03, 0.0]; look.gain = [1.10, 1.0, 0.80]
        case "fadedSummer":
            look.exposure = 0.12; look.contrast = 0.80; look.saturation = 0.75
            look.lift = [0.07, 0.06, 0.04]; look.gain = [1.02, 1.0, 0.96]; look.highlightTint = [1.0, 0.91, 0.75]; look.split = 0.25
        case "winterAsh":
            look.exposure = -0.05; look.contrast = 1.05; look.saturation = 0.55
            look.lift = [0.0, 0.01, 0.04]; look.gain = [0.95, 0.99, 1.06]; look.shadowTint = [0.10, 0.14, 0.19]; look.split = 0.20
        case "neonNight":
            look.exposure = -0.10; look.contrast = 1.25; look.saturation = 1.20
            look.lift = [0.02, -0.02, 0.05]; look.gain = [1.02, 0.94, 1.08]
            look.shadowTint = [0.0, 0.22, 0.27]; look.highlightTint = [1.0, 0.25, 0.75]; look.split = 0.35
        case "infrared":
            look.contrast = 1.20; look.saturation = 1.30; look.mix = [0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
        case "autumn":
            look.contrast = 1.10; look.lift = [0.03, 0.0, -0.02]; look.gain = [1.08, 0.98, 0.88]
        case "pastel":
            look.exposure = 0.15; look.contrast = 0.75; look.saturation = 0.85; look.lift = [0.08, 0.08, 0.08]; look.gain = [0.96, 0.96, 0.98]
        default:
            return nil
        }
        return look
    }

    static let lookNames: [String] = ["portra", "kodachrome", "ektar", "provia", "velvia", "cinema", "bleach", "crossProcess", "polaroid", "lomo", "noirFilm", "archive", "fadedSummer", "winterAsh", "neonNight", "infrared", "autumn", "pastel"]
}

enum GGFilmLUT {
    private static let dimension = 16
    private static let lock = NSLock()
    private static var cubes: [String: Data] = [:]
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// The look applied to `image`, cross-faded with the source by `intensity`.
    static func apply(_ look: GGFilmLook, to image: CIImage, intensity: Double, extent: CGRect) -> CIImage {
        let data = GGFilmLUT.cube(for: look)
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            return image
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(GGFilmLUT.dimension, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(GGFilmLUT.colorSpace, forKey: "inputColorSpace")
        guard let output = filter.outputImage?.cropped(to: extent) else {
            return image
        }
        return GGMaskOps.mix(base: image, overlay: output, amount: intensity, extent: extent)
    }

    private static func cube(for look: GGFilmLook) -> Data {
        let key = look.cacheKey
        GGFilmLUT.lock.lock()
        if let data = GGFilmLUT.cubes[key] {
            GGFilmLUT.lock.unlock()
            return data
        }
        GGFilmLUT.lock.unlock()

        let n = GGFilmLUT.dimension
        var values = [Float](repeating: 0.0, count: n * n * n * 4)
        let exposureFactor = pow(2.0, look.exposure)
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    var rgb = [Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1)]
                    for c in 0 ..< 3 {
                        var x = rgb[c] * exposureFactor
                        x = (x - 0.435) * look.contrast + 0.435
                        x = look.gain[c] * (x + look.lift[c] * (1.0 - x))
                        x = pow(max(x, 0.0), 1.0 / max(look.gamma[c], 0.05))
                        rgb[c] = x
                    }
                    if look.split > 0.0 {
                        let luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
                        let shadowWeight = (1.0 - luma) * (1.0 - luma) * look.split
                        let highlightWeight = luma * luma * look.split
                        for c in 0 ..< 3 {
                            rgb[c] += look.shadowTint[c] * shadowWeight + look.highlightTint[c] * highlightWeight
                        }
                    }
                    if let mix = look.mix, mix.count == 9 {
                        let original = rgb
                        for c in 0 ..< 3 {
                            rgb[c] = mix[c * 3] * original[0] + mix[c * 3 + 1] * original[1] + mix[c * 3 + 2] * original[2]
                        }
                    }
                    let luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
                    let offset = ((b * n + g) * n + r) * 4
                    for c in 0 ..< 3 {
                        let value = luma + (rgb[c] - luma) * look.saturation
                        values[offset + c] = Float(max(0.0, min(1.0, value)))
                    }
                    values[offset + 3] = 1.0
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        GGFilmLUT.lock.lock()
        if GGFilmLUT.cubes.count >= 64 {
            GGFilmLUT.cubes.removeAll()
        }
        GGFilmLUT.cubes[key] = data
        GGFilmLUT.lock.unlock()
        return data
    }
}
