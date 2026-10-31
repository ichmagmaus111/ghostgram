load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ChatMessageItem",
    module_name = "ChatMessageItem",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        # GHOST: appearance snapshot (hidden channel comments) — W2-4
        "//Ghostgram/Features/Appearance:GGAppearanceSettings",
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/AccountContext",
        "//submodules/TelegramUI/Components/Chat/ChatHistoryEntry",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
        "//submodules/TelegramPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
