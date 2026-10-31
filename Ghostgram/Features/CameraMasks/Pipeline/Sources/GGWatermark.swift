import Foundation
import UIKit
import CoreVideo
import GGCore

/// Text and look of a watermark, shared by photos and round videos.
public struct GGWatermarkStyle: Equatable {
    public var text: String
    public var font: GGWatermarkFont
    /// 0.1…1.
    public var opacity: CGFloat
    public var color: GGWatermarkColor

    public init(text: String, font: GGWatermarkFont, opacity: CGFloat, color: GGWatermarkColor) {
        self.text = text
        self.font = font
        self.opacity = opacity
        self.color = color
    }
}

/// Snapshot of the round-video watermark settings.
public struct GGRoundWatermarkConfig: Equatable {
    public var style: GGWatermarkStyle
    public var position: GGRoundWatermarkPosition
    /// % of the side, 2…12.
    public var sizePercent: CGFloat

    public init(style: GGWatermarkStyle, position: GGRoundWatermarkPosition, sizePercent: CGFloat) {
        self.style = style
        self.position = position
        self.sizePercent = sizePercent
    }

    /// nil when the watermark is off or has no text.
    public static func current() -> GGRoundWatermarkConfig? {
        guard GGRoundVideoSettings.watermark.value else {
            return nil
        }
        return GGRoundWatermarkConfig.make(
            text: GGRoundVideoSettings.watermarkText.value,
            font: GGRoundVideoSettings.watermarkFont.value,
            position: GGRoundVideoSettings.watermarkPosition.value,
            size: GGRoundVideoSettings.watermarkSize.value,
            opacity: GGRoundVideoSettings.watermarkOpacity.value,
            color: GGRoundVideoSettings.watermarkColor.value
        )
    }

    /// Builds a config from raw values (the menu preview passes slider drafts here).
    public static func make(text: String, font: String, position: String, size: Double, opacity: Double, color: String) -> GGRoundWatermarkConfig? {
        let trimmed = GGWatermarkDrawing.normalizedText(text, maxLength: GGWatermarkDrawing.roundMaxLength)
        if trimmed.isEmpty {
            return nil
        }
        return GGRoundWatermarkConfig(
            style: GGWatermarkStyle(
                text: trimmed,
                font: GGWatermarkFont(rawValue: font) ?? .bold,
                opacity: CGFloat(max(10.0, min(100.0, opacity)) / 100.0),
                color: GGWatermarkColor(rawValue: color) ?? .white
            ),
            position: GGRoundWatermarkPosition(rawValue: position) ?? .bottom,
            sizePercent: CGFloat(max(2.0, min(12.0, size)))
        )
    }
}

/// Snapshot of the photo watermark settings. Read once per photo.
public struct GGPhotoWatermarkConfig: Equatable {
    public var style: GGWatermarkStyle
    public var position: GGPhotoWatermarkPosition
    /// % of the short side, 2…12.
    public var sizePercent: CGFloat
    public var tiled: Bool

    public init(style: GGWatermarkStyle, position: GGPhotoWatermarkPosition, sizePercent: CGFloat, tiled: Bool) {
        self.style = style
        self.position = position
        self.sizePercent = sizePercent
        self.tiled = tiled
    }

    /// The `GGOutgoingImageHooks.image` handler of the app and of the share extension: the photo
    /// with the current watermark, or as it is when the mark is off.
    public static func applyCurrent(to image: UIImage) -> UIImage {
        guard let config = GGPhotoWatermarkConfig.current() else {
            return image
        }
        return config.apply(to: image)
    }

    public static func current() -> GGPhotoWatermarkConfig? {
        guard GGPhotoWatermarkSettings.enabled.value else {
            return nil
        }
        return GGPhotoWatermarkConfig.make(
            text: GGPhotoWatermarkSettings.text.value,
            font: GGPhotoWatermarkSettings.font.value,
            position: GGPhotoWatermarkSettings.position.value,
            size: GGPhotoWatermarkSettings.size.value,
            opacity: GGPhotoWatermarkSettings.opacity.value,
            color: GGPhotoWatermarkSettings.color.value,
            tiled: GGPhotoWatermarkSettings.tiled.value
        )
    }

    public static func make(text: String, font: String, position: String, size: Double, opacity: Double, color: String, tiled: Bool) -> GGPhotoWatermarkConfig? {
        let trimmed = GGWatermarkDrawing.normalizedText(text, maxLength: GGWatermarkDrawing.photoMaxLength)
        if trimmed.isEmpty {
            return nil
        }
        return GGPhotoWatermarkConfig(
            style: GGWatermarkStyle(
                text: trimmed,
                font: GGWatermarkFont(rawValue: font) ?? .bold,
                opacity: CGFloat(max(10.0, min(100.0, opacity)) / 100.0),
                color: GGWatermarkColor(rawValue: color) ?? .white
            ),
            position: GGPhotoWatermarkPosition(rawValue: position) ?? .bottomRight,
            sizePercent: CGFloat(max(2.0, min(12.0, size))),
            tiled: tiled
        )
    }

