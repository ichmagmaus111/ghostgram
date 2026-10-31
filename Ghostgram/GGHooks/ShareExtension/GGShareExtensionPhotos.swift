// Compiled into ShareExtensionContext (filegroup //Ghostgram/GGHooks:ShareExtensionHookSources):
// photos sent from other apps through the share extension get the same size, JPEG quality and
// watermark as photos sent from the app (MEDIA-12). The settings are App Group ones
// (`GGOutgoingPhotoSettings`, `GGPhotoWatermarkSettings`); the handlers are the app's own.

import Foundation
import UIKit
import ImageCompression
import GGCore
import GGFeaturesShared
import GGCameraPipeline

/// From `ggShareExtensionDidStart`, before `GGHookRegistry.freeze()`.
func ggShareExtensionRegisterPhotoHandlers() {
    GGPhotoWatermarkSettings.declare()
    GGOutgoingImageHooks.parameters.register({ parameters in
        GGOutgoingPhotoSettings.apply(maxSide: &parameters.maxSide, jpegQuality: &parameters.jpegQuality, isHd: parameters.isHd)
    })
    GGOutgoingImageHooks.image.register({ image, _ in
        return GGPhotoWatermarkConfig.applyCurrent(to: image)
    }, order: 500)
}

/// GHOST hook target, before the shared items are read (`TGItemProviderSignals.setGGPhotoMaxPixelSize`):
/// the long side a shared photo is decoded to when Ghostgram changes something about it, 0 when
/// nothing changes (the item provider then compresses it itself, as upstream does).
func ggShareExtensionPhotoMaxPixelSize() -> CGFloat {
    let maxSide = GGOutgoingImageHooks.maxSide(1280.0, hd: false)
    let quality = GGOutgoingImageHooks.jpegQuality(0.52, hd: false)
    if maxSide == 1280.0 && quality == 0.52 && GGPhotoWatermarkConfig.current() == nil {
        return 0.0
    }
    return maxSide
}
