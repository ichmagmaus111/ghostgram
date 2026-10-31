load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

# Feature module GGCallsMedia. Owner: W3-3.
# May depend on everything below TelegramUI; never on TelegramUI or another GG<Feature> module
# (FOUNDATION_SPEC §1.1).
#
# Hooks/      — swift_library GGCallsMediaHooks: points for the call modules below this one
#               (TelegramCallsUI depends on it), handlers registered here and by W3-2.
# CallAudio/  — objc_library GGCallAudio: the realtime part of the call audio effects, linked into
#               TgVoipWebrtc and used from TelegramVoip.
swift_library(
    name = "GGCallsMedia",
    module_name = "GGCallsMedia",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/GGHooks:GGHooks",
        "//Ghostgram/GGSettingsUI:GGSettingsUI",
        "//Ghostgram/Features/Shared:GGFeaturesShared",
        "//Ghostgram/Features/CallsMedia/Hooks:GGCallsMediaHooks",
        "//Ghostgram/Features/CallsMedia/CallAudio:GGCallAudio",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/TelegramVoip:TelegramVoip",
        "//submodules/TelegramCallsUI:TelegramCallsUI",
        "//submodules/ChatListUI:ChatListUI",
        "//submodules/FetchManagerImpl:FetchManagerImpl",
        "//submodules/ImageCompression:ImageCompression",
        "//submodules/ContextUI:ContextUI",
        "//submodules/UndoUI:UndoUI",
        "//submodules/AppBundle:AppBundle",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/PromptUI:PromptUI",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//third-party/LibYuvBinding",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) tests of «Записывать звонки» as one choice (2026-10-27): only
# Sources/Settings/GGCallRecordingMode.swift (Foundation). Run with
#   ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/CallsMedia:GGCallRecordingModeTests
swift_test(
    name = "GGCallRecordingModeTests",
    srcs = [
        "Sources/Settings/GGCallRecordingMode.swift",
    ] + glob([
        "Tests/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
)
