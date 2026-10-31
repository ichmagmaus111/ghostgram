// Compiled into ImageCompression (filegroup //Ghostgram/GGHooks:ImageCompressionHookSources).
// Outgoing photos: size and JPEG quality (photo quality / "large photos") and a pixel
// transform (watermark). Lives in ImageCompression because both sending paths — the legacy
// picker (LegacyMediaPickerUI) and photo-library resources (LocalMediaResources) — import it,
// and both sit below the UI library GGHooks.

import Foundation
import UIKit
import GGCore

public struct GGOutgoingPhotoParameters: Equatable {
    /// Longest side in pixels (upstream: 1280, 2560 for "HD").
    public var maxSide: CGFloat
    /// JPEG quality 0…1 (upstream: 0.6).
    public var jpegQuality: Float
    public let isHd: Bool

    public init(maxSide: CGFloat, jpegQuality: Float, isHd: Bool) {
        self.maxSide = maxSide
        self.jpegQuality = jpegQuality
        self.isHd = isHd
    }
}

public enum GGOutgoingImageHooks {
    /// Transformer of size / quality of an outgoing photo.
    public static let parameters = GGHookPoint<(inout GGOutgoingPhotoParameters) -> Void>("media.outgoingPhotoParameters")

    /// Transformer of the scaled pixels before compression (watermark). Called off the main
    /// thread; `Bool` = HD photo.
    public static let image = GGHookPoint<(UIImage, Bool) -> UIImage>("media.outgoingPhotoImage")

    public static func maxSide(_ side: CGFloat, hd: Bool) -> CGFloat {
        if GGOutgoingImageHooks.parameters.isEmpty {
            return side
        }
        return GGOutgoingImageHooks.resolve(GGOutgoingPhotoParameters(maxSide: side, jpegQuality: 0.6, isHd: hd)).maxSide
    }

    public static func jpegQuality(_ quality: Float, hd: Bool) -> Float {
        if GGOutgoingImageHooks.parameters.isEmpty {
            return quality
        }
        return GGOutgoingImageHooks.resolve(GGOutgoingPhotoParameters(maxSide: hd ? 2560.0 : 1280.0, jpegQuality: quality, isHd: hd)).jpegQuality
    }

    public static func transform(_ image: UIImage, hd: Bool) -> UIImage {
        if GGOutgoingImageHooks.image.isEmpty {
            return image
        }
        var result = image
        for handler in GGOutgoingImageHooks.image.handlers {
            result = handler(result, hd)
        }
        return result
    }

    private static func resolve(_ value: GGOutgoingPhotoParameters) -> GGOutgoingPhotoParameters {
        var result = value
        for handler in GGOutgoingImageHooks.parameters.handlers {
            handler(&result)
        }
        return result
    }
}
