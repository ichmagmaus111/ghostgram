import Foundation
import UIKit
import Postbox
import TelegramCore
import LocalMediaResources
import MediaEditor
import ImageCompression
import LegacyComponents
import GGCore
import GGCameraPipeline

/// «Водяной знак на фото» on both sending paths of the attachment picker (`GGOutgoingImageHooks`).
/// The settings are read once per photo as a snapshot. The share extension registers the same
/// handler (`ggShareExtensionDidStart`).
enum GGPhotoWatermarkHandler {
    static func register() {
        GGOutgoingImageHooks.image.register({ image, _ in
            return GGPhotoWatermarkConfig.applyCurrent(to: image)
        }, order: 500)
    }
}

/// «Video as a round video». No conversion code in the chat screen and no one-shot flag in
/// UserDefaults: the outgoing pipeline (`GGOutgoingHooks.messages`) relabels the video — a
/// centred square, the `.videoMessage` export preset (side and bitrate of the round video settings),
/// at most 60 s, `instantRoundVideo` — and the upload transcodes it with the stock exporter.
/// Which videos: the gallery assets marked by «Send as a round video» in the picker, or every
/// picked video while «Always send videos as round videos» is on.
enum GGRoundVideoImportHandler {
    static let maximumDuration: Double = 60.0

    static func register() {
        GGOutgoingHooks.messages.register({ messages, context in
            let all = GGRoundVideoSettings.galleryVideosAsRound.value
            if !all && !GGRoundVideoImport.shared.hasMarks {
                return
            }
            messages = messages.map { message in
                return GGRoundVideoImportHandler.convert(message, peerId: context.account.peerId, all: all)
            }
        }, order: 500)
    }

    private static func convert(_ message: EnqueueMessage, peerId: EnginePeer.Id, all: Bool) -> EnqueueMessage {
        guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, _, correlationId, bubbleUpEmojiOrStickersets) = message, let mediaReference, case let .standalone(media) = mediaReference, let file = media as? TelegramMediaFile else {
            return message
        }
        guard let converted = GGRoundVideoImportHandler.convert(file, peerId: peerId, all: all) else {
            return message
        }
        // A round video is never part of an album.
        return .message(text: text, attributes: attributes, inlineStickers: inlineStickers, mediaReference: .standalone(media: converted), threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
    }

    private static func convert(_ file: TelegramMediaFile, peerId: EnginePeer.Id, all: Bool) -> TelegramMediaFile? {
        if file.isInstantVideo || file.isAnimated {
            return nil
        }
        var videoDuration: Double?
        var videoSize: PixelDimensions?
        for attribute in file.attributes {
            if case let .Video(duration, size, _, _, _, _) = attribute {
                videoDuration = duration
                videoSize = size
            }
        }
        guard let duration = videoDuration, let size = videoSize, size.width > 0, size.height > 0 else {
            return nil
        }

        let resource: TelegramMediaResource
        var trimRange: Range<Double>?
        if let library = file.resource as? VideoLibraryMediaResource {
            // A marked asset, or every video in the «always» mode.
            let marked = GGRoundVideoImport.shared.consume(assetIdentifier: library.localIdentifier)
            guard marked || all else {
                return nil
            }
            if case let .compress(adjustments) = library.conversion {
                trimRange = GGRoundVideoImportHandler.trimRange(adjustments)
            }
            guard let adjustments = GGRoundVideoImportHandler.adjustments(size: size, duration: duration, trimRange: trimRange, peerId: peerId) else {
                return nil
            }
            resource = VideoLibraryMediaResource(localIdentifier: library.localIdentifier, conversion: .compress(adjustments))
        } else if let local = file.resource as? LocalFileVideoMediaResource, all {
            // A recording of the round camera sent as an ordinary video («Отправлять видео вместо
            // кружка») stays a video: «always as round videos» is about the gallery.
            if GGRoundVideoImportHandler.isRoundCameraRecording(local.adjustments) {
                return nil
            }
            trimRange = GGRoundVideoImportHandler.trimRange(local.adjustments)
            guard let adjustments = GGRoundVideoImportHandler.adjustments(size: size, duration: duration, trimRange: trimRange, peerId: peerId) else {
                return nil
            }
            resource = LocalFileVideoMediaResource(randomId: Int64.random(in: Int64.min ... Int64.max), paths: local.paths, adjustments: adjustments)
        } else {
            return nil
        }

        let range = GGRoundVideoImportHandler.clampedRange(trimRange, duration: duration)
        let side = Int32(GGRoundVideoConfig.exportSide(400.0))
        var attributes: [TelegramMediaFileAttribute] = []
        for attribute in file.attributes {
            if case .Video = attribute {
                continue
            }
            attributes.append(attribute)
        }
        attributes.append(.Video(duration: range.upperBound - range.lowerBound, size: PixelDimensions(width: side, height: side), flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil))
        return file.withUpdatedResource(resource).withUpdatedAttributes(attributes)
    }