    /// Draws the watermark over a photo. Thread-safe (UIGraphicsImageRenderer), called off the main
    /// thread by the sending paths; one render per photo.
    public func apply(to image: UIImage) -> UIImage {
        let size = image.size
        guard size.width >= 1.0, size.height >= 1.0 else {
            return image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let fontSize = max(10.0, min(size.width, size.height) * self.sizePercent / 100.0)
        let attributes = GGWatermarkDrawing.attributes(style: self.style, fontSize: fontSize)
        let text = self.style.text as NSString
        let textSize = text.size(withAttributes: attributes)
        let margin = fontSize * 0.8
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            if self.tiled {
                let cgContext = context.cgContext
                cgContext.saveGState()
                cgContext.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                cgContext.rotate(by: -CGFloat.pi / 6.0)
                let stepX = textSize.width + fontSize * 2.5
                let stepY = textSize.height + fontSize * 2.5
                let extent = size.width + size.height
                var y = -extent
                while y < extent {
                    var x = -extent
                    while x < extent {
                        text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                        x += stepX
                    }
                    y += stepY
                }
                cgContext.restoreGState()
            } else {
                let origin: CGPoint
                switch self.position {
                case .topLeft:
                    origin = CGPoint(x: margin, y: margin)
                case .topRight:
                    origin = CGPoint(x: size.width - textSize.width - margin, y: margin)
                case .center:
                    origin = CGPoint(x: (size.width - textSize.width) / 2.0, y: (size.height - textSize.height) / 2.0)
                case .bottomLeft:
                    origin = CGPoint(x: margin, y: size.height - textSize.height - margin)
                case .bottomRight:
                    origin = CGPoint(x: size.width - textSize.width - margin, y: size.height - textSize.height - margin)
                }
                text.draw(at: origin, withAttributes: attributes)
            }
        }
    }
}

/// A round-video watermark prepared for one recording: the text is rendered once, every frame only
/// copies that small image into the frame.
public final class GGRoundVideoWatermark {
    public let side: Int
    public let image: CGImage
    /// Pixel rect in the square, top-left origin.
    public let rect: CGRect

    public init?(config: GGRoundWatermarkConfig, side: Int) {
        guard side > 0, let (image, rect) = GGWatermarkDrawing.roundOverlay(config: config, side: CGFloat(side)) else {
            return nil
        }
        self.side = side
        self.image = image
        self.rect = rect
    }

    /// Draws over a 32BGRA buffer in place. Other formats are left as they are.
    public func draw(into pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer), width > 0, height > 0 else {
            return
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: GGWatermarkDrawing.colorSpace, bitmapInfo: bitmapInfo) else {
            return
        }
        let scale = CGFloat(width) / CGFloat(self.side)
        let target = CGRect(
            x: self.rect.minX * scale,
            y: CGFloat(height) - self.rect.maxY * scale,
            width: self.rect.width * scale,
            height: self.rect.height * scale
        )
        context.interpolationQuality = .medium
        context.draw(self.image, in: target)
    }
}

enum GGWatermarkDrawing {
    static let roundMaxLength = 48
    static let photoMaxLength = 40
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func normalizedText(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxLength {
            return String(trimmed.prefix(maxLength))
        }
        return trimmed
    }

    static func font(_ font: GGWatermarkFont, size: CGFloat) -> UIFont {
        switch font {
        case .regular:
            return UIFont.systemFont(ofSize: size)
        case .bold:
            return UIFont.boldSystemFont(ofSize: size)
        case .mono:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        case .italic:
            return UIFont.italicSystemFont(ofSize: size)
        }
    }

    static func fillColor(_ color: GGWatermarkColor) -> UIColor {
        switch color {
        case .white:
            return UIColor(white: 1.0, alpha: 1.0)
        case .black:
            return UIColor(white: 0.0, alpha: 1.0)
        case .red:
            return UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
        case .yellow:
            return UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        }
    }

    /// Fill in the chosen color, a contrasting outline (negative stroke width = fill + stroke).
    static func attributes(style: GGWatermarkStyle, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let fill = GGWatermarkDrawing.fillColor(style.color).withAlphaComponent(style.opacity)
        let strokeBase: UIColor = style.color == .white ? UIColor(white: 0.0, alpha: 1.0) : UIColor(white: 1.0, alpha: 1.0)
        return [
            .font: GGWatermarkDrawing.font(style.font, size: fontSize),
            .foregroundColor: fill,
            .strokeColor: strokeBase.withAlphaComponent(style.opacity * 0.8),
            .strokeWidth: -2.5
        ]
    }

    /// The text fitted into the circle of a `side`×`side` square: horizontally centred, shrunk until
    /// it fits the chord at its height.
    static func roundOverlay(config: GGRoundWatermarkConfig, side: CGFloat) -> (CGImage, CGRect)? {
        let radius = side / 2.0
        let edgeInset = side * 0.14
        var fontSize = max(8.0, side * config.sizePercent / 100.0)
        let text = config.style.text as NSString
        var attributes = GGWatermarkDrawing.attributes(style: config.style, fontSize: fontSize)
        var textSize = text.size(withAttributes: attributes)
        for _ in 0 ..< 8 {
            let dy: CGFloat
            switch config.position {
            case .center:
                dy = textSize.height / 2.0
            case .top, .bottom:
                dy = radius - edgeInset
            }
            let halfChord = sqrt(max(0.0, radius * radius - dy * dy))
            let usable = max(1.0, 2.0 * halfChord - 0.5 * fontSize)
            if textSize.width <= usable || fontSize <= 6.0 {
                break
            }
            fontSize = max(6.0, fontSize * usable / textSize.width)
            attributes = GGWatermarkDrawing.attributes(style: config.style, fontSize: fontSize)
            textSize = text.size(withAttributes: attributes)
        }
        let width = ceil(textSize.width) + 4.0
        let height = ceil(textSize.height) + 2.0
        let originY: CGFloat
        switch config.position {
        case .top:
            originY = edgeInset
        case .center:
            originY = (side - height) / 2.0
        case .bottom:
            originY = side - edgeInset - height
        }
        let rect = CGRect(x: floor((side - width) / 2.0), y: floor(originY), width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            text.draw(at: CGPoint(x: 2.0, y: 1.0), withAttributes: attributes)
        }
        guard let cgImage = image.cgImage else {
            return nil
        }
        return (cgImage, rect)
    }
}
