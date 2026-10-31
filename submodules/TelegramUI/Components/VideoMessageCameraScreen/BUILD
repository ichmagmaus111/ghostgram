load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "VideoMessageCameraScreen",
    module_name = "VideoMessageCameraScreen",
    srcs = glob([
        "Sources/**/*.swift",
    ]) + [
        # GHOST: video part of the Ghostgram round video settings and masks
        "//Ghostgram/Features/CameraMasks:VideoMessageCameraScreenSources",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/ComponentFlow",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/AppBundle",
        "//submodules/TelegramStringFormatting",
        "//submodules/PresentationDataUtils",
        "//submodules/MediaResources",
        "//submodules/LocalMediaResources",
        "//submodules/ImageCompression",
        "//submodules/Camera",
        "//submodules/Camera/CameraLegacy",
        "//submodules/Camera/CameraNeo",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/Components/BlurredBackgroundComponent",
        "//submodules/Components/BundleIconComponent:BundleIconComponent",
        "//submodules/TelegramUI/Components/ButtonComponent",
        "//submodules/TelegramUI/Components/PlainButtonComponent",
        "//submodules/TelegramUI/Components/CameraButtonComponent",
        "//submodules/TooltipUI",
        "//submodules/TelegramNotices",
        "//submodules/DeviceAccess",
        "//submodules/TelegramUI/Components/MediaEditor",
        "//submodules/LegacyMediaPickerUI",
        "//submodules/TelegramAudio",
        "//submodules/ChatSendMessageActionUI",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
        "//submodules/TelegramUI/Components/LottieComponent",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        # GHOST: Ghostgram round video settings and masks
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/Features/CameraMasks:GGCameraPipeline",
    ],
    visibility = [
        "//visibility:public",
    ],
)
