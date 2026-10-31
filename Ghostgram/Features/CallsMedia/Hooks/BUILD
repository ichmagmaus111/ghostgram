load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Extension points of the «Calls» zone for the upstream call modules (TelegramCallsUI) that sit BELOW
# GGCallsMedia and do not see GGHooks. Owner: W3-3. The handlers live in GGCallsMedia (and, for the
# masks column of the call overlay, in W3-2's module); an empty point means upstream behaviour.
# Same pattern as //Ghostgram/Features/Appearance:GGAppearanceSettings (W2-4).
swift_library(
    name = "GGCallsMediaHooks",
    module_name = "GGCallsMediaHooks",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Ghostgram/GGCore:GGCore",
        "//Ghostgram/Features/CallsMedia/CallAudio:GGCallAudio",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramVoip:TelegramVoip",
        "//submodules/AccountContext:AccountContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)
