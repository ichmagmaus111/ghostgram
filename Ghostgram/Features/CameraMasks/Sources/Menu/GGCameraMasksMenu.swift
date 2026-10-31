import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import PromptUI
import PresentationDataUtils
import GGCore
import GGSettingsUI
import GGCameraPipeline
import GGFeaturesShared

/// Menu rows of the zone: «Медиа и звонки › Кружки и камера» (masks, round video settings, gallery,
/// photo watermark), the «Маски и камера» section of «Звонки», «Приватность › Анонимный режим».
/// Every row is a binding to a registry setting: writing it rebuilds the screen, nothing else.
enum GGCameraMasksMenu {
    static let tab = GGMenuTabID.mediaCameraVideoMessages

    static let sectionQuality = GGMenuSectionID("media.cameraVideoMessages.quality")
    static let sectionCamera = GGMenuSectionID("media.cameraVideoMessages.camera")
    static let sectionRecording = GGMenuSectionID("media.cameraVideoMessages.recording")
    static let sectionSound = GGMenuSectionID("media.cameraVideoMessages.sound")
    static let sectionWatermark = GGMenuSectionID("media.cameraVideoMessages.watermark")
    static let sectionGallery = GGMenuSectionID("media.cameraVideoMessages.gallery")
    static let sectionPhotoWatermark = GGMenuSectionID("media.cameraVideoMessages.photoWatermark")
    static let sectionReset = GGMenuSectionID("media.cameraVideoMessages.reset")
    static let sectionCalls = GGMenuSectionID("media.calls.cameraMasks")

    static let masksTab = GGMenuTabID("cameraMasks.masks")
    static let studioTab = GGMenuTabID("cameraMasks.studio")
    static let virtualCameraTab = GGMenuTabID("cameraMasks.virtualCamera")

    static func register() {
        GGCameraMasksMenu.registerSections()
        GGCameraMasksMenu.registerPreview()
        GGCameraMasksMenu.registerMasks()
        GGCameraMasksMenu.registerQuality()
        GGCameraMasksMenu.registerCamera()
        GGCameraMasksMenu.registerRecording()
        GGCameraMasksMenu.registerSound()
        GGCameraMasksMenu.registerWatermark()
        GGCameraMasksMenu.registerGallery()
        GGCameraMasksMenu.registerPhotoWatermark()
        GGCameraMasksMenu.registerReset()
        GGCameraMasksMenu.registerCalls()
        GGCameraMasksMenu.registerAnonymousMode()
    }