    /// Editor values of the round camera's own export (`.videoMessage`): a recording, not a gallery video.
    private static func isRoundCameraRecording(_ adjustments: VideoMediaResourceAdjustments?) -> Bool {
        guard let adjustments, !adjustments.isStory else {
            return false
        }
        guard let values = try? JSONDecoder().decode(MediaEditorValues.self, from: adjustments.data.makeData()) else {
            return false
        }
        return values.qualityPreset == .videoMessage
    }

    /// The trim the user made in the picker's editor, if any.
    private static func trimRange(_ adjustments: VideoMediaResourceAdjustments?) -> Range<Double>? {
        guard let adjustments else {
            return nil
        }
        let data = adjustments.data.makeData()
        if adjustments.isStory {
            if let values = try? JSONDecoder().decode(MediaEditorValues.self, from: data) {
                return values.videoTrimRange
            }
            return nil
        }
        guard let dictionary = legacy_unarchiveDeprecated(data: data) as? [AnyHashable: Any], let legacy = TGVideoEditAdjustments(dictionary: dictionary) else {
            return nil
        }
        if legacy.trimEndValue > legacy.trimStartValue {
            return legacy.trimStartValue ..< legacy.trimEndValue
        }
        return nil
    }

    private static func clampedRange(_ range: Range<Double>?, duration: Double) -> Range<Double> {
        let start = max(0.0, range?.lowerBound ?? 0.0)
        var end = min(duration, range?.upperBound ?? duration)
        if end - start > GGRoundVideoImportHandler.maximumDuration {
            end = start + GGRoundVideoImportHandler.maximumDuration
        }
        return start ..< max(start + 0.1, end)
    }

    /// Editor values of the stock exporter: centred square, `.videoMessage` preset, ≤ 60 s.
    private static func adjustments(size: PixelDimensions, duration: Double, trimRange: Range<Double>?, peerId: EnginePeer.Id) -> VideoMediaResourceAdjustments? {
        let dimensions = size.cgSize
        let side = min(dimensions.width, dimensions.height)
        let cropRect = CGRect(x: floor((dimensions.width - side) / 2.0), y: floor((dimensions.height - side) / 2.0), width: side, height: side)
        let values = MediaEditorValues(
            peerId: peerId,
            originalDimensions: size,
            cropOffset: .zero,
            cropRect: cropRect,
            cropScale: 1.0,
            cropRotation: 0.0,
            cropMirroring: false,
            cropOrientation: nil,
            gradientColors: nil,
            videoTrimRange: GGRoundVideoImportHandler.clampedRange(trimRange, duration: duration),
            videoBounce: false,
            videoIsMuted: false,
            videoIsFullHd: false,
            videoIsMirrored: false,
            videoVolume: nil,
            additionalVideoPath: nil,
            additionalVideoIsDual: false,
            additionalVideoMirroringChanges: [],
            additionalVideoPosition: nil,
            additionalVideoScale: nil,
            additionalVideoRotation: nil,
            additionalVideoPositionChanges: [],
            additionalVideoTrimRange: nil,
            additionalVideoOffset: nil,
            additionalVideoVolume: nil,
            collage: [],
            nightTheme: false,
            drawing: nil,
            maskDrawing: nil,
            entities: [],
            toolValues: [:],
            audioTrack: nil,
            audioTrackTrimRange: nil,
            audioTrackOffset: nil,
            audioTrackVolume: nil,
            audioTrackSamples: nil,
            collageTrackSamples: nil,
            coverImageTimestamp: nil,
            coverDimensions: nil,
            qualityPreset: .videoMessage
        )
        guard let data = try? JSONEncoder().encode(values) else {
            return nil
        }
        let buffer = EngineMemoryBuffer(data: data)
        // `isStory` here only tells the fetcher the data is editor values (JSON).
        return VideoMediaResourceAdjustments(data: buffer, digest: EngineMemoryBuffer(data: buffer.md5Digest()), isStory: true)
    }
}
