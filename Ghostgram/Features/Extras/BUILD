load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Feature module GGExtras (W5-SG): the Swiftgram user features Ghostgram did not have yet, written as
# Ghostgram features. Settings and the policy read by upstream call sites live in GGFeaturesShared
# (Sources/Extras). May depend on everything below TelegramUI; never on TelegramUI or another
# GG<Feature> module (FOUNDATION_SPEC §1.1).
swift_library(
    name = "GGExtras",
    module_name = "GGExtras",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":GGExtrasHooks",
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
        "//submodules/ContextUI:ContextUI",
        "//submodules/AppBundle:AppBundle",
        "//submodules/UndoUI:UndoUI",
        "//submodules/PeerInfoUI:PeerInfoUI",
        "//submodules/ChatInterfaceState:ChatInterfaceState",
        # «Переслать без автора»: the picker's comment and «Запланировать» (as in Telegram's forward).
        "//submodules/TextFormat:TextFormat",
        "//submodules/TelegramUI/Components/ChatScheduleTimeController:ChatScheduleTimeController",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# UI points with AccountContext (selection panel buttons, link menu, in-app browser). Below every
# module that calls them: ChatMessageSelectionInputPanelNode, TelegramUI.
swift_library(
    name = "GGExtrasHooks",
    module_name = "GGExtrasHooks",
    srcs = glob([
        "Hooks/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGCore:GGCore",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Points TelegramCore itself calls (in-chat search fallback, restriction text): compiled INTO
# TelegramCore, like //Ghostgram/GGHooks:TelegramCoreHookSources.
filegroup(
    name = "TelegramCoreSources",
    srcs = glob(["Core/**/*.swift"]),
    visibility = ["//visibility:public"],
)
