load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Aggregator of the feature modules: only `register()` calls. TelegramUI depends on it.
# Owner: W1-2; the twelve feature modules are listed once here so nobody edits it in waves 2–4.
swift_library(
    name = "GGFeatures",
    module_name = "GGFeatures",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGSettingsUI:GGSettingsUI",
        "//Ghostgram/Features/Shared:GGFeaturesShared",
        "//Ghostgram/Features/GhostMode:GGGhostMode",
        "//Ghostgram/Features/AntiDelete:GGAntiDelete",
        "//Ghostgram/Features/Messages:GGMessages",
        "//Ghostgram/Features/Appearance:GGAppearance",
        "//Ghostgram/Features/Interface:GGInterface",
        "//Ghostgram/Features/Voice:GGVoice",
        "//Ghostgram/Features/CameraMasks:GGCameraMasks",
        "//Ghostgram/Features/CallsMedia:GGCallsMedia",
        "//Ghostgram/Features/Security:GGSecurity",
        "//Ghostgram/Features/NetworkSpoof:GGNetworkSpoof",
        "//Ghostgram/Features/Vless:GGVless",
        "//Ghostgram/Features/ProfileExport:GGProfileExport",
        # W5-SG: Swiftgram-parity features
        "//Ghostgram/Features/Extras:GGExtras",
        # W7-RD2: «Дата регистрации»
        "//Ghostgram/Features/RegDate:GGRegDate",
    ],
    visibility = [
        "//visibility:public",
    ],
)
