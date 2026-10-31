load("@rules_cc//cc:objc_library.bzl", "objc_library")

# Realtime part of the call audio effects (silent mute, soundboard mix, voice effect slot, recording tap).
# Owner: W3-3. Linked into TgVoipWebrtc, whose WrappedAudioDeviceModuleIOS feeds every captured and
# played 10 ms block through it; the control side (GGCallAudioEffects) is used from Swift through
# TelegramVoip. No webrtc or tgcalls dependency: the core is plain C++ on Int16 samples.
objc_library(
    name = "GGCallAudio",
    enable_modules = True,
    module_name = "GGCallAudio",
    srcs = glob([
        "Sources/**/*.mm",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
        "PublicHeaders",
    ],
    copts = [
        "-std=c++17",
        "-Werror",
    ],
    sdk_frameworks = [
        "Foundation",
    ],
    visibility = [
        "//visibility:public",
    ],
)
