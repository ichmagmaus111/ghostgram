load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Ghostgram extension points (owner: W1-2; frozen after wave 1, changes via the orchestrator).
# The point containers (GGHookPoint) live in GGCore. Each point lives in the lowest module that
# calls it (FOUNDATION_SPEC §1.1, §4), so most of this directory compiles INTO upstream modules:
#
#   Core/                  → TelegramCore                (updates, presence, outgoing, network…)
#   Theme/                 → TelegramPresentationData    (PresentationData transformer chain)
#   Display/               → Display                     (font substitution)
#   ImageCompression/      → ImageCompression            (outgoing photo size / quality / pixels)
#   NotificationService/   → NotificationServiceExtensionLib (launch + push content in the NSE)
#   ShareExtension/        → ShareExtensionContext       (launch in the share extension)
#   SiriIntents/           → IntentsExtensionLib         (launch in the Siri intents extension)
#   TelegramUI/            → TelegramUI                  (launch, lifecycle, helpers needing internal types)
#   PeerInfoScreen/        → PeerInfoScreen              (settings-tab rows → internal PeerInfo items)
#   ChatListUI/            → ChatListUI                  (helpers needing internal ChatListUI types)
#   ChatMessageBubbleItemNode/ → ChatMessageBubbleItemNode (taps, quick translate button beside the bubble)
#   ChatMessageTextBubbleContentNode/ → ChatMessageTextBubbleContentNode (the footnote under the text)
#   UI/                    → swift_library GGHooks       (public UI points)
#
# Every upstream module that receives a filegroup also gets "//Ghostgram/GGCore:GGCore" in deps.

filegroup(
    name = "TelegramCoreHookSources",
    srcs = glob(["Core/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "TelegramPresentationDataHookSources",
    srcs = glob(["Theme/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "DisplayHookSources",
    srcs = glob(["Display/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "ImageCompressionHookSources",
    srcs = glob(["ImageCompression/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "NotificationServiceHookSources",
    srcs = glob(["NotificationService/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "ShareExtensionHookSources",
    srcs = glob(["ShareExtension/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "SiriIntentsHookSources",
    srcs = glob(["SiriIntents/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "TelegramUIHookSources",
    srcs = glob(["TelegramUI/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "PeerInfoScreenHookSources",
    srcs = glob(["PeerInfoScreen/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "ChatListUIHookSources",
    srcs = glob(["ChatListUI/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "ChatMessageBubbleItemNodeHookSources",
    srcs = glob(["ChatMessageBubbleItemNode/**/*.swift"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "ChatMessageTextBubbleContentNodeHookSources",
    srcs = glob(["ChatMessageTextBubbleContentNode/**/*.swift"]),
    visibility = ["//visibility:public"],
)

# Public UI points. Must stay BELOW every module that calls them: ChatListUI, SettingsUI,
# PeerInfoScreen, TelegramUI, GalleryUI, the chat message nodes, the input panels
# (none of them may be in this target's transitive deps).
swift_library(
    name = "GGHooks",
    module_name = "GGHooks",
    srcs = glob([
        "UI/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGCore:GGCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/AccountContext:AccountContext",
        "//submodules/ContextUI:ContextUI",
        # MediaPlayerStatus in the gallery video points (W3-R); AccountContext already depends on it.
        "//submodules/MediaPlayer:UniversalMediaPlayer",
    ],
    visibility = [
        "//visibility:public",
    ],
)