    private static func registerSections() {
        let screen = GGMenuScreenID.tab(GGCameraMasksMenu.tab)
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionQuality, screen: screen, order: 300, header: { GGStrings.CameraMasks.Round.Section.quality }, footer: { _ in GGStrings.CameraMasks.Round.qualityFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionCamera, screen: screen, order: 400, header: { GGStrings.CameraMasks.Round.Section.camera }, footer: { _ in GGStrings.CameraMasks.Round.cameraFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionRecording, screen: screen, order: 500, header: { GGStrings.CameraMasks.Round.Section.recording }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionSound, screen: screen, order: 600, header: { GGStrings.CameraMasks.Round.Section.sound }, footer: { _ in GGStrings.CameraMasks.Round.soundFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionWatermark, screen: screen, order: 700, header: { GGStrings.CameraMasks.Round.Section.watermark }, footer: { _ in GGStrings.CameraMasks.Round.watermarkFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionGallery, screen: screen, order: 800, header: { GGStrings.CameraMasks.Round.Section.gallery }, footer: { _ in GGStrings.CameraMasks.Round.galleryFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionPhotoWatermark, screen: screen, order: 900, header: { GGStrings.CameraMasks.Photo.section }, footer: { _ in GGStrings.CameraMasks.Photo.footer }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionReset, screen: screen, order: 1000))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGCameraMasksMenu.sectionCalls, screen: .tab(.mediaCalls), order: 800, header: { GGStrings.CameraMasks.Calls.section }, footer: { _ in GGStrings.CameraMasks.Calls.footer }))
    }

    private static func registerPreview() {
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.preview",
            section: .preview(of: GGCameraMasksMenu.tab),
            order: 100,
            title: { "" },
            kind: .preview(.custom(height: 236.0, make: { _ in
                return GGRoundVideoPreviewView(frame: .zero)
            }))
        ))
    }

    // MARK: Masks

    private static func registerMasks() {
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.masks.enabled",
            section: .main(of: GGCameraMasksMenu.tab),
            order: 100,
            title: { GGStrings.CameraMasks.Masks.enabled },
            subtitle: { GGStrings.CameraMasks.Masks.enabledInfo },
            kind: .toggle(.global(GGMaskSettings.enabled)),
            searchKeywords: { [GGStrings.CameraMasks.Masks.keywords] }
        ))
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: GGCameraMasksMenu.masksTab,
                parent: .tab(GGCameraMasksMenu.tab),
                title: { GGStrings.CameraMasks.Masks.title },
                makeScreen: { context in
                    return ggMakeMaskLibraryScreen(context: context.context, target: .current)
                },
                searchKeywords: { [GGStrings.CameraMasks.Masks.keywords] }
            ),
            linkIn: .main(of: GGCameraMasksMenu.tab),
            order: 200,
            subtitle: { GGStrings.CameraMasks.Masks.chooseInfo },
            icon: .system("theatermasks"),
            label: { context in
                return GGMaskEngine.title(GGMaskSelection(storage: GGMaskSettings.selection.value))
            }
        )
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: GGCameraMasksMenu.studioTab,
                parent: .tab(GGCameraMasksMenu.tab),
                title: { GGStrings.CameraMasks.Studio.title },
                makeScreen: { context in
                    return ggMakeMaskStudioHome(context: context.context)
                },
                searchKeywords: { [GGStrings.CameraMasks.Studio.keywords] }
            ),
            linkIn: .main(of: GGCameraMasksMenu.tab),
            order: 300,
            subtitle: { GGStrings.CameraMasks.Studio.info },
            icon: .system("paintbrush"),
            label: { _ in
                let count = GGMaskStore.shared.currentEntries.count
                return count > 0 ? "\(count)" : nil
            }
        )
    }

    // MARK: Quality

    private static func registerQuality() {
        let section = GGCameraMasksMenu.sectionQuality
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.resolution",
            section: section,
            order: 100,
            title: { GGStrings.CameraMasks.Round.resolution },
            kind: .choice(.global(GGRoundVideoSettings.resolution), options: [
                GGMenuChoiceOption(value: "standard", title: { GGStrings.CameraMasks.Round.asTelegram }),
                GGMenuChoiceOption(value: "400", title: { GGStrings.CameraMasks.Round.side(side: "400") }),
                GGMenuChoiceOption(value: "512", title: { GGStrings.CameraMasks.Round.side(side: "512") }),
                GGMenuChoiceOption(value: "640", title: { GGStrings.CameraMasks.Round.side(side: "640") })
            ]),
            searchKeywords: { [GGStrings.CameraMasks.Round.qualityKeywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.bitrate",
            section: section,
            order: 200,
            title: { GGStrings.CameraMasks.Round.bitrate },
            kind: .slider(.global(GGRoundVideoSettings.bitrate), range: 0.0 ... 4000.0, step: 500.0, format: { value in
                if value < 500.0 {
                    return GGStrings.CameraMasks.Round.asTelegram
                }
                // What is really recorded: above Telegram's size limit the bitrate is lowered
                // (GGRoundVideoConfig.recording), so the slider says so instead of the chosen value.
                if let maximum = GGRoundVideoServerLimits.maximumVideoKbps(audioKbps: GGRoundVideoServerLimits.audioKbps), Double(maximum) < min(4000.0, value) {
                    return GGStrings.CameraMasks.Round.bitrateLimited(value: String(format: "%.1f", Double(maximum) / 1000.0))
                }
                return GGStrings.CameraMasks.Round.bitrateValue(value: String(format: "%.1f", value / 1000.0))
            })
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.codec",
            section: section,
            order: 300,
            title: { GGStrings.CameraMasks.Round.codec },
            kind: .choice(.global(GGRoundVideoSettings.codec), options: [
                GGMenuChoiceOption(value: GGRoundVideoCodec.h264.rawValue, title: { GGStrings.CameraMasks.Round.codecH264 }),
                GGMenuChoiceOption(value: GGRoundVideoCodec.hevc.rawValue, title: { GGStrings.CameraMasks.Round.codecHevc })
            ])
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.frameRate",
            section: section,
            order: 400,
            title: { GGStrings.CameraMasks.Round.frameRate },
            subtitle: { GGStrings.CameraMasks.Round.frameRateInfo },
            kind: .choice(.global(GGRoundVideoSettings.frameRate), options: [
                GGMenuChoiceOption(value: "30", title: { GGStrings.CameraMasks.Round.fps(fps: "30") }),
                GGMenuChoiceOption(value: "60", title: { GGStrings.CameraMasks.Round.fps(fps: "60") })
            ])
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.stabilization",
            section: section,
            order: 500,
            title: { GGStrings.CameraMasks.Round.stabilization },
            kind: .choice(.global(GGRoundVideoSettings.stabilization), options: [
                GGMenuChoiceOption(value: GGRoundVideoStabilization.standard.rawValue, title: { GGStrings.CameraMasks.Round.stabilizationStandard }),
                GGMenuChoiceOption(value: GGRoundVideoStabilization.off.rawValue, title: { GGStrings.CameraMasks.Round.stabilizationOff }),
                GGMenuChoiceOption(value: GGRoundVideoStabilization.cinematic.rawValue, title: { GGStrings.CameraMasks.Round.stabilizationCinematic })
            ])
        ))
    }

    // MARK: Camera

    private static func registerCamera() {
        let section = GGCameraMasksMenu.sectionCamera
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.rearCamera",
            section: section,
            order: 100,
            title: { GGStrings.CameraMasks.Round.rearCamera },
            subtitle: { GGStrings.CameraMasks.Round.rearCameraInfo },
            kind: .toggle(.global(GGRoundVideoSettings.startWithRearCamera))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.startZoom",
            section: section,
            order: 200,
            title: { GGStrings.CameraMasks.Round.startZoom },
            kind: .choice(.global(GGRoundVideoSettings.startZoom), options: [
                GGMenuChoiceOption(value: GGRoundVideoStartZoom.one.rawValue, title: { GGStrings.CameraMasks.Round.zoomOne }),
                GGMenuChoiceOption(value: GGRoundVideoStartZoom.two.rawValue, title: { GGStrings.CameraMasks.Round.zoomTwo }),
                GGMenuChoiceOption(value: GGRoundVideoStartZoom.last.rawValue, title: { GGStrings.CameraMasks.Round.zoomLast })
            ])
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.rememberZoom",
            section: section,
            order: 300,
            title: { GGStrings.CameraMasks.Round.rememberZoom },
            subtitle: { GGStrings.CameraMasks.Round.rememberZoomInfo },
            kind: .toggle(.global(GGRoundVideoSettings.rememberZoom))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.zoomSlider",
            section: section,
            order: 400,
            title: { GGStrings.CameraMasks.Round.zoomSlider },
            subtitle: { GGStrings.CameraMasks.Round.zoomSliderInfo },
            kind: .toggle(.global(GGRoundVideoSettings.zoomSlider))
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.rearHalfZoom",
            section: section,
            order: 450,
            title: { GGStrings.CameraMasks.Round.rearHalfZoom },
            subtitle: { GGStrings.CameraMasks.Round.rearHalfZoomInfo },
            kind: .toggle(.global(GGRoundVideoSettings.rearHalfZoom)),
            isVisible: { _ in GGRoundVideoConfig.hasUltraWideCamera }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.flipAnimation",
            section: section,
            order: 500,
            title: { GGStrings.CameraMasks.Round.flipAnimation },
            subtitle: { GGStrings.CameraMasks.Round.flipAnimationInfo },
            kind: .toggle(.global(GGRoundVideoSettings.flipAnimation))
        ))
    }

    // MARK: Recording

    private static func registerRecording() {
        let section = GGCameraMasksMenu.sectionRecording
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.countdown", section: section, order: 100, title: { GGStrings.CameraMasks.Round.countdown }, subtitle: { GGStrings.CameraMasks.Round.countdownInfo }, kind: .toggle(.global(GGRoundVideoSettings.countdown))))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.viewOnce", section: section, order: 200, title: { GGStrings.CameraMasks.Round.viewOnce }, subtitle: { GGStrings.CameraMasks.Round.viewOnceInfo }, kind: .toggle(.global(GGRoundVideoSettings.viewOnceByDefault))))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.sendAsVideo", section: section, order: 300, title: { GGStrings.CameraMasks.Round.sendAsVideo }, subtitle: { GGStrings.CameraMasks.Round.sendAsVideoInfo }, kind: .toggle(.global(GGRoundVideoSettings.sendAsRegularVideo))))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.saveToGallery", section: section, order: 400, title: { GGStrings.CameraMasks.Round.saveToGallery }, subtitle: { GGStrings.CameraMasks.Round.saveToGalleryInfo }, kind: .toggle(.global(GGRoundVideoSettings.saveCopyToGallery))))
    }

    // MARK: Sound

    private static func registerSound() {
        let section = GGCameraMasksMenu.sectionSound
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.microphone",
            section: section,
            order: 100,
            title: { GGStrings.CameraMasks.Round.microphone },
            kind: .choice(.global(GGRoundVideoSettings.microphoneMode), options: [
                GGMenuChoiceOption(value: GGRoundVideoMicrophoneMode.standard.rawValue, title: { GGStrings.CameraMasks.Round.asTelegram }),
                GGMenuChoiceOption(value: GGRoundVideoMicrophoneMode.videoRecording.rawValue, title: { GGStrings.CameraMasks.Round.microphoneVideo }),
                GGMenuChoiceOption(value: GGRoundVideoMicrophoneMode.voiceChat.rawValue, title: { GGStrings.CameraMasks.Round.microphoneVoice })
            ])
        ))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.normalize", section: section, order: 200, title: { GGStrings.CameraMasks.Round.normalize }, subtitle: { GGStrings.CameraMasks.Round.normalizeInfo }, kind: .toggle(.global(GGRoundVideoSettings.normalizeAudio))))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.mute", section: section, order: 300, title: { GGStrings.CameraMasks.Round.mute }, subtitle: { GGStrings.CameraMasks.Round.muteInfo }, kind: .toggle(.global(GGRoundVideoSettings.muteAudio))))
    }

    // MARK: Watermark (round)

    static func fontOptions() -> [GGMenuChoiceOption] {
        return [
            GGMenuChoiceOption(value: GGWatermarkFont.regular.rawValue, title: { GGStrings.CameraMasks.Watermark.fontRegular }),
            GGMenuChoiceOption(value: GGWatermarkFont.bold.rawValue, title: { GGStrings.CameraMasks.Watermark.fontBold }),
            GGMenuChoiceOption(value: GGWatermarkFont.mono.rawValue, title: { GGStrings.CameraMasks.Watermark.fontMono }),
            GGMenuChoiceOption(value: GGWatermarkFont.italic.rawValue, title: { GGStrings.CameraMasks.Watermark.fontItalic })
        ]
    }

    static func colorOptions() -> [GGMenuChoiceOption] {
        return [
            GGMenuChoiceOption(value: GGWatermarkColor.white.rawValue, title: { GGStrings.CameraMasks.Watermark.colorWhite }),
            GGMenuChoiceOption(value: GGWatermarkColor.black.rawValue, title: { GGStrings.CameraMasks.Watermark.colorBlack }),
            GGMenuChoiceOption(value: GGWatermarkColor.red.rawValue, title: { GGStrings.CameraMasks.Watermark.colorRed }),
            GGMenuChoiceOption(value: GGWatermarkColor.yellow.rawValue, title: { GGStrings.CameraMasks.Watermark.colorYellow })
        ]
    }

    /// A row that edits a text setting in a prompt.
    static func textRow(id: String, section: GGMenuSectionID, order: Int, title: @escaping () -> String, prompt: @escaping () -> String, setting: GGSetting<String>, limit: Int, isVisible: ((GGMenuContext) -> Bool)?) -> GGMenuRow {
        return GGMenuRow(
            id: id,
            section: section,
            order: order,
            title: title,
            kind: .action({ context in
                context.present(promptController(context: context.context, text: prompt(), value: setting.value, placeholder: GGStrings.CameraMasks.Watermark.placeholder, characterLimit: limit, apply: { value in
                    if let value {
                        setting.set(value.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }))
            }),
            isVisible: isVisible,
            label: { _ in
                let value = setting.value
                return value.isEmpty ? GGStrings.CameraMasks.Watermark.noText : value
            }
        )
    }

    private static func registerWatermark() {
        let section = GGCameraMasksMenu.sectionWatermark
        let isOn: (GGMenuContext) -> Bool = { _ in
            return GGRoundVideoSettings.watermark.value
        }
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.watermark", section: section, order: 100, title: { GGStrings.CameraMasks.Round.watermark }, kind: .toggle(.global(GGRoundVideoSettings.watermark)), searchKeywords: { [GGStrings.CameraMasks.Watermark.keywords] }))
        GGMenuRegistry.register(GGCameraMasksMenu.textRow(id: "cameraMasks.roundVideo.watermarkText", section: section, order: 200, title: { GGStrings.CameraMasks.Watermark.text }, prompt: { GGStrings.CameraMasks.Watermark.textPrompt }, setting: GGRoundVideoSettings.watermarkText, limit: 48, isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.watermarkPosition",
            section: section,
            order: 300,
            title: { GGStrings.CameraMasks.Watermark.position },
            kind: .choice(.global(GGRoundVideoSettings.watermarkPosition), options: [
                GGMenuChoiceOption(value: GGRoundWatermarkPosition.bottom.rawValue, title: { GGStrings.CameraMasks.Watermark.positionBottom }),
                GGMenuChoiceOption(value: GGRoundWatermarkPosition.top.rawValue, title: { GGStrings.CameraMasks.Watermark.positionTop }),
                GGMenuChoiceOption(value: GGRoundWatermarkPosition.center.rawValue, title: { GGStrings.CameraMasks.Watermark.positionCenter })
            ]),
            isVisible: isOn
        ))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.watermarkFont", section: section, order: 400, title: { GGStrings.CameraMasks.Watermark.font }, kind: .choice(.global(GGRoundVideoSettings.watermarkFont), options: GGCameraMasksMenu.fontOptions()), isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.watermarkSize", section: section, order: 500, title: { GGStrings.CameraMasks.Watermark.size }, kind: .slider(.global(GGRoundVideoSettings.watermarkSize), range: 2.0 ... 12.0, step: 1.0, format: { value in GGStrings.CameraMasks.Watermark.percent(value: "\(Int(value))") }), isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.watermarkOpacity", section: section, order: 600, title: { GGStrings.CameraMasks.Watermark.opacity }, kind: .slider(.global(GGRoundVideoSettings.watermarkOpacity), range: 10.0 ... 100.0, step: 5.0, format: { value in GGStrings.CameraMasks.Watermark.percent(value: "\(Int(value))") }), isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.watermarkColor", section: section, order: 700, title: { GGStrings.CameraMasks.Watermark.color }, kind: .choice(.global(GGRoundVideoSettings.watermarkColor), options: GGCameraMasksMenu.colorOptions()), isVisible: isOn))
    }

    // MARK: Gallery (video → round, SG-F5)

    private static func registerGallery() {
        let section = GGCameraMasksMenu.sectionGallery
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.galleryAsRound", section: section, order: 100, title: { GGStrings.CameraMasks.Round.galleryAsRound }, subtitle: { GGStrings.CameraMasks.Round.galleryAsRoundInfo }, kind: .toggle(.global(GGRoundVideoSettings.galleryVideosAsRound))))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.roundVideo.galleryMenuItem", section: section, order: 150, title: { GGStrings.CameraMasks.Round.galleryMenuItem }, subtitle: { GGStrings.CameraMasks.Round.galleryMenuItemInfo }, kind: .toggle(.global(GGRoundVideoSettings.galleryMenuItem)), isVisible: { _ in !GGRoundVideoSettings.galleryVideosAsRound.value }))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.gallery.hideCamera", section: section, order: 200, title: { GGStrings.CameraMasks.Gallery.hideCamera }, subtitle: { GGStrings.CameraMasks.Gallery.hideCameraInfo }, kind: .toggle(.global(GGGalleryCameraSettings.hideCamera))))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.gallery.noLivePreview", section: section, order: 300, title: { GGStrings.CameraMasks.Gallery.noLivePreview }, subtitle: { GGStrings.CameraMasks.Gallery.noLivePreviewInfo }, kind: .toggle(.global(GGGalleryCameraSettings.noLivePreview)), isVisible: { _ in !GGGalleryCameraSettings.hideCamera.value }))
    }

    // MARK: Photo watermark

    private static func registerPhotoWatermark() {
        let section = GGCameraMasksMenu.sectionPhotoWatermark
        let isOn: (GGMenuContext) -> Bool = { _ in
            return GGPhotoWatermarkSettings.enabled.value
        }
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.photoWatermark.preview", section: section, order: 50, title: { "" }, kind: .preview(.custom(height: 190.0, make: { _ in GGPhotoWatermarkPreviewView(frame: .zero) }))))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.photoWatermark.enabled", section: section, order: 100, title: { GGStrings.CameraMasks.Photo.enabled }, subtitle: { GGStrings.CameraMasks.Photo.enabledInfo }, kind: .toggle(.global(GGPhotoWatermarkSettings.enabled)), searchKeywords: { [GGStrings.CameraMasks.Watermark.keywords] }))
        GGMenuRegistry.register(GGCameraMasksMenu.textRow(id: "cameraMasks.photoWatermark.text", section: section, order: 200, title: { GGStrings.CameraMasks.Watermark.text }, prompt: { GGStrings.CameraMasks.Watermark.textPrompt }, setting: GGPhotoWatermarkSettings.text, limit: 40, isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.photoWatermark.tiled", section: section, order: 300, title: { GGStrings.CameraMasks.Photo.tiled }, kind: .toggle(.global(GGPhotoWatermarkSettings.tiled)), isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.photoWatermark.position",
            section: section,
            order: 400,
            title: { GGStrings.CameraMasks.Watermark.position },
            kind: .choice(.global(GGPhotoWatermarkSettings.position), options: [
                GGMenuChoiceOption(value: GGPhotoWatermarkPosition.bottomRight.rawValue, title: { GGStrings.CameraMasks.Photo.bottomRight }),
                GGMenuChoiceOption(value: GGPhotoWatermarkPosition.bottomLeft.rawValue, title: { GGStrings.CameraMasks.Photo.bottomLeft }),
                GGMenuChoiceOption(value: GGPhotoWatermarkPosition.topRight.rawValue, title: { GGStrings.CameraMasks.Photo.topRight }),
                GGMenuChoiceOption(value: GGPhotoWatermarkPosition.topLeft.rawValue, title: { GGStrings.CameraMasks.Photo.topLeft }),
                GGMenuChoiceOption(value: GGPhotoWatermarkPosition.center.rawValue, title: { GGStrings.CameraMasks.Watermark.positionCenter })
            ]),
            isVisible: { context in isOn(context) && !GGPhotoWatermarkSettings.tiled.value }
        ))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.photoWatermark.font", section: section, order: 500, title: { GGStrings.CameraMasks.Watermark.font }, kind: .choice(.global(GGPhotoWatermarkSettings.font), options: GGCameraMasksMenu.fontOptions()), isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.photoWatermark.size", section: section, order: 600, title: { GGStrings.CameraMasks.Watermark.size }, kind: .slider(.global(GGPhotoWatermarkSettings.size), range: 2.0 ... 12.0, step: 1.0, format: { value in GGStrings.CameraMasks.Watermark.percent(value: "\(Int(value))") }), isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.photoWatermark.opacity", section: section, order: 700, title: { GGStrings.CameraMasks.Watermark.opacity }, kind: .slider(.global(GGPhotoWatermarkSettings.opacity), range: 10.0 ... 100.0, step: 5.0, format: { value in GGStrings.CameraMasks.Watermark.percent(value: "\(Int(value))") }), isVisible: isOn))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.photoWatermark.color", section: section, order: 800, title: { GGStrings.CameraMasks.Watermark.color }, kind: .choice(.global(GGPhotoWatermarkSettings.color), options: GGCameraMasksMenu.colorOptions()), isVisible: isOn))
    }

    // MARK: Reset

    private static func registerReset() {
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.roundVideo.reset",
            section: GGCameraMasksMenu.sectionReset,
            order: 100,
            title: { GGStrings.CameraMasks.Round.reset },
            kind: .action({ context in
                let presentationData = context.presentationData
                context.present(textAlertController(context: context.context, title: GGStrings.CameraMasks.Round.resetTitle, text: GGStrings.CameraMasks.Round.resetText, actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: GGStrings.CameraMasks.Round.resetConfirm, action: {
                        for setting in GGRoundVideoSettings.resettableKeys {
                            setting.reset()
                        }
                    })
                ]))
            }),
            isEnabled: { _ in
                return GGRoundVideoSettings.resettableKeys.contains(where: { !$0.isDefault() })
            },
            isDestructive: true
        ))
    }

    // MARK: Calls

    private static func registerCalls() {
        let section = GGCameraMasksMenu.sectionCalls
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.calls.masks", section: section, order: 100, title: { GGStrings.CameraMasks.Calls.masks }, subtitle: { GGStrings.CameraMasks.Calls.masksInfo }, kind: .toggle(.global(GGMaskSettings.inCalls)), searchKeywords: { [GGStrings.CameraMasks.Masks.keywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.virtualCamera.enabled", section: section, order: 200, title: { GGStrings.CameraMasks.VirtualCamera.enabled }, subtitle: { GGStrings.CameraMasks.VirtualCamera.enabledInfo }, kind: .toggle(.global(GGVirtualCameraSettings.enabled)), searchKeywords: { [GGStrings.CameraMasks.VirtualCamera.keywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "cameraMasks.virtualCamera.loop", section: section, order: 300, title: { GGStrings.CameraMasks.VirtualCamera.loop }, kind: .toggle(.global(GGVirtualCameraSettings.loop)), isVisible: { _ in GGVirtualCameraSettings.enabled.value }))
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: GGCameraMasksMenu.virtualCameraTab,
                parent: .tab(.mediaCalls),
                title: { GGStrings.CameraMasks.VirtualCamera.library },
                makeScreen: { context in
                    return ggMakeVirtualCameraScreen(context: context.context)
                },
                searchKeywords: { [GGStrings.CameraMasks.VirtualCamera.keywords] }
            ),
            linkIn: GGCameraMasksMenu.sectionCalls,
            order: 400,
            subtitle: { GGStrings.CameraMasks.VirtualCamera.libraryInfo },
            icon: .system("photo.on.rectangle"),
            label: { _ in
                if let item = GGVirtualCameraSettings.selectedItem {
                    return item.title
                }
                return nil
            }
        )
    }

    // MARK: Anonymous mode

    private static func registerAnonymousMode() {
        let tab = GGMenuTabID.privacyAnonymousMode
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.anonymous.active",
            section: .main(of: tab),
            order: 100,
            title: { GGStrings.CameraMasks.Anonymous.toggle },
            subtitle: { GGStrings.CameraMasks.Anonymous.toggleInfo },
            kind: .toggle(.account(GGAnonymousMode.isActive)),
            searchKeywords: { [GGStrings.CameraMasks.Anonymous.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.anonymous.mask",
            section: .main(of: tab),
            order: 200,
            title: { GGStrings.CameraMasks.Anonymous.mask },
            kind: .action({ context in
                context.push(ggMakeMaskLibraryScreen(context: context.context, target: .anonymous))
            }),
            label: { _ in
                return GGMaskEngine.title(GGMaskSelection(storage: GGAnonymousMode.mask.value))
            }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "cameraMasks.anonymous.voice",
            section: .main(of: tab),
            order: 300,
            title: { GGStrings.CameraMasks.Anonymous.voice },
            kind: .action({ context in
                let presets = GGAnonymousMode.allVoicePresets()
                let sheet = UIAlertController(title: GGStrings.CameraMasks.Anonymous.voice, message: nil, preferredStyle: .actionSheet)
                for preset in presets {
                    let title = (preset.id == GGAnonymousMode.voice.value ? "✓ " : "") + preset.title()
                    sheet.addAction(UIAlertAction(title: title, style: .default, handler: { _ in
                        GGAnonymousMode.voice.set(preset.id)
                    }))
                }
                sheet.addAction(UIAlertAction(title: context.presentationData.strings.Common_Cancel, style: .cancel))
                context.presentNative(sheet)
            }),
            isVisible: { _ in
                return !GGAnonymousMode.voicePresets.isEmpty
            },
            label: { _ in
                let value = GGAnonymousMode.voice.value
                return GGAnonymousMode.allVoicePresets().first(where: { $0.id == value })?.title()
            }
        ))
    }
}
