load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ChatMessageInteractiveFileNode",
    module_name = "ChatMessageInteractiveFileNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]) + [
        # GHOST: word bubbles and the transcription quote (W3-1)
        "//Ghostgram/Features/Voice:ChatMessageInteractiveFileNodeSources",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/PhotoResources",
        "//submodules/TelegramStringFormatting",
        "//submodules/SemanticStatusNode",
        "//submodules/FileMediaResourceStatus",
        "//submodules/CheckNode",
        "//submodules/MusicAlbumArtResources",
        "//submodules/AudioBlob",
        "//submodules/ContextUI",
        "//submodules/ChatPresentationInterfaceState",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/AudioTranscriptionButtonComponent",
        "//submodules/TelegramUI/Components/AudioWaveformComponent",
        "//submodules/ShimmerEffect",
        "//submodules/Media/ConvertOpusToAAC",
        "//submodules/Media/LocalAudioTranscription",
        "//submodules/TextSelectionNode",
        "//submodules/TelegramUI/Components/AudioTranscriptionPendingIndicatorComponent",
        "//submodules/UndoUI",
        "//submodules/TelegramNotices",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
        "//submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode",
        "//submodules/TelegramUI/Components/Chat/ChatHistoryEntry",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Chat/ShimmeringLinkNode",
        "//submodules/AnimatedCountLabelNode",
        "//submodules/AudioWaveform",
        "//submodules/DeviceProximity",
        # GHOST: transcription for everyone, word timings, quote (W3-1)
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/Features/Voice:GGVoiceTranscription",
        "//submodules/TextFormat:TextFormat",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
