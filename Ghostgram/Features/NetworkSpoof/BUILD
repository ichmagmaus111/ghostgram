load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Feature module GGNetworkSpoof («Приватность › Подмены»: номер, профиль). Owner: W3-5.
# May depend on everything below TelegramUI; never on TelegramUI or another GG<Feature> module
# (FOUNDATION_SPEC §1.1).
swift_library(
    name = "GGNetworkSpoof",
    module_name = "GGNetworkSpoof",
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
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        # Screens: lists, inputs, alerts.
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AlertUI:AlertUI",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
