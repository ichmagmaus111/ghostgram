load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "TopMessageReactions",
    module_name = "TopMessageReactions",
    srcs = glob([
        "Sources/**/*.swift",
    ]) + [
        # GHOST: own recent reactions point (W2-5)
        "//Ghostgram/Features/Interface:TopMessageReactionsPointSources",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/AccountContext",
        "//submodules/ReactionSelectionNode",
        # GHOST: hook points
        "//Ghostgram/GGCore:GGCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
