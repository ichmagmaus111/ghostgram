import Foundation
import UIKit
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

/// Pictures from outside (icon packs, badges, the photo library, the pasteboard) are decoded only as
/// large as they are drawn. ImageIO makes the thumbnail without decoding the whole picture (a
/// 16000×16000 PNG drawn into 300 px costs ~20 MB this way, ~1 GB through `UIImage(data:)` + `draw`),
/// and a picture whose pixel count is absurd for its use is refused from the file's header, before any
/// decoding: a 40000×40000 PNG compresses to a few megabytes and passes every limit on bytes. Any
/// thread; callers keep it off the main one.
enum GGImageDecoding {
    /// Icons of a pack: far beyond any icon.
    static let maxIconSourcePixels = 4096 * 4096
    /// Badge pictures: photos from the library included (48 MP).
    static let maxPictureSourcePixels = 100_000_000

    static func thumbnail(data: Data, maxPixelSize: Int, maxSourcePixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return GGImageDecoding.thumbnail(source: source, maxPixelSize: maxPixelSize, maxSourcePixels: maxSourcePixels)
    }

    static func thumbnail(url: URL, maxPixelSize: Int, maxSourcePixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return GGImageDecoding.thumbnail(source: source, maxPixelSize: maxPixelSize, maxSourcePixels: maxSourcePixels)
    }

    /// Pixel size of the first picture, read from the header only.
    static func pixelSize(source: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(source) > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] else {
            return nil
        }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    /// The picture at most `maxPixelSize` on its long side (a smaller one keeps its size), upright,
    /// decoded; scale 1. Nil: not a picture, or more than `maxSourcePixels` pixels.
    private static func thumbnail(source: CGImageSource, maxPixelSize: Int, maxSourcePixels: Int) -> UIImage? {
        guard let size = GGImageDecoding.pixelSize(source: source) else {
            return nil
        }
        let (pixels, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        if overflow || pixels > maxSourcePixels {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

/// The photo library's picker for one picture: the photo comes as a file and is decoded right there,
/// off the main thread, only as a thumbnail (`loadObject(ofClass: UIImage.self)` hands over the
/// whole photo, which was then drawn on the main thread — a 48 MP photo is ~190 MB). `completion`
/// runs on a background queue; nothing happens when the picture can not be read.
final class GGPhotoThumbnailPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    private let maxPixelSize: Int
    private let completion: (UIImage) -> Void

    init(maxPixelSize: Int, completion: @escaping (UIImage) -> Void) {
        self.maxPixelSize = maxPixelSize
        self.completion = completion
        super.init()
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            return
        }
        let maxPixelSize = self.maxPixelSize
        let completion = self.completion
        // The file lives only until the handler returns: it is decoded inside it.
        let _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier, completionHandler: { url, _ in
            guard let url, let image = GGImageDecoding.thumbnail(url: url, maxPixelSize: maxPixelSize, maxSourcePixels: GGImageDecoding.maxPictureSourcePixels) else {
                return
            }
            completion(image)
        })
    }
}
