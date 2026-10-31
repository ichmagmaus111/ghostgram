load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

# Owner: W3-2. Targets:
#
#   GGCameraPipeline  — what the upstream camera modules read: round video / watermark / gallery
#                       camera settings, the recording snapshot, the frame processor protocol and
#                       the camera hook points, the watermark renderer, audio post-processing of
#                       round videos. GGCore + SwiftSignalKit only, so Camera, CameraNeo,
#                       CameraLegacy, MediaEditor, MediaPickerUI and VideoMessageCameraScreen can
#                       depend on it (like GGAppearanceSettings of W2-4).
#   GGCallFrameBridge — Objective-C, Foundation + CoreVideo only: the one hook tgcalls'
#                       VideoCameraCapturer calls for every call frame (masks in calls).
#   GGCallCameraHooks — GGCore + TelegramVoip: the call camera points TelegramCallsUI asks
#                       (a capturer fed by the virtual camera instead of the device camera).
#   GGCameraMasks     — the feature: mask engine (Core Image + Vision), catalog, own masks, studio,
#                       menus, the round-video camera extension, calls (masks, virtual camera),
#                       «video → round video», photo watermark, migration.
#
# Filegroup compiled INTO VideoMessageCameraScreen (its BUILD lists the label in srcs), so the code
# stays under Ghostgram/: the video part of the round video settings on the camera screen.

swift_library(
    name = "GGCameraPipeline",
    module_name = "GGCameraPipeline",
    srcs = glob([
        "Pipeline/Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGCore:GGCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

objc_library(
    name = "GGCallFrameBridge",
    enable_modules = True,
    module_name = "GGCallFrameBridge",
    srcs = glob([
        "CallBridge/Sources/**/*.m",
    ]),
    copts = [
        "-Werror",
    ],
    hdrs = glob([
        "CallBridge/PublicHeaders/**/*.h",
    ]),
    includes = [
        "CallBridge/PublicHeaders",
    ],
    sdk_frameworks = [
        "Foundation",
        "CoreVideo",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "VideoMessageCameraScreenSources",
    srcs = glob([
        "Upstream/VideoMessageCameraScreen/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "GGCallCameraHooks",
    module_name = "GGCallCameraHooks",
    srcs = glob([
        "CallHooks/Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGCore:GGCore",
        "//submodules/TelegramVoip:TelegramVoip",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "GGCameraMasks",
    module_name = "GGCameraMasks",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":GGCameraPipeline",
        ":GGCallFrameBridge",
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/GGHooks:GGHooks",
        "//Ghostgram/GGSettingsUI:GGSettingsUI",
        "//Ghostgram/Features/Shared:GGFeaturesShared",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AppBundle:AppBundle",
        "//submodules/ImageCompression:ImageCompression",
        "//submodules/LocalMediaResources:LocalMediaResources",
        "//submodules/TelegramUI/Components/MediaEditor",
        "//submodules/LegacyComponents:LegacyComponents",
        "//submodules/PromptUI:PromptUI",
        ":GGCallCameraHooks",
        "//Ghostgram/Features/CallsMedia/Hooks:GGCallsMediaHooks",
        "//submodules/TelegramVoip:TelegramVoip",
    ],
    visibility = [
        "//visibility:public",
    ],
)
