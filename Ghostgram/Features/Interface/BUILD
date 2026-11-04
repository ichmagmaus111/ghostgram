load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

# Feature module GGInterface. Owner: W2-5.
# May depend on everything below TelegramUI; never on TelegramUI or another GG<Feature> module
# (FOUNDATION_SPEC §1.1).
#
# Points/<Module>/ — extension points that compile INTO W2-5's own (not frozen) upstream modules,
# the same way GGHooks/<Module>/ does for the frozen ones. Each such module also gets
# "//Ghostgram/GGCore:GGCore" in its deps. GGInterface registers the handlers.

filegroup(
    name = "AvatarNodePointSources",
    srcs = glob(["Points/AvatarNode/**/*.swift"]),
    visibility = ["//submodules/AvatarNode:__pkg__"],
)

filegroup(
    name = "TabBarComponentPointSources",
    srcs = glob(["Points/TabBarComponent/**/*.swift"]),
    visibility = ["//submodules/TelegramUI/Components/TabBarComponent:__pkg__"],
)

filegroup(
    name = "ChatListTitleViewPointSources",
    srcs = glob(["Points/ChatListTitleView/**/*.swift"]),
    visibility = ["//submodules/TelegramUI/Components/ChatListTitleView:__pkg__"],
)

filegroup(
    name = "ChatTextInputActionButtonsNodePointSources",
    srcs = glob(["Points/ChatTextInputActionButtonsNode/**/*.swift"]),
    visibility = ["//submodules/TelegramUI/Components/Chat/ChatTextInputActionButtonsNode:__pkg__"],
)

filegroup(
    name = "EntityKeyboardPointSources",
    srcs = glob(["Points/EntityKeyboard/**/*.swift"]),
    visibility = ["//submodules/TelegramUI/Components/EntityKeyboard:__pkg__"],
)

filegroup(
    name = "TopMessageReactionsPointSources",
    srcs = glob(["Points/TopMessageReactions/**/*.swift"]),
    visibility = ["//submodules/TelegramUI/Components/Chat/TopMessageReactions:__pkg__"],
)

# Zone assets (the bundled island badge). Listed in the app's resources next to
# //Ghostgram/GGSettingsUI:GGSettingsUIAssets in Telegram/BUILD (request R6, frozen file).
filegroup(
    name = "GGInterfaceAssets",
    srcs = glob(["Assets/GGInterface.xcassets/**"]),
    visibility = ["//visibility:public"],
)

# Ghostgram's alternate app icon (Ghost; the duck was removed by the owner, 2026-10-28); wired into
# Telegram/BUILD's alternate icons by request R6. Plain files at the bundle root, as Telegram's own
# `*.alticon` folders.
filegroup(
    name = "GhostAppIcon",
    srcs = glob(["Assets/AppIcons/Ghost.alticon/*.png"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "GGInterface",
    module_name = "GGInterface",
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
        "//submodules/AppBundle:AppBundle",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent:GlassBackgroundComponent",
        "//submodules/WallpaperBackgroundNode:WallpaperBackgroundNode",
        "//submodules/ContextUI:ContextUI",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/UndoUI:UndoUI",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/ChatListUI:ChatListUI",
        "//submodules/SettingsUI:SettingsUI",
        "//submodules/AttachmentTextInputPanelNode:AttachmentTextInputPanelNode",
        "//submodules/Utils/DeviceModel:DeviceModel",
        "//submodules/TelegramUI/Components/ChatListTitleView:ChatListTitleView",
        "//submodules/TelegramUI/Components/ChatListHeaderComponent:ChatListHeaderComponent",
        "//submodules/TelegramUI/Components/NavigationBarComponent:NavigationBarComponent",
        "//submodules/TelegramUI/Components/ChatList/ChatListFilterTabContainerNode:ChatListFilterTabContainerNode",
        "//submodules/TelegramUI/Components/TabBarComponent:TabBarComponent",
        "//submodules/TelegramUI/Components/EntityKeyboard:EntityKeyboard",
        "//submodules/TelegramUI/Components/EmojiStatusSelectionComponent:EmojiStatusSelectionComponent",
        "//submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen:PeerInfoScreen",
        "//submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode:ChatTextInputPanelNode",
        "//submodules/TelegramUI/Components/Chat/ChatTextInputActionButtonsNode:ChatTextInputActionButtonsNode",
        "//submodules/TelegramUI/Components/Chat/TopMessageReactions:TopMessageReactions",
        # The formatting toolbar formats through each composer directly (BUGHUNT UI-14).
        "//submodules/ChatPresentationInterfaceState:ChatPresentationInterfaceState",
        "//submodules/TelegramUI/Components/Chat/ChatInputTextNode:ChatInputTextNode",
        "//submodules/TelegramUI/Components/TextFieldComponent:TextFieldComponent",
        "//third-party/ZipArchive:ZipArchive",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) tests of «Скругление углов» (2026-10-27): only Sources/Settings/GGAvatarCorners.swift
# (Foundation). Run with
#   ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/Interface:GGAvatarCornersTests
swift_test(
    name = "GGAvatarCornersTests",
    srcs = [
        "Sources/Settings/GGAvatarCorners.swift",
    ] + glob([
        "Tests/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
)
