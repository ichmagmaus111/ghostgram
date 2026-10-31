load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ChatListTitleView",
    module_name = "ChatListTitleView",
    srcs = glob([
        "Sources/**/*.swift",
    ]) + [
        # GHOST: chat list chrome points of W2-5 (title, search by id)
        "//Ghostgram/Features/Interface:ChatListTitleViewPointSources",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/ActivityIndicator:ActivityIndicator",
        "//submodules/AccountContext",
        "//submodules/ComponentFlow",
        "//submodules/AppBundle",
        "//submodules/TelegramUI/Components/EmojiStatusComponent",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/Components/ComponentDisplayAdapters:ComponentDisplayAdapters",
        # GHOST: hook points
        "//Ghostgram/GGCore:GGCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
