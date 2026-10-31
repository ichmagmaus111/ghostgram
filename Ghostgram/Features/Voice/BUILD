load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

# Owner: W3-1 («Голос»). Targets:
#
#   GGVoiceDSP           — plain C: the one voice effect graph (voice messages, round videos, calls)
#                          and the playback equalizer. No Foundation, realtime-safe processing. Linked
#                          into UniversalMediaPlayer (equalizer in the audio renderers) and GGVoice.
#   GGVoiceTranscription — transcription of voice messages and round videos: the engine is chosen at
#                          the moment of the request by the account's live Premium status (owner's
#                          decision 2026-10-21): Telegram's server, or Apple Speech. Word timings,
#                          the word bubbles model, the transcription quote. Used by the bubble nodes.
#   GGVoice              — the feature: menu, preview, voice changer for voice messages / round
#                          videos / calls, equalizer parameters, auto-transcription, migrations.
#
# Filegroups compiled INTO upstream modules (their BUILD lists the label in srcs), so the code stays
# under Ghostgram/:
#   TelegramAudioPoints                 — the built-in microphone policy (ManagedAudioSession).
#   UniversalMediaPlayerSources         — the equalizer instance of the audio renderers.
#   ChatMessageInteractiveFileNodeSources — the word bubbles layer of the transcription.

objc_library(
    name = "GGVoiceDSP",
    enable_modules = True,
    module_name = "GGVoiceDSP",
    srcs = glob([
        "DSP/Sources/**/*.c",
    ]),
    hdrs = glob([
        "DSP/PublicHeaders/**/*.h",
    ]),
    includes = [
        "DSP/PublicHeaders",
        "DSP/PublicHeaders/GGVoiceDSP",
    ],
    copts = [
        "-std=c11",
        "-O2",
        "-Werror",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "GGVoiceTranscription",
    module_name = "GGVoiceTranscription",
    srcs = glob([
        "Transcription/Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/Features/Shared:GGFeaturesShared",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "TelegramAudioPoints",
    srcs = glob([
        "Points/TelegramAudio/**/*.swift",
    ]),
    visibility = [
        "//submodules/TelegramAudio:__pkg__",
    ],
)

filegroup(
    name = "UniversalMediaPlayerSources",
    srcs = glob([
        "Points/UniversalMediaPlayer/**/*.swift",
    ]),
    visibility = [
        "//submodules/MediaPlayer:__pkg__",
    ],
)

filegroup(
    name = "ChatMessageInteractiveFileNodeSources",
    srcs = glob([
        "Points/ChatMessageInteractiveFileNode/**/*.swift",
    ]),
    visibility = [
        "//submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode:__pkg__",
    ],
)

# Feature module GGVoice. May depend on everything below TelegramUI; never on TelegramUI or another
# GG<Feature> module (FOUNDATION_SPEC §1.1). GGCameraPipeline, GGCallAudio and GGCallsMediaHooks are
# the light point libraries of W3-2 / W3-3, not their feature modules.
swift_library(
    name = "GGVoice",
    module_name = "GGVoice",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":GGVoiceDSP",
        ":GGVoiceTranscription",
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/GGHooks:GGHooks",
        "//Ghostgram/GGSettingsUI:GGSettingsUI",
        "//Ghostgram/Features/Shared:GGFeaturesShared",
        "//Ghostgram/Features/CameraMasks:GGCameraPipeline",
        "//Ghostgram/Features/CallsMedia/CallAudio:GGCallAudio",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/TelegramVoip:TelegramVoip",
        "//submodules/TelegramCallsUI:TelegramCallsUI",
        "//submodules/UndoUI:UndoUI",
        "//submodules/PromptUI:PromptUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
