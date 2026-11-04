load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

# Feature module GGMessages (W2-3): restriction bypasses, the outgoing text pipeline, translation,
# the message menu and gestures, the «Чаты» and «Уведомления» sections of the «Сообщения» category.
# May depend on everything below TelegramUI; never on TelegramUI or another GG<Feature> module
# (FOUNDATION_SPEC §1.1).
swift_library(
    name = "GGMessages",
    module_name = "GGMessages",
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
        "//submodules/ContextUI:ContextUI",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/PromptUI:PromptUI",
        "//submodules/UndoUI:UndoUI",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/TextFormat:TextFormat",
        "//submodules/TranslateUI:TranslateUI",
        "//submodules/AppBundle:AppBundle",
        "//submodules/PeerInfoUI:PeerInfoUI",
        # `canEditMessage` for «Двойной тап — изменить» (BUGHUNT UI-42).
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon:ChatMessageItemCommon",
        # «Переслать без автора»: «Запланировать» in the picker (as in Telegram's forward).
        "//submodules/TelegramUI/Components/ChatScheduleTimeController:ChatScheduleTimeController",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) tests of the outgoing text pipeline core: only Sources/Pipeline/Core (Foundation),
# like //submodules/MetalEngine:MetalPipelineCacheTests. Run with
#   ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/Messages:GGMessagesTests
swift_test(
    name = "GGMessagesTests",
    srcs = glob([
        "Sources/Pipeline/Core/**/*.swift",
        "Tests/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
)
