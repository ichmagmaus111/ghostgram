load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ShareExtensionContext",
    module_name = "ShareExtensionContext",
    srcs = glob([
        "Sources/**/*.swift",
    ]) + [
        # GHOST: Ghostgram core and the shared part of the features
        "//Ghostgram/GGHooks:ShareExtensionHookSources",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        # GHOST: Ghostgram core and the shared part of the features
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/Features/Shared:GGFeaturesShared",
        # GHOST: outgoing photo size, quality and watermark (GGShareExtensionPhotos.swift)
        "//submodules/ImageCompression:ImageCompression",
        "//Ghostgram/Features/CameraMasks:GGCameraPipeline",
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/PasscodeCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramUIPreferences",
        "//submodules/AccountContext",
        "//submodules/ShareController",
        "//submodules/TelegramUI/Components/ShareScreen",
        "//submodules/LegacyUI",
        "//submodules/PeerInfoUI",
        "//submodules/ShareItems",
        "//submodules/ShareItems/Impl:ShareItemsImpl",
        "//submodules/SettingsUI",
        "//submodules/PasscodeUI",
        "//submodules/OpenSSLEncryptionProvider",
        "//submodules/AppLock",
        "//submodules/AppLockState",
        "//submodules/OverlayStatusController",
        "//submodules/PresentationDataUtils",
        "//submodules/ChatImportUI",
        "//third-party/ZipArchive",
        "//submodules/ActivityIndicator",
        "//submodules/DebugSettingsUI",
        "//submodules/ManagedFile",
        "//submodules/ContextUI",
        "//submodules/TelegramUI/Components/TelegramUIDeclareEncodables",
        "//submodules/TelegramUI/Components/AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer",
        "//submodules/TelegramUI/Components/DCTAnimationCacheImpl:DCTAnimationCacheImpl",
        "//submodules/TelegramUI/Components/DCTMultiAnimationRendererImpl:DCTMultiAnimationRendererImpl",
        "//submodules/TelegramUI/Components/TelegramAccountAuxiliaryMethods",
        "//submodules/TelegramUI/Components/PeerSelectionController",
        "//submodules/TelegramUI/Components/ContextMenuScreen",
        "//submodules/TelegramUI/Components/ContextControllerImpl",
        "//submodules/TelegramUI/Components/NavigationBarNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
